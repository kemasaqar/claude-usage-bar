#!/usr/bin/env bash
# Wires the bridge into Claude Code and links the plugin into SwiftBar.
# Safe to re-run. Usage: ./install.sh [--force]   (--force replaces an existing statusLine)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge/statusline.py"
PLUGIN="$ROOT/swiftbar/claude-usage.5m.py"
SETTINGS="$HOME/.claude/settings.json"
FORCE="${1:-}"

chmod +x "$BRIDGE" "$PLUGIN"

# 1. Claude Code statusLine -> bridge
python3 - "$SETTINGS" "$BRIDGE" "$FORCE" <<'PY'
import json, shutil, sys, time
from pathlib import Path

settings_path, bridge, force = Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "--force"
settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
want = {"type": "command", "command": bridge}
current = settings.get("statusLine")

if current == want:
    print(f"statusLine already set in {settings_path}")
    sys.exit(0)
if current and not force:
    print(f"A statusLine is already configured in {settings_path}:")
    print(f"  {json.dumps(current)}")
    print("Re-run with --force to replace it (a backup is kept).")
    sys.exit(1)
if settings_path.exists():
    backup = settings_path.with_name(f"settings.json.bak-{int(time.time())}")
    shutil.copy2(settings_path, backup)
    print(f"Backed up {settings_path} -> {backup.name}")
settings["statusLine"] = want
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"Set statusLine in {settings_path}")
PY

# 2. SwiftBar plugin symlink
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [[ -z "$PLUGIN_DIR" ]]; then
  echo
  echo "SwiftBar isn't set up yet. Install it, open it once, and pick a plugin folder:"
  echo "  brew install --cask swiftbar"
  echo "Then re-run ./install.sh"
  exit 0
fi
mkdir -p "$PLUGIN_DIR"
ln -sf "$PLUGIN" "$PLUGIN_DIR/claude-usage.5m.py"
echo "Linked plugin into $PLUGIN_DIR"
open -g "swiftbar://refreshallplugins" 2>/dev/null || true
echo "Done. Send a message in Claude Code to populate the menu bar."
