"""Run with: python3 -m unittest discover -s tests"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SETUP = ROOT / "bridge" / "setup_settings.py"
BRIDGE = "/opt/claude-usage-bar/bridge/statusline.py"
MINE = {"type": "command", "command": "~/.claude/my-status.sh", "padding": 0}


class SetupSettingsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.settings = root / "claude" / "settings.json"
        self.config = root / "config" / "config.json"
        self.env = {**os.environ, "CLAUDE_USAGE_BAR_CONFIG": str(self.config)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_setup(self, action: str, bridge: str = BRIDGE) -> str:
        r = subprocess.run(
            [sys.executable, str(SETUP), action, str(self.settings), bridge],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def write_settings(self, data: dict):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data))

    def read_settings(self) -> dict:
        return json.loads(self.settings.read_text())

    def backups(self) -> list:
        return list(self.settings.parent.glob("settings.json.bak-*"))

    def test_install_without_settings_file(self):
        self.run_setup("install")
        self.assertEqual(self.read_settings()["statusLine"],
                         {"type": "command", "command": BRIDGE})
        self.assertFalse(self.config.exists())

    def test_install_keeps_other_settings_and_backs_up(self):
        self.write_settings({"model": "opus", "env": {"FOO": "ü"}})
        self.run_setup("install")
        s = self.read_settings()
        self.assertEqual(s["model"], "opus")
        self.assertEqual(s["env"]["FOO"], "ü")
        self.assertEqual(len(self.backups()), 1)

    def test_install_keeps_existing_status_line(self):
        self.write_settings({"statusLine": MINE})
        out = self.run_setup("install")
        self.assertIn("Kept your status line", out)
        self.assertEqual(json.loads(self.config.read_text())["original_status_line"], MINE)
        self.assertEqual(self.read_settings()["statusLine"],
                         {"type": "command", "command": BRIDGE, "padding": 0})

    def test_install_and_uninstall_with_non_object_status_line(self):
        self.write_settings({"statusLine": "echo hi"})
        self.assertIn("Kept your status line: echo hi", self.run_setup("install"))
        self.assertEqual(self.read_settings()["statusLine"],
                         {"type": "command", "command": BRIDGE})
        self.run_setup("uninstall")
        self.assertEqual(self.read_settings()["statusLine"], "echo hi")

    def test_reinstall_changes_nothing(self):
        self.write_settings({"statusLine": MINE})
        self.run_setup("install")
        out = self.run_setup("install")
        self.assertIn("already set", out)
        self.assertEqual(len(self.backups()), 1)
        # The saved original is still yours, not the bridge.
        self.assertEqual(json.loads(self.config.read_text())["original_status_line"], MINE)

    def test_reinstall_from_moved_checkout_updates_path(self):
        self.run_setup("install", "/old/place/bridge/statusline.py")
        self.run_setup("install")
        self.assertEqual(self.read_settings()["statusLine"]["command"], BRIDGE)
        self.assertFalse(self.config.exists())

    def test_uninstall_restores_original(self):
        self.write_settings({"statusLine": MINE, "model": "opus"})
        self.run_setup("install")
        out = self.run_setup("uninstall")
        self.assertIn("Restored your status line", out)
        self.assertEqual(self.read_settings(), {"statusLine": MINE, "model": "opus"})
        self.assertFalse(self.config.exists())

    def test_uninstall_without_original_removes_entry(self):
        self.write_settings({"model": "opus"})
        self.run_setup("install")
        self.run_setup("uninstall")
        self.assertEqual(self.read_settings(), {"model": "opus"})

    def test_uninstall_leaves_someone_elses_status_line(self):
        self.write_settings({"statusLine": MINE})
        out = self.run_setup("uninstall")
        self.assertIn("left it alone", out)
        self.assertEqual(self.read_settings()["statusLine"], MINE)

    def test_symlinked_settings_stays_a_symlink(self):
        real = Path(self.tmp.name) / "dotfiles" / "settings.json"
        real.parent.mkdir()
        real.write_text(json.dumps({"model": "opus"}))
        self.settings.parent.mkdir(parents=True)
        self.settings.symlink_to(real)
        self.run_setup("install")
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(json.loads(real.read_text())["statusLine"]["command"], BRIDGE)

    def test_invalid_json_is_left_untouched(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text("{not json")
        r = subprocess.run(
            [sys.executable, str(SETUP), "install", str(self.settings), BRIDGE],
            env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("isn't valid JSON", r.stderr)
        self.assertEqual(self.settings.read_text(), "{not json")


if __name__ == "__main__":
    unittest.main()
