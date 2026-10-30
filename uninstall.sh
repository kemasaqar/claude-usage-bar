#!/usr/bin/env bash
# Removes the statusLine entry (only if it points at this bridge) and the SwiftBar link.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge/statusline.py"
SETTINGS="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS" ]]; then
python3 - "$SETTINGS" "$BRIDGE" <<'PY'
import json, sys
from pathlib import Path

path, bridge = Path(sys.argv[1]), sys.argv[2]
settings = json.loads(path.read_text())
if (settings.get("statusLine") or {}).get("command") == bridge:
    del settings["statusLine"]
    path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"Removed statusLine from {path}")
else:
    print("statusLine doesn't point at this bridge; left it alone")
PY
fi

PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [[ -n "$PLUGIN_DIR" && -L "$PLUGIN_DIR/claude-usage.5m.py" ]]; then
  rm "$PLUGIN_DIR/claude-usage.5m.py"
  echo "Removed SwiftBar plugin link"
fi
echo "Cache left at ~/.cache/claude-usage-bar (delete it if you like)."
