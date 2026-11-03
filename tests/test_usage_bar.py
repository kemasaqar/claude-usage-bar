"""Run with: python3 -m unittest discover -s tests"""
from __future__ import annotations

import base64
import importlib.util
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
        self.config = Path(self.tmp.name) / "config.json"
        self.env = {
            **os.environ,
            "CLAUDE_USAGE_BAR_CACHE": str(self.cache),
            "CLAUDE_USAGE_BAR_CONFIG": str(self.config),
            "CLAUDE_USAGE_BAR_PROJECTS": str(projects),
            "CLAUDE_USAGE_BAR_CLAUDE": str(Path(self.tmp.name) / "no-claude"),
            "CLAUDE_USAGE_BAR_REFRESH_URL": "",
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

    def keep_original(self, command: str):
        self.config.write_text(json.dumps(
            {"original_status_line": {"type": "command", "command": command}}))

    def test_original_status_line_is_shown_and_cache_still_updated(self):
        self.keep_original("printf 'mine: '; head -c 12")  # echoes part of its stdin
        out = self.bridge(payload(five=(23.5, self.now + 3600)))
        self.assertEqual(out, 'mine: {"model": {"')
        self.assertEqual(self.cached()["five_hour"]["used_percentage"], 23.5)

    def test_failing_original_status_line_falls_back_to_ours(self):
        self.keep_original("echo broken; exit 3")
        out = self.bridge(payload(five=(23.5, self.now + 3600)))
        self.assertIn("5h 24%", out)

    def test_plugin_without_cache_shows_setup_help(self):
        out = self.plugin()
        self.assertIn("No usage data yet", out)

    def test_plugin_shows_percentages_and_colors(self):
        self.bridge(payload(five=(92, self.now + 3600), seven=(41, self.now + 86400 * 3)))
        title = self.plugin().splitlines()[0]
        self.assertTrue(title.startswith("92% · 41% |"), title)
        self.assertIn("color=#E5484D", title)

    def test_plugin_icon_shows_what_is_left(self):
        spec = importlib.util.spec_from_file_location("plugin", PLUGIN)
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)
        self.bridge(payload(five=(10, self.now + 3600), seven=(30, self.now + 86400)))
        title = self.plugin().splitlines()[0]
        encoded = title.split("templateImage=")[1].split()[0]
        self.assertTrue(base64.b64decode(encoded).startswith(b"\x89PNG\r\n\x1a\n"))
        # 30% used (the higher of the two) -> 70% full
        self.assertEqual(encoded, plugin.png_base64(plugin.icon_alpha(70)))

    def test_icon_fills_from_bottom(self):
        spec = importlib.util.spec_from_file_location("plugin", PLUGIN)
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)
        size = plugin.ICON_PT * plugin.ICON_SCALE
        mid = size // 2
        empty, half, full = (plugin.icon_alpha(p) for p in (0, 50, 100))
        self.assertEqual(empty[mid][mid], 0)              # only the ring at 0%
        self.assertGreater(empty[mid][1], 0)
        self.assertEqual(half[mid + 4][mid], 255)          # below the level
        self.assertEqual(half[mid - 4][mid], 0)            # above the level
        self.assertEqual(full[mid - 8][mid], 255)          # full to the top
        self.assertEqual(full[mid][mid - 11], 0)           # gap before the ring
        total = [sum(map(sum, plugin.icon_alpha(p))) for p in (0, 25, 50, 75, 100)]
        self.assertEqual(total, sorted(total))

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

    def test_plugin_unchanged_but_recently_checked_is_not_stale(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text(json.dumps({
            "updated_at": self.now - 3 * 3600,  # numbers haven't moved
            "checked_at": self.now - 300,       # but a reading just confirmed them
            "windows": {"five_hour": {"used_percentage": 10, "resets_at": self.now + 3600}},
        }))
        out = self.plugin()
        self.assertNotIn("⚠", out.splitlines()[0])
        self.assertIn("Last reading 5m ago", out)


if __name__ == "__main__":
    unittest.main()
