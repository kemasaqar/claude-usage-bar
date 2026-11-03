"""Run with: python3 -m unittest discover -s tests"""
from __future__ import annotations

import fcntl
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

# Mimics `claude -p --output-format stream-json`. FAKE_MODE: fail prints an
# error, noevent succeeds without a rate_limit_event, slow hangs.
FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
mode = os.environ.get("FAKE_MODE")
if mode == "fail":
    print("Invalid API key", file=sys.stderr)
    sys.exit(1)
if mode == "slow":
    time.sleep(30)
reset = int(os.environ["FAKE_RESET"])
print(json.dumps({"type": "system", "subtype": "init"}))
if mode == "noevent":
    print(json.dumps({"type": "result", "subtype": "success"}))
    sys.exit(0)
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

    def probe_state(self) -> dict:
        return json.loads((self.state_dir / "probe.json").read_text())

    def test_reply_without_rate_limit_event_is_a_failure(self):
        self.write_cache(self.now - 3600)
        r = self.probe("--now", FAKE_MODE="noevent")
        self.assertEqual(r.returncode, 1)
        self.assertFalse(self.probe_state()["ok"])
        w = json.loads(self.cache.read_text())["windows"]
        self.assertEqual(w["five_hour"]["used_percentage"], 10.0)

    def test_hung_claude_times_out(self):
        start = time.time()
        r = self.probe("--now", FAKE_MODE="slow", CLAUDE_USAGE_BAR_PROBE_TIMEOUT_S="1")
        self.assertLess(time.time() - start, 10)
        self.assertEqual(r.returncode, 1)
        self.assertIn("timed out", self.probe_state()["error"])

    def test_missing_claude_is_reported(self):
        r = self.probe("--now", CLAUDE_USAGE_BAR_CLAUDE=str(self.state_dir / "nope"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("claude not found", self.probe_state()["error"])
        self.assertEqual(self.calls(), [])

    def test_second_check_while_one_runs_is_skipped(self):
        self.state_dir.mkdir(parents=True)
        with open(self.state_dir / ".probe-lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)  # another check in progress
            r = self.probe("--now")
        self.assertEqual(r.returncode, 0)
        self.assertIn("already running", r.stdout)
        self.assertEqual(self.calls(), [])

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
