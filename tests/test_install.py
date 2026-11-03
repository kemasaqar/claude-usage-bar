"""Run with: python3 -m unittest discover -s tests

Runs the real install.sh and uninstall.sh against a temporary HOME, with fake
brew, defaults, open, pgrep, pkill, mdfind, uname and xcode-select first on
PATH. Nothing touches your real settings, SwiftBar or Homebrew.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Each fake logs "name args..." to $FAKE_LOG.
FAKES = {
    "uname": 'echo "${FAKE_UNAME:-Darwin}"',
    "xcode-select": 'exit "${FAKE_XCODE_EXIT:-0}"',
    "mdfind": "exit 0",
    "pgrep": 'exit "${FAKE_PGREP_EXIT:-1}"',
    "pkill": "exit 0",
    "open": "exit 0",
    "brew": 'mkdir -p "$FAKE_APP_DIR/SwiftBar.app"',
    # Stores the one key we use in a file.
    "defaults": """
case "$1" in
  read) [[ -f "$FAKE_DEFAULTS" ]] && cat "$FAKE_DEFAULTS" || exit 1 ;;
  write) printf '%s' "$4" > "$FAKE_DEFAULTS" ;;
esac""",
}


class InstallScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        self.apps = root / "Applications"
        self.apps.mkdir()
        self.log = root / "calls.log"
        self.defaults = root / "swiftbar-defaults"
        self.bin = root / "bin"
        self.bin.mkdir()
        for name, body in FAKES.items():
            fake = self.bin / name
            fake.write_text(
                f'#!/bin/bash\necho "{name} $*" >> "$FAKE_LOG"\n{body}\n'
            )
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.settings = self.home / ".claude" / "settings.json"
        self.plugin_dir = self.home / "Library" / "Application Support" / "SwiftBar" / "Plugins"
        self.env = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "CLAUDE_USAGE_BAR_APP_DIRS": str(self.apps),
            "FAKE_APP_DIR": str(self.apps),
            "FAKE_LOG": str(self.log),
            "FAKE_DEFAULTS": str(self.defaults),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, name: str, **env) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["/bin/bash", str(ROOT / name)], env={**self.env, **env},
            capture_output=True, text=True, stdin=subprocess.DEVNULL,
        )

    def calls(self, name: str) -> list:
        if not self.log.exists():
            return []
        return [line.split(" ", 1)[1] if " " in line else ""
                for line in self.log.read_text().splitlines()
                if line.split(" ", 1)[0] == name]

    def have_swiftbar(self, plugin_dir: Path | None = None):
        (self.apps / "SwiftBar.app").mkdir()
        if plugin_dir:
            plugin_dir.mkdir(parents=True, exist_ok=True)
            self.defaults.write_text(str(plugin_dir))

    def status_line(self):
        return json.loads(self.settings.read_text()).get("statusLine")

    def test_fresh_mac_installs_and_sets_up_swiftbar(self):
        r = self.run_script("install.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls("brew"), ["install --cask swiftbar"])
        self.assertEqual(self.defaults.read_text(), str(self.plugin_dir))
        link = self.plugin_dir / "claude-usage.5m.py"
        self.assertEqual(link.resolve(), ROOT / "swiftbar" / "claude-usage.5m.py")
        self.assertEqual(self.status_line()["command"], str(ROOT / "bridge" / "statusline.py"))
        self.assertEqual(self.calls("open"), [f"-a {self.apps}/SwiftBar.app"])

    def test_existing_setup_is_reused_and_refreshed(self):
        custom = self.home / "MyPlugins"
        self.have_swiftbar(custom)
        r = self.run_script("install.sh", FAKE_PGREP_EXIT="0")  # SwiftBar running
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls("brew"), [])
        self.assertEqual(self.calls("pkill"), [])
        self.assertEqual(self.defaults.read_text(), str(custom))
        self.assertTrue((custom / "claude-usage.5m.py").is_symlink())
        self.assertEqual(self.calls("open"), ["-g swiftbar://refreshallplugins"])

    def test_missing_plugin_folder_is_replaced_with_default(self):
        self.have_swiftbar()
        self.defaults.write_text(str(self.home / "gone"))
        r = self.run_script("install.sh", FAKE_PGREP_EXIT="0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.defaults.read_text(), str(self.plugin_dir))
        # Quit first, or SwiftBar would write its old value back on quit.
        self.assertEqual(self.calls("pkill"), ["-x SwiftBar"])

    def test_no_swiftbar_and_no_homebrew_stops_before_changing_anything(self):
        (self.bin / "brew").unlink()
        r = self.run_script("install.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("https://swiftbar.app", r.stderr)
        self.assertFalse(self.settings.exists())

    def test_missing_command_line_tools_stops_early(self):
        r = self.run_script("install.sh", FAKE_XCODE_EXIT="2")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("xcode-select --install", r.stderr)
        self.assertEqual(self.calls("brew"), [])
        self.assertFalse(self.settings.exists())

    def test_not_macos_stops_early(self):
        r = self.run_script("install.sh", FAKE_UNAME="Linux")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("only runs on macOS", r.stderr)

    def test_uninstall_reverses_install(self):
        self.have_swiftbar(self.plugin_dir)
        self.settings.parent.mkdir()
        mine = {"type": "command", "command": "~/my-status.sh"}
        self.settings.write_text(json.dumps({"statusLine": mine}))
        self.assertEqual(self.run_script("install.sh").returncode, 0)
        r = self.run_script("uninstall.sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.status_line(), mine)
        self.assertFalse((self.plugin_dir / "claude-usage.5m.py").exists())
        self.assertTrue((self.apps / "SwiftBar.app").exists())  # left installed


if __name__ == "__main__":
    unittest.main()
