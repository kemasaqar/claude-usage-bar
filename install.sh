#!/usr/bin/env bash
# Installs Claude Usage Bar from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/kemasaqar/claude-usage-bar/main/install.sh | bash
#
# Downloads the app, puts it in /Applications (or ~/Applications), points
# Claude Code's statusLine at it (keeping yours, if you have one), starts it
# at login, and opens it. Safe to re-run: that's also how you update.
#
# The app isn't notarized (no Apple Developer ID). Downloading with curl
# means macOS doesn't mark it as from the internet, so there's no warning.
set -euo pipefail

REPO="kemasaqar/claude-usage-bar"
# A URL or a local path to ClaudeUsageBar.zip (tests and local builds).
ZIP="${CLAUDE_USAGE_BAR_ZIP:-https://github.com/$REPO/releases/latest/download/ClaudeUsageBar.zip}"
APP_NAME="ClaudeUsageBar.app"

fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

# 1. Requirements
[[ "$(uname -s)" == Darwin ]] || fail "Claude Usage Bar only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "macOS 13 or newer is needed (you have $(sw_vers -productVersion))."

CLAUDE=""
for c in "$(command -v claude || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
         /opt/homebrew/bin/claude /usr/local/bin/claude; do
  if [[ -n "$c" && -x "$c" ]]; then CLAUDE="$c"; break; fi
done
[[ -n "$CLAUDE" ]] || echo "Warning: Claude Code (claude) not found. Install it, or auto-check can't run."

# 2. Download and unpack
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ "$ZIP" == http* ]]; then
  echo "Downloading $ZIP"
  curl -fsSL --retry 2 -o "$tmp/app.zip" "$ZIP" || fail "Download failed: $ZIP"
else
  cp "$ZIP" "$tmp/app.zip" || fail "Can't read $ZIP"
fi
ditto -x -k "$tmp/app.zip" "$tmp/unpacked" || fail "The download isn't a valid zip."
[[ -x "$tmp/unpacked/$APP_NAME/Contents/MacOS/ClaudeUsageBar" ]] \
  || fail "The download doesn't contain $APP_NAME."

# 3. Install, replacing any older copy
if [[ -n "${CLAUDE_USAGE_BAR_APP_DIR:-}" ]]; then
  APP_DIR="$CLAUDE_USAGE_BAR_APP_DIR"
  OLD_DIRS=("$APP_DIR")
else
  if [[ -w /Applications ]]; then APP_DIR="/Applications"; else APP_DIR="$HOME/Applications"; fi
  OLD_DIRS=(/Applications "$HOME/Applications")
fi
mkdir -p "$APP_DIR"
# Quit the running copy and wait until it's gone: a new copy that starts
# while the old one is still exiting thinks it's a duplicate and quits.
if pkill -x ClaudeUsageBar 2>/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x ClaudeUsageBar >/dev/null || break
    sleep 0.5
  done
fi
for dir in "${OLD_DIRS[@]}"; do
  if [[ -e "$dir/$APP_NAME" ]]; then rm -rf "${dir:?}/$APP_NAME"; fi
done
mv "$tmp/unpacked/$APP_NAME" "$APP_DIR/$APP_NAME"
APP="$APP_DIR/$APP_NAME"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Installed $APP"

# 4. statusLine + start at login
"$APP/Contents/MacOS/ClaudeUsageBar" setup

# 5. Switching from the SwiftBar version? Remove its plugin so you don't get
# two menu bar items. SwiftBar itself stays installed.
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"
if [[ -n "$PLUGIN_DIR" && -L "$PLUGIN_DIR/claude-usage.5m.py" ]]; then
  rm "$PLUGIN_DIR/claude-usage.5m.py"
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  echo "Removed the old SwiftBar plugin (SwiftBar itself is still installed)"
fi

open "$APP"

cat <<EOF

Done. The menu bar shows your 5-hour and weekly Claude limits (Pro/Max plans).
- First reading: send a message in Claude Code, or open the menu and pick Check now.
- Auto-check: while your 5-hour window is open or you're using Claude Code, a tiny
  Haiku request (about 900 tokens) runs at most every 5 minutes to keep the numbers
  fresh. Turn it off with Pause auto-check in the menu.
- Can't see it? Menu bar managers hide new items: Bartender puts them in Always
  Hidden, Ice in its hidden section. Move it to Shown in their settings. On a
  MacBook with a notch it can also end up behind the notch.
- Update: run the same install command again.
EOF
