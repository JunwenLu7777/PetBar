#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

PET_DEST="${CODEX_HOME:-$HOME/.codex}/pets/chatbird-nt"
APP_DEST="$HOME/Applications/ChatBird 额度面板.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ChatBirdQuotaPanel"
LABEL="dev.chatbird.codex-quota-panel"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/ChatBird额度面板.log"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE_PATH="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"

if /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
  || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1
then
  echo "请先完全退出 Codex，再重新运行卸载程序；当前安装和恢复文件均未改动。"
  exit 1
fi

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true
if [[ -x "$APP_BINARY" ]]; then
  "$APP_BINARY" --uninstall-claude-hook \
    || {
      echo "无法移除 Claude Code 权限确认 Hook，已停止卸载。"
      exit 1
    }
  "$APP_BINARY" \
    --restore-codex-overlay-notifications \
    "$STATE_PATH" \
    "$NATIVE_NOTIFICATION_BACKUP" \
    || {
      echo "无法恢复 Codex 原生气泡设置，已停止卸载以保留恢复文件。"
      exit 1
    }
fi
/bin/rm -f "$PLIST_DEST"
/bin/rm -rf "$APP_DEST" "$PET_DEST" "$HEALTH_DIR"
/bin/rm -f "$LOG_PATH"

if [[ -f "$CONFIG" ]]; then
  TMP_CONFIG="$(/usr/bin/mktemp "$CONFIG.tmp.XXXXXX")"
  /usr/bin/awk '
    BEGIN { section = "" }
    /^[[:space:]]*\[[^]]+\]/ {
      section = ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) ? "desktop" : "other"
      print
      next
    }
    section == "desktop" && /^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"/ { next }
    { print }
  ' "$CONFIG" > "$TMP_CONFIG"
  /bin/mv "$TMP_CONFIG" "$CONFIG"
fi

echo "ChatBird 宠物、额度面板和原生气泡设置已卸载。重新打开 Codex 后生效。"
if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
