#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

ROOT="${0:A:h}"
APP_DEST="$HOME/Applications/ThreadHelm.app"
LEGACY_APP_DEST="$HOME/Applications/ChatBird.app"
OLDER_LEGACY_APP_DEST="$HOME/Applications/ChatBird 额度面板.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ThreadHelm"
PACKAGE_BINARY="$ROOT/ThreadHelm.app/Contents/MacOS/ThreadHelm"
LEGACY_APP_BINARY="$LEGACY_APP_DEST/Contents/MacOS/ChatBird"
OLDER_LEGACY_APP_BINARY="$OLDER_LEGACY_APP_DEST/Contents/MacOS/ChatBirdQuotaPanel"
LABEL="dev.threadhelm.app"
LEGACY_LABEL="dev.chatbird.app"
OLDER_LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST_DEST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
OLDER_LEGACY_PLIST_DEST="$HOME/Library/LaunchAgents/$OLDER_LEGACY_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/ThreadHelm.log"
LEGACY_LOG_PATH="$HOME/Library/Logs/ChatBird.log"
OLDER_LEGACY_LOG_PATH="$HOME/Library/Logs/ChatBird额度面板.log"
OLDER_LEGACY_ALT_LOG_PATH="$HOME/Library/Logs/ChatBirdQuotaPanel.log"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
OLDER_LEGACY_HEALTH_DIR="$HOME/Library/Caches/$OLDER_LEGACY_LABEL"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE_PATH="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/threadhelm-native-notification-backup.json"
LEGACY_NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
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
  backup="$CONFIG.threadhelm-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
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

for label in "$LABEL" "$LEGACY_LABEL" "$OLDER_LEGACY_LABEL"; do
  /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
/usr/bin/pkill -x ThreadHelm 2>/dev/null || true
/usr/bin/pkill -x ChatBird 2>/dev/null || true
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true

CLEANUP_BINARY=""
for candidate in \
  "$PACKAGE_BINARY" \
  "$APP_BINARY" \
  "$LEGACY_APP_BINARY" \
  "$OLDER_LEGACY_APP_BINARY"; do
  if [[ -x "$candidate" ]]; then
    CLEANUP_BINARY="$candidate"
    break
  fi
done
if [[ -z "$CLEANUP_BINARY" ]]; then
  echo "找不到可用于安全移除五 Agent 受管集成的 ThreadHelm 程序；已停止卸载。"
  exit 1
else
  INTEGRATION_REPORT="$(
    "$CLEANUP_BINARY" --agent-integrations uninstall --live
  )" \
    || {
      echo "无法安全卸载 Claude、Cursor、ZCode 和 OMP 的受管集成，已停止卸载。"
      exit 1
    }
  INTEGRATION_BACKUP_ID="$(
    print -r -- "$INTEGRATION_REPORT" \
      | /usr/bin/plutil -extract backupID raw -o - - 2>/dev/null
  )" || {
    echo "无法读取五 Agent 本机集成恢复点，已停止卸载。"
    exit 1
  }
fi

RESTORE_BACKUP=""
if [[ -f "$NATIVE_NOTIFICATION_BACKUP" ]]; then
  RESTORE_BACKUP="$NATIVE_NOTIFICATION_BACKUP"
elif [[ -f "$LEGACY_NATIVE_NOTIFICATION_BACKUP" ]]; then
  RESTORE_BACKUP="$LEGACY_NATIVE_NOTIFICATION_BACKUP"
fi
if [[ -n "$RESTORE_BACKUP" ]]; then
  if [[ -z "$CLEANUP_BINARY" ]]; then
    echo "找不到可用于恢复 Codex 原生气泡设置的 ThreadHelm 或旧 ChatBird 程序；已停止卸载并保留恢复文件。"
    exit 1
  fi
  "$CLEANUP_BINARY" \
    --restore-codex-overlay-notifications \
    "$STATE_PATH" \
    "$RESTORE_BACKUP" \
    || {
      if [[ -n "${INTEGRATION_BACKUP_ID:-}" ]]; then
        "$CLEANUP_BINARY" --agent-integrations restore \
          "$INTEGRATION_BACKUP_ID" --live || true
      fi
      echo "无法恢复 Codex 原生气泡设置，受管 Agent 集成已尽量还原；已停止卸载以保留恢复文件。"
      exit 1
    }
fi

remove_legacy_codex_pet_selection

/bin/rm -f \
  "$PLIST_DEST" \
  "$LEGACY_PLIST_DEST" \
  "$OLDER_LEGACY_PLIST_DEST" \
  "$LOG_PATH" \
  "$LEGACY_LOG_PATH" \
  "$OLDER_LEGACY_LOG_PATH" \
  "$OLDER_LEGACY_ALT_LOG_PATH" \
  "$NATIVE_NOTIFICATION_BACKUP" \
  "$LEGACY_NATIVE_NOTIFICATION_BACKUP"
/bin/rm -rf \
  "$APP_DEST" \
  "$LEGACY_APP_DEST" \
  "$OLDER_LEGACY_APP_DEST" \
  "$HEALTH_DIR" \
  "$LEGACY_HEALTH_DIR" \
  "$OLDER_LEGACY_HEALTH_DIR"

echo "ThreadHelm、旧 ChatBird 产品文件与原生气泡设置已卸载。旧 ~/.codex/pets/chatbird-nt 未被删除。"
if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
