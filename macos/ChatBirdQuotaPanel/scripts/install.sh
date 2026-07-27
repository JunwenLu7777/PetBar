#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/ChatBird 额度面板.app"
APP_BINARY="$APP/Contents/MacOS/ChatBirdQuotaPanel"
APP_SHORTCUT="$HOME/Applications/ChatBird 额度面板.app"
LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ChatBird额度面板.log"
HEALTH="$HOME/Library/Caches/$LABEL/panel-health.json"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
SESSION_INDEX="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"

"$ROOT/scripts/build.sh" >/dev/null
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "${HEALTH:h}"
/usr/bin/codesign --verify --deep --strict "$APP"
"$APP_BINARY" --install-claude-hook
"$APP_BINARY" \
  --prepare-codex-overlay-notifications \
  "$STATE" \
  "$SESSION_INDEX" \
  "$NATIVE_NOTIFICATION_BACKUP"

/usr/bin/sed \
  -e "s|__EXECUTABLE__|$APP_BINARY|g" \
  -e "s|__HEALTH_PATH__|$HEALTH|g" \
  -e "s|__STATE_PATH__|$STATE|g" \
  -e "s|__LOG_PATH__|$LOG|g" \
  "$ROOT/Resources/$LABEL.plist.in" > "$PLIST"

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/bin/rm -f "$HEALTH"
if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST"; then
  /bin/sleep 1
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL"

for _ in {1..80}; do
  if [[ -s "$HEALTH" ]] \
    && /usr/bin/grep -q '"claudeQuotaPeriods":\["5h","weekly","fable"\]' "$HEALTH" \
    && /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
      | /usr/bin/grep -Fq "program = $APP_BINARY"
  then
    /bin/mkdir -p "${APP_SHORTCUT:h}"
    /bin/rm -rf "$APP_SHORTCUT"
    /bin/ln -s "$APP" "$APP_SHORTCUT"
    echo "$APP"
    exit 0
  fi
  /bin/sleep 0.1
done

echo "ChatBird 额度面板未能从项目构建路径启动" >&2
exit 1
