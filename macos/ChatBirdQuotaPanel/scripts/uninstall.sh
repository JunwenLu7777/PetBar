#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DOMAIN="gui/$(id -u)"
LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$ROOT/build/ChatBird 额度面板.app"
APP_SHORTCUT="$HOME/Applications/ChatBird 额度面板.app"
BIN="$APP/Contents/MacOS/ChatBirdQuotaPanel"
SHORTCUT_BIN="$APP_SHORTCUT/Contents/MacOS/ChatBirdQuotaPanel"
HEALTH="$HOME/Library/Caches/$LABEL/panel-health.json"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"

if /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
  || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1
then
  echo "请先完全退出 Codex，再重新运行卸载程序。" >&2
  exit 1
fi

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [[ -x "$BIN" || -x "$SHORTCUT_BIN" ]]; then
  CLEANUP_BIN="$BIN"
  [[ -x "$CLEANUP_BIN" ]] || CLEANUP_BIN="$SHORTCUT_BIN"
  "$CLEANUP_BIN" --uninstall-claude-hook
  "$CLEANUP_BIN" \
    --restore-codex-overlay-notifications \
    "$STATE" \
    "$NATIVE_NOTIFICATION_BACKUP"
fi
/bin/rm -f "$PLIST" "$HEALTH"
/bin/rm -rf "$APP" "$APP_SHORTCUT"
echo "ChatBird 额度面板已卸载"
