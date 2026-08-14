#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DOMAIN="gui/$(id -u)"
LABEL="dev.threadhelm.app"
LEGACY_LABEL="dev.chatbird.app"
OLDER_LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
OLDER_LEGACY_PLIST="$HOME/Library/LaunchAgents/$OLDER_LEGACY_LABEL.plist"
BUILD_APP="$ROOT/build/ThreadHelm.app"
INSTALLED_APP="$HOME/Applications/ThreadHelm.app"
LEGACY_APP="$HOME/Applications/ChatBird.app"
OLDER_LEGACY_APP="$HOME/Applications/ChatBird 额度面板.app"
BUILD_BIN="$BUILD_APP/Contents/MacOS/ThreadHelm"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/ThreadHelm"
LEGACY_BIN="$LEGACY_APP/Contents/MacOS/ChatBird"
OLDER_LEGACY_BIN="$OLDER_LEGACY_APP/Contents/MacOS/ChatBirdQuotaPanel"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
OLDER_LEGACY_HEALTH_DIR="$HOME/Library/Caches/$OLDER_LEGACY_LABEL"
LOG="$HOME/Library/Logs/ThreadHelm.log"
LEGACY_LOG="$HOME/Library/Logs/ChatBird.log"
OLDER_LEGACY_LOG="$HOME/Library/Logs/ChatBird额度面板.log"
OLDER_LEGACY_ALT_LOG="$HOME/Library/Logs/ChatBirdQuotaPanel.log"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/threadhelm-native-notification-backup.json"
LEGACY_NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"

detach_legacy_codex_pet_selection() {
  [[ -f "$CONFIG" ]] || return 0
  /usr/bin/grep -Eq \
    '^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"' \
    "$CONFIG" || return 0

  /bin/cp -p "$CONFIG" "$CONFIG.threadhelm-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
  local temporary_config
  temporary_config="$(/usr/bin/mktemp "$CONFIG.tmp.XXXXXX")"
  /usr/bin/awk '
    BEGIN { section = "" }
    /^[[:space:]]*\[[^]]+\]/ {
      section = ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) ? "desktop" : "other"
      print
      next
    }
    section == "desktop" && /^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"/ { next }
    { print }
  ' "$CONFIG" > "$temporary_config"
  /bin/mv "$temporary_config" "$CONFIG"
}

if /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
  || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1
then
  echo "请先完全退出 Codex，再重新运行卸载程序。" >&2
  exit 1
fi

for label in "$LABEL" "$LEGACY_LABEL" "$OLDER_LEGACY_LABEL"; do
  /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
/usr/bin/pkill -x ThreadHelm 2>/dev/null || true
/usr/bin/pkill -x ChatBird 2>/dev/null || true
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true

CLEANUP_BIN=""
for candidate in \
  "$BUILD_BIN" \
  "$INSTALLED_BIN" \
  "$LEGACY_BIN" \
  "$OLDER_LEGACY_BIN"; do
  if [[ -x "$candidate" ]]; then
    CLEANUP_BIN="$candidate"
    break
  fi
done
if [[ -z "$CLEANUP_BIN" ]]; then
  echo "找不到可用于安全移除五 Agent 受管集成的 ThreadHelm 程序。" >&2
  exit 1
else
  INTEGRATION_REPORT="$(
    "$CLEANUP_BIN" --agent-integrations uninstall --live
  )" || {
    echo "无法安全卸载 Claude、Cursor、ZCode 和 OMP 的受管集成。" >&2
    exit 1
  }
  INTEGRATION_BACKUP_ID="$(
    print -r -- "$INTEGRATION_REPORT" \
      | /usr/bin/plutil -extract backupID raw -o - - 2>/dev/null
  )" || {
    echo "无法读取五 Agent 本机集成恢复点。" >&2
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
  if [[ -z "$CLEANUP_BIN" ]]; then
    echo "找不到可用于恢复 Codex 原生气泡设置的 ThreadHelm 或旧 ChatBird 程序。" >&2
    exit 1
  fi
  if ! "$CLEANUP_BIN" \
    --restore-codex-overlay-notifications \
    "$STATE" \
    "$RESTORE_BACKUP"
  then
    if [[ -n "${INTEGRATION_BACKUP_ID:-}" ]]; then
      "$CLEANUP_BIN" --agent-integrations restore \
        "$INTEGRATION_BACKUP_ID" --live || true
    fi
    echo "无法恢复 Codex 原生气泡设置；受管 Agent 集成已尽量还原。" >&2
    exit 1
  fi
fi

detach_legacy_codex_pet_selection

/bin/rm -f \
  "$PLIST" \
  "$LEGACY_PLIST" \
  "$OLDER_LEGACY_PLIST" \
  "$LOG" \
  "$LEGACY_LOG" \
  "$OLDER_LEGACY_LOG" \
  "$OLDER_LEGACY_ALT_LOG" \
  "$NATIVE_NOTIFICATION_BACKUP" \
  "$LEGACY_NATIVE_NOTIFICATION_BACKUP"
/bin/rm -rf \
  "$INSTALLED_APP" \
  "$LEGACY_APP" \
  "$OLDER_LEGACY_APP" \
  "$HEALTH_DIR" \
  "$LEGACY_HEALTH_DIR" \
  "$OLDER_LEGACY_HEALTH_DIR"
echo "ThreadHelm 与旧 ChatBird 产品文件已卸载"
