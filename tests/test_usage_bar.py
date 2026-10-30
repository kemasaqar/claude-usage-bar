"""Run with: python3 -m unittest discover -s tests"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "bridge" / "statusline.py"
PLUGIN = ROOT / "swiftbar" / "claude-usage.5m.py"


def payload(five=None, seven=None, **extra):
    rl = {}
    if five:
        rl["five_hour"] = {"used_percentage": five[0], "resets_at": five[1]}
    if seven:
        rl["seven_day"] = {"used_percentage": seven[0], "resets_at": seven[1]}
    p = {
        "model": {"id": "claude-opus-5-5", "display_name": "Opus"},
        "workspace": {"current_dir": "/tmp/myproj"},
        "context_window": {"used_percentage": 8},
        **extra,
    }
    if rl:
        p["rate_limits"] = rl
    return p


class UsageBarTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "sub" / "usage.json"
        # Empty projects dir + nonexistent claude: the plugin's background
        # auto-check can never start a real Claude request during tests.
        projects = Path(self.tmp.name) / "projects"
        projects.mkdir()
        self.env = {
            **os.environ,
            "CLAUDE_USAGE_BAR_CACHE": str(self.cache),
            "CLAUDE_USAGE_BAR_PROJECTS": str(projects),
            "CLAUDE_USAGE_BAR_CLAUDE": str(Path(self.tmp.name) / "no-claude"),
            "PATH": "/usr/bin:/bin",
        }
        self.now = int(time.time())

    def tearDown(self):
        self.tmp.cleanup()

    def bridge(self, data) -> str:
        stdin = data if isinstance(data, str) else json.dumps(data)
        r = subprocess.run(
            [sys.executable, str(BRIDGE)], input=stdin, env=self.env,
            capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()

    def plugin(self) -> str:
        r = subprocess.run(
            [sys.executable, str(PLUGIN)], env=self.env,
            capture_output=True, text=True, check=True,
        )
        return r.stdout

    def cached(self) -> dict:
        return json.loads(self.cache.read_text())["windows"]

    def test_writes_cache_and_prints_status_line(self):
        out = self.bridge(payload(five=(23.5, self.now + 3600), seven=(41.2, self.now + 86400 * 3)))
        self.assertIn("Opus", out)
        self.assertIn("myproj", out)
        self.assertIn("5h 24%", out)
        self.assertIn("7d 41%", out)
        w = self.cached()
        self.assertEqual(w["five_hour"]["used_percentage"], 23.5)
        self.assertEqual(w["seven_day"]["used_percentage"], 41.2)

    def test_lower_value_in_same_window_is_ignored(self):
        reset = self.now + 3600
        self.bridge(payload(five=(50, reset)))
        self.bridge(payload(five=(30, reset)))  # stale session
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 50)

    def test_higher_value_in_same_window_wins(self):
        reset = self.now + 3600
        self.bridge(payload(five=(30, reset)))
        self.bridge(payload(five=(55, reset)))
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 55)

    def test_newer_window_replaces_even_if_lower(self):
        self.bridge(payload(five=(90, self.now + 60)))
        self.bridge(payload(five=(2, self.now + 5 * 3600)))
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 2)

    def test_older_window_is_ignored(self):
        self.bridge(payload(five=(2, self.now + 5 * 3600)))
        self.bridge(payload(five=(90, self.now + 60)))
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 2)

    def test_missing_rate_limits_keeps_cache(self):
        self.bridge(payload(five=(10, self.now + 3600)))
        out = self.bridge(payload())  # e.g. new session before first reply
        self.assertNotIn("5h", out)
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 10)

    def test_garbage_input_does_not_crash(self):
        self.assertEqual(self.bridge("not json"), "")
        self.assertEqual(self.bridge(json.dumps({"rate_limits": {"five_hour": "x"}})), "")
        self.assertFalse(self.cache.exists())

    def test_plugin_without_cache_shows_setup_help(self):
        out = self.plugin()
        self.assertIn("No usage data yet", out)

    def test_plugin_shows_percentages_and_colors(self):
        self.bridge(payload(five=(92, self.now + 3600), seven=(41, self.now + 86400 * 3)))
        title = self.plugin().splitlines()[0]
        self.assertTrue(title.startswith("92% · 41% |"), title)
        self.assertIn("color=#E5484D", title)

    def test_plugin_treats_passed_window_as_reset(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text(json.dumps({
            "updated_at": self.now,
            "windows": {"five_hour": {"used_percentage": 80, "resets_at": self.now - 10}},
        }))
        out = self.plugin()
        self.assertTrue(out.startswith("0%↺"), out.splitlines()[0])
        self.assertIn("Window has reset", out)

    def test_plugin_marks_stale(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text(json.dumps({
            "updated_at": self.now - 3 * 3600,
            "windows": {"five_hour": {"used_percentage": 10, "resets_at": self.now + 3600}},
        }))
        out = self.plugin()
        self.assertIn("⚠", out.splitlines()[0])
        self.assertIn("(stale)", out)


if __name__ == "__main__":
    unittest.main()
