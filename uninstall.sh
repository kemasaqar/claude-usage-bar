#!/usr/bin/env bash
# Removes Claude Usage Bar:
#
#   curl -fsSL https://raw.githubusercontent.com/kemasaqar/claude-usage-bar/swift/uninstall.sh | bash
#
# Puts back the status line you had before (or removes ours), removes the
# login item and deletes the app. Your readings stay in ~/.cache/claude-usage-bar.
set -euo pipefail

APP_NAME="ClaudeUsageBar.app"
if [[ -n "${CLAUDE_USAGE_BAR_APP_DIR:-}" ]]; then
  DIRS=("$CLAUDE_USAGE_BAR_APP_DIR")
else
  DIRS=(/Applications "$HOME/Applications")
fi
APP=""
for dir in "${DIRS[@]}"; do
  if [[ -d "$dir/$APP_NAME" ]]; then APP="$dir/$APP_NAME"; break; fi
done

pkill -x ClaudeUsageBar 2>/dev/null || true

if [[ -n "$APP" ]]; then
  "$APP/Contents/MacOS/ClaudeUsageBar" uninstall
  rm -rf "$APP"
  echo "Removed $APP"
else
  echo "$APP_NAME not found in /Applications or ~/Applications."
  echo "If you moved it, run: /path/to/$APP_NAME/Contents/MacOS/ClaudeUsageBar uninstall"
fi
echo "Readings and auto-check state left at ~/.cache/claude-usage-bar (delete it if you like)."
