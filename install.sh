#!/usr/bin/env bash
# Sets up claude-usage-bar: checks requirements, installs SwiftBar if needed,
# points Claude Code's statusLine at the bridge (keeping yours, if you have
# one) and links the plugin into SwiftBar. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$ROOT/bridge/statusline.py"
PLUGIN="$ROOT/swiftbar/claude-usage.5m.py"
SETTINGS="$HOME/.claude/settings.json"
SWIFTBAR_ID="com.ameba.SwiftBar"
DEFAULT_PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
# Folders to look for SwiftBar.app in, colon-separated (tests override this).
APP_DIRS="${CLAUDE_USAGE_BAR_APP_DIRS:-/Applications:$HOME/Applications}"

fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

# 1. Requirements
[[ "$(uname -s)" == Darwin ]] || fail "claude-usage-bar only runs on macOS."
# Without Apple's Command Line Tools, /usr/bin/python3 is a stub that pops up
# an install dialog, and the menu bar would stay blank.
xcode-select -p >/dev/null 2>&1 \
  || fail "Apple's Command Line Tools are missing. Run: xcode-select --install, then re-run ./install.sh"
command -v python3 >/dev/null || fail "python3 not found."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' \
  || fail "Python 3.9 or newer is needed (found $(python3 -V 2>&1))."

CLAUDE=""
for c in "$(command -v claude || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
         /opt/homebrew/bin/claude /usr/local/bin/claude; do
  if [[ -n "$c" && -x "$c" ]]; then CLAUDE="$c"; break; fi
done
[[ -n "$CLAUDE" ]] || echo "Warning: Claude Code (claude) not found. Install it, or auto-check can't run."

# 2. SwiftBar, the app that hosts the menu bar item
find_swiftbar() {
  local dir dirs
  IFS=: read -ra dirs <<< "$APP_DIRS"
  for dir in "${dirs[@]}"; do
    [[ -d "$dir/SwiftBar.app" ]] && { echo "$dir/SwiftBar.app"; return; }
  done
  mdfind "kMDItemCFBundleIdentifier == '$SWIFTBAR_ID'" 2>/dev/null | head -1
}
SWIFTBAR_APP="$(find_swiftbar)"
if [[ -z "$SWIFTBAR_APP" ]]; then
  command -v brew >/dev/null \
    || fail "SwiftBar isn't installed. Get it from https://swiftbar.app, then re-run ./install.sh"
  if [[ -t 0 ]]; then
    read -r -p "SwiftBar (shows the menu bar item) isn't installed. Install it with Homebrew? [Y/n] " answer
    [[ "$answer" =~ ^[Nn] ]] && fail "SwiftBar is required."
  fi
  brew install --cask swiftbar
  SWIFTBAR_APP="$(find_swiftbar)"
  [[ -n "$SWIFTBAR_APP" ]] || fail "SwiftBar installed, but its app wasn't found."
fi

# SwiftBar asks for a plugin folder on first launch unless one is set and
# exists, so set it up front.
PLUGIN_DIR="$(defaults read "$SWIFTBAR_ID" PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [[ -z "$PLUGIN_DIR" || ! -d "$PLUGIN_DIR" ]]; then
  PLUGIN_DIR="$DEFAULT_PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  pkill -x SwiftBar 2>/dev/null && sleep 1  # it would overwrite the setting on quit
  defaults write "$SWIFTBAR_ID" PluginDirectory "$PLUGIN_DIR"
  echo "Set SwiftBar's plugin folder to $PLUGIN_DIR"
fi

# 3. Claude Code statusLine -> bridge
chmod +x "$BRIDGE" "$PLUGIN" "$ROOT/bridge/probe.py"
python3 "$ROOT/bridge/setup_settings.py" install "$SETTINGS" "$BRIDGE"

# 4. Plugin
ln -sf "$PLUGIN" "$PLUGIN_DIR/claude-usage.5m.py"
echo "Linked plugin into $PLUGIN_DIR"
if pgrep -xq SwiftBar; then
  open -g "swiftbar://refreshallplugins"
else
  open -a "$SWIFTBAR_APP"
fi

cat <<EOF

Done. The menu bar shows your 5-hour and weekly Claude limits (Pro/Max plans).
- First reading: send a message in Claude Code, or open the menu and pick Check now.
- Auto-check: while your 5-hour window is open or you're using Claude Code, a tiny
  Haiku request (about 900 tokens) runs at most every 5 minutes to keep the numbers
  fresh. Turn it off with Pause auto-check in the menu.
- Can't see it? A menu bar manager (Bartender, Ice) may be hiding it, or a notch.
- To start SwiftBar at login, turn on Launch at Login in its preferences.
EOF
