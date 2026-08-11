#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

APP_DEST="$HOME/Applications/ChatBird.app"
LEGACY_APP_DEST="$HOME/Applications/ChatBird 额度面板.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ChatBird"
LEGACY_APP_BINARY="$LEGACY_APP_DEST/Contents/MacOS/ChatBirdQuotaPanel"
LABEL="dev.chatbird.app"
LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST_DEST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/ChatBird.log"
LEGACY_LOG_PATH="$HOME/Library/Logs/ChatBird额度面板.log"
LEGACY_ALT_LOG_PATH="$HOME/Library/Logs/ChatBirdQuotaPanel.log"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE_PATH="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"

remove_legacy_codex_pet_selection() {
  [[ -f "$CONFIG" ]] || return 0
  /usr/bin/awk '
    BEGIN { section = ""; found = 0 }
    /^[[:space:]]*\[[^]]+\]/ {
      section = ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) ? "desktop" : "other"
    }
    section == "desktop" && /^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"/ {
      found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$CONFIG" || return 0

  local backup
  local tmp_config
  backup="$CONFIG.chatbird-backup-$(date +%Y%m%d-%H%M%S)"
  tmp_config="$(/usr/bin/mktemp "$CONFIG.tmp.XXXXXX")"
  /bin/cp -p "$CONFIG" "$backup"
  /usr/bin/awk '
    BEGIN { section = "" }
    /^[[:space:]]*\[[^]]+\]/ {
      section = ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) ? "desktop" : "other"
      print
      next
    }
    section == "desktop" && /^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"/ { next }
    { print }
  ' "$CONFIG" > "$tmp_config"
  /bin/mv "$tmp_config" "$CONFIG"
  echo "已备份并移除旧 Codex 宠物选择：$backup"
}

if /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
  || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1
then
  echo "请先完全退出 Codex，再重新运行卸载程序；当前安装和恢复文件均未改动。"
  exit 1
fi

for label in "$LABEL" "$LEGACY_LABEL"; do
  /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
/usr/bin/pkill -x ChatBird 2>/dev/null || true
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true

CLEANUP_BINARY=""
for candidate in "$APP_BINARY" "$LEGACY_APP_BINARY"; do
  if [[ -x "$candidate" ]]; then
    CLEANUP_BINARY="$candidate"
    break
  fi
done
if [[ -n "$CLEANUP_BINARY" ]]; then
  "$CLEANUP_BINARY" --uninstall-claude-hook \
    || {
      echo "无法移除 Claude Code 权限确认 Hook，已停止卸载。"
      exit 1
    }
  "$CLEANUP_BINARY" \
    --restore-codex-overlay-notifications \
    "$STATE_PATH" \
    "$NATIVE_NOTIFICATION_BACKUP" \
    || {
      echo "无法恢复 Codex 原生气泡设置，已停止卸载以保留恢复文件。"
      exit 1
    }
fi

remove_legacy_codex_pet_selection

/bin/rm -f "$PLIST_DEST" "$LEGACY_PLIST_DEST"
/bin/rm -rf "$APP_DEST" "$LEGACY_APP_DEST" "$HEALTH_DIR" "$LEGACY_HEALTH_DIR"
/bin/rm -f "$LOG_PATH" "$LEGACY_LOG_PATH" "$LEGACY_ALT_LOG_PATH"

echo "ChatBird 独立 App 与原生气泡设置已卸载。旧 ~/.codex/pets/chatbird-nt 未被删除。"
if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
