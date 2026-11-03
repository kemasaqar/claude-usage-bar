#!/usr/bin/env python3
"""Point Claude Code's statusLine at the bridge, or undo that.

  setup_settings.py install   SETTINGS BRIDGE
  setup_settings.py uninstall SETTINGS BRIDGE

install keeps a status line you already had: it's saved in the config file
(CLAUDE_USAGE_BAR_CONFIG, default ~/.config/claude-usage-bar/config.json) and
the bridge shows its output. uninstall puts it back. Both back up
settings.json before changing it. Used by install.sh and uninstall.sh.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from statusline import CONFIG_PATH, load_cache, write_cache  # noqa: E402


def is_ours(status_line) -> bool:
    """Also matches an older checkout of this repo at another path."""
    command = status_line.get("command") if isinstance(status_line, dict) else None
    return isinstance(command, str) and command.endswith("/bridge/statusline.py")


def load_settings(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        settings = json.loads(path.read_text())
    except ValueError as e:
        sys.exit(f"Error: {path} isn't valid JSON ({e}); fix it and re-run.")
    if not isinstance(settings, dict):
        sys.exit(f"Error: {path} doesn't contain a JSON object.")
    return settings


def save_settings(path: Path, settings: dict) -> None:
    """Back up, then write atomically. Writes through a symlink (dotfiles
    setups) instead of replacing it."""
    target = path.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        backup = path.with_name(f"settings.json.bak-{int(time.time())}")
        shutil.copy2(target, backup)
        print(f"Backed up {path} -> {backup.name}")
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".settings-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
        if target.exists():
            shutil.copymode(target, tmp)
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def install(path: Path, bridge: str) -> None:
    settings = load_settings(path)
    current = settings.get("statusLine")
    if current and not is_ours(current):
        write_cache(CONFIG_PATH, {"original_status_line": current})
        print(f"Kept your status line: {current.get('command', current)}")
        print("  It still shows in the terminal; the bridge runs it for you.")
    # Keep extra keys such as "padding" from the existing entry.
    wanted = {**(current if isinstance(current, dict) else {}),
              "type": "command", "command": bridge}
    if current == wanted:
        print(f"statusLine already set in {path}")
        return
    settings["statusLine"] = wanted
    save_settings(path, settings)
    print(f"Set statusLine in {path}")


def uninstall(path: Path, bridge: str) -> None:
    settings = load_settings(path)
    current = settings.get("statusLine")
    original = load_cache(CONFIG_PATH).get("original_status_line")
    if not is_ours(current):
        print("statusLine doesn't point at this bridge; left it alone")
    else:
        restore = isinstance(original, dict) and original
        if restore:
            settings["statusLine"] = original
        else:
            del settings["statusLine"]
        save_settings(path, settings)
        if restore:
            print(f"Restored your status line: {original.get('command', original)}")
        else:
            print(f"Removed statusLine from {path}")
    CONFIG_PATH.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in ("install", "uninstall"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    action, settings, bridge = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    (install if action == "install" else uninstall)(settings, bridge)
    return 0


if __name__ == "__main__":
    sys.exit(main())
