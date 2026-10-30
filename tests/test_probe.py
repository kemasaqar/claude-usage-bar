"""Run with: python3 -m unittest discover -s tests"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "bridge" / "probe.py"

# Mimics `claude -p --output-format stream-json`. FAKE_MODE=fail prints an error.
FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if os.environ.get("FAKE_MODE") == "fail":
    print("Invalid API key", file=sys.stderr)
    sys.exit(1)
reset = int(os.environ["FAKE_RESET"])
print(json.dumps({"type": "system", "subtype": "init"}))
print(json.dumps({"type": "rate_limit_event", "rate_limit_info": {
    "status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": 0.25, "resetsAt": reset},
        "seven_day": {"utilization": 0.5, "resetsAt": reset + 86400}}}}))
print(json.dumps({"type": "result", "subtype": "success"}))
"""


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.state_dir = root / "cache"
        self.cache = self.state_dir / "usage.json"
        self.projects = root / "projects"
        (self.projects / "proj").mkdir(parents=True)
        self.log = root / "calls.log"
        fake = root / "claude"
        fake.write_text(FAKE_CLAUDE)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.now = int(time.time())
        self.env = {
            **os.environ,
            "CLAUDE_USAGE_BAR_CACHE": str(self.cache),
            "CLAUDE_USAGE_BAR_PROJECTS": str(self.projects),
            "CLAUDE_USAGE_BAR_CLAUDE": str(fake),
            "CLAUDE_USAGE_BAR_REFRESH_URL": "",  # never poke the real SwiftBar
            "FAKE_LOG": str(self.log),
            "FAKE_RESET": str(self.now + 3600),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def probe(self, *args, **env):
        return subprocess.run(
            [sys.executable, str(PROBE), *args], env={**self.env, **env},
            capture_output=True, text=True,
        )

    def calls(self) -> list:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def touch_transcript(self, mtime: float):
        t = self.projects / "proj" / "session.jsonl"
        t.write_text("{}\n")
        os.utime(t, (mtime, mtime))

    def write_cache(self, checked_at: int):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.cache.write_text(json.dumps({
            "updated_at": checked_at, "checked_at": checked_at,
            "windows": {"five_hour": {"used_percentage": 10.0, "resets_at": self.now + 3600}},
        }))

    def test_now_writes_cache_from_rate_limit_event(self):
        r = self.probe("--now")
        self.assertEqual(r.returncode, 0, r.stderr)
        w = json.loads(self.cache.read_text())["windows"]
        self.assertEqual(w["five_hour"]["used_percentage"], 25.0)
        self.assertEqual(w["seven_day"]["used_percentage"], 50.0)
        args = self.calls()[0]
        for flag in ("-p", "--no-session-persistence", "--strict-mcp-config"):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--model") + 1], "haiku")
        state = json.loads((self.state_dir / "probe.json").read_text())
        self.assertTrue(state["ok"])

    def test_failure_is_recorded_and_cache_untouched(self):
        self.write_cache(self.now - 3600)
        r = self.probe("--now", FAKE_MODE="fail")
        self.assertEqual(r.returncode, 1)
        state = json.loads((self.state_dir / "probe.json").read_text())
        self.assertFalse(state["ok"])
        self.assertIn("Invalid API key", state["error"])
        w = json.loads(self.cache.read_text())["windows"]
        self.assertEqual(w["five_hour"]["used_percentage"], 10.0)

    def test_auto_checks_while_window_open_even_when_idle(self):
        self.write_cache(self.now - 3600)       # 5-hour window resets in 1h
        self.touch_transcript(self.now - 7200)  # no activity since last reading
        r = self.probe("--auto")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_auto_skips_when_idle_and_window_closed(self):
        self.state_dir.mkdir(parents=True)
        self.cache.write_text(json.dumps({
            "updated_at": self.now - 7200, "checked_at": self.now - 7200,
            "windows": {"five_hour": {"used_percentage": 40.0, "resets_at": self.now - 60}},
        }))
        self.touch_transcript(self.now - 9000)
        r = self.probe("--auto")
        self.assertIn("idle, no open 5-hour window", r.stdout)
        self.assertEqual(self.calls(), [])
        state = json.loads((self.state_dir / "probe.json").read_text())
        self.assertEqual(state["skipped"], "idle, no open 5-hour window")

    def test_auto_skips_recent_reading(self):
        self.write_cache(self.now - 60)
        self.touch_transcript(self.now)
        r = self.probe("--auto")
        self.assertIn("recent reading", r.stdout)
        self.assertEqual(self.calls(), [])

    def test_auto_checks_after_activity_on_stale_reading(self):
        self.write_cache(self.now - 3600)
        self.touch_transcript(self.now - 30)
        r = self.probe("--auto")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls()), 1)
        # A second run right after must not check again.
        self.probe("--auto")
        self.assertEqual(len(self.calls()), 1)

    def test_pause_and_resume(self):
        self.write_cache(self.now - 3600)
        self.touch_transcript(self.now - 30)
        self.probe("--pause")
        r = self.probe("--auto")
        self.assertIn("paused", r.stdout)
        self.assertEqual(self.calls(), [])
        # --now still works while paused.
        self.probe("--now")
        self.assertEqual(len(self.calls()), 1)
        self.probe("--resume")
        self.assertFalse((self.state_dir / "auto-check-paused").exists())


if __name__ == "__main__":
    unittest.main()
