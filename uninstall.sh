#!/usr/bin/env bash
# Undoes install.sh: puts back the status line you had before (or removes
# ours) and removes the SwiftBar link. Leaves SwiftBar itself installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge/statusline.py"
SETTINGS="$HOME/.claude/settings.json"

python3 "$ROOT/bridge/setup_settings.py" uninstall "$SETTINGS" "$BRIDGE"

PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [[ -n "$PLUGIN_DIR" && -L "$PLUGIN_DIR/claude-usage.5m.py" ]]; then
  rm "$PLUGIN_DIR/claude-usage.5m.py"
  echo "Removed SwiftBar plugin link"
fi
echo "Cache and auto-check state left at ~/.cache/claude-usage-bar (delete it if you like)."
echo "SwiftBar is still installed; remove it with: brew uninstall --cask swiftbar"
