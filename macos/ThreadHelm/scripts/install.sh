#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TRANSACTION_HELPER="$ROOT/scripts/local-install-transaction.zsh"
BUILD_APP="$ROOT/build/ThreadHelm.app"
INSTALLED_APP="$HOME/Applications/ThreadHelm.app"
APP_BINARY="$INSTALLED_APP/Contents/MacOS/ThreadHelm"
LABEL="dev.threadhelm.app"
LEGACY_LABEL="dev.chatbird.app"
OLDER_LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
OLDER_LEGACY_PLIST="$HOME/Library/LaunchAgents/$OLDER_LEGACY_LABEL.plist"
LOG="$HOME/Library/Logs/ThreadHelm.log"
LEGACY_LOG="$HOME/Library/Logs/ChatBird.log"
OLDER_LEGACY_LOG="$HOME/Library/Logs/ChatBird额度面板.log"
OLDER_LEGACY_ALT_LOG="$HOME/Library/Logs/ChatBirdQuotaPanel.log"
HEALTH="$HOME/Library/Caches/$LABEL/panel-health.json"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
OLDER_LEGACY_HEALTH_DIR="$HOME/Library/Caches/$OLDER_LEGACY_LABEL"
LEGACY_APP="$HOME/Applications/ChatBird.app"
OLDER_LEGACY_APP="$HOME/Applications/ChatBird 额度面板.app"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
SESSION_INDEX="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/threadhelm-native-notification-backup.json"
LEGACY_NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"

[[ -f "$TRANSACTION_HELPER" ]] || {
  echo "缺少 ThreadHelm 本机安装事务脚本" >&2
  exit 1
}
source "$TRANSACTION_HELPER"
THREADHELM_APP_DEST="$INSTALLED_APP"
THREADHELM_PLIST_DEST="$PLIST"
THREADHELM_HEALTH_DIR="${HEALTH:h}"
THREADHELM_STATE_PATH="$STATE"
THREADHELM_NATIVE_BACKUP_PATH="$NATIVE_NOTIFICATION_BACKUP"
THREADHELM_LEGACY_NATIVE_BACKUP_PATH="$LEGACY_NATIVE_NOTIFICATION_BACKUP"
THREADHELM_DOMAIN="$DOMAIN"
THREADHELM_LABEL="$LABEL"
THREADHELM_RECOVERY_BINARY="$APP_BINARY"

stop_service_and_processes() {
  local label
  for label in "$LABEL" "$LEGACY_LABEL" "$OLDER_LEGACY_LABEL"; do
    /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  done
  /usr/bin/pkill -x ThreadHelm 2>/dev/null || true
  /usr/bin/pkill -x ChatBird 2>/dev/null || true
  /usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true
  for _ in {1..20}; do
    ! /usr/bin/pgrep -x ThreadHelm >/dev/null 2>&1 \
      && ! /usr/bin/pgrep -x ChatBird >/dev/null 2>&1 \
      && ! /usr/bin/pgrep -x ChatBirdQuotaPanel >/dev/null 2>&1 \
      && return 0
    /bin/sleep 0.1
  done
  echo "无法停止现有 ThreadHelm 或旧 ChatBird 进程" >&2
  exit 1
}

migrate_notification_backup() {
  if [[ ! -e "$NATIVE_NOTIFICATION_BACKUP" \
        && -f "$LEGACY_NATIVE_NOTIFICATION_BACKUP" ]]; then
    /bin/mv "$LEGACY_NATIVE_NOTIFICATION_BACKUP" "$NATIVE_NOTIFICATION_BACKUP"
  fi
}

detach_legacy_codex_pet_selection() {
  [[ -f "$CONFIG" ]] || return 0
  /usr/bin/grep -Eq \
    '^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"' \
    "$CONFIG" || return 0

  /bin/cp -p \
    "$CONFIG" \
    "$CONFIG.threadhelm-migration-backup-$(date +%Y%m%d-%H%M%S)"
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

cleanup_legacy_products() {
  /bin/rm -rf \
    "$LEGACY_APP" \
    "$OLDER_LEGACY_APP" \
    "$LEGACY_HEALTH_DIR" \
    "$OLDER_LEGACY_HEALTH_DIR"
  /bin/rm -f \
    "$LEGACY_PLIST" \
    "$OLDER_LEGACY_PLIST" \
    "$LEGACY_LOG" \
    "$OLDER_LEGACY_LOG" \
    "$OLDER_LEGACY_ALT_LOG" \
    "$LEGACY_NATIVE_NOTIFICATION_BACKUP"
  detach_legacy_codex_pet_selection
}

wait_for_panel_health() {
  for _ in {1..80}; do
    if [[ -s "$HEALTH" ]] \
      && /usr/bin/grep -q '"edition":"threadhelm"' "$HEALTH" \
      && /usr/bin/grep -q '"productID":"threadhelm"' "$HEALTH" \
      && /usr/bin/grep -q '"claudeQuotaPeriods":\["5h","weekly","fable"\]' "$HEALTH" \
      && /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
        | /usr/bin/grep -Fq "program = $APP_BINARY"
    then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

"$ROOT/scripts/build.sh" >/dev/null
/usr/bin/codesign --verify --deep --strict "$BUILD_APP"
mkdir -p \
  "$HOME/Applications" \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Logs" \
  "${HEALTH:h}"

threadhelm_begin_install_transaction
trap 'threadhelm_rollback_install_transaction' EXIT
trap 'exit 130' INT TERM
stop_service_and_processes
migrate_notification_backup

/bin/rm -rf "$INSTALLED_APP" "${HEALTH:h}"
/bin/rm -f "$PLIST"
mkdir -p "${HEALTH:h}"
/usr/bin/ditto "$BUILD_APP" "$INSTALLED_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"

INTEGRATION_REPORT=""
if ! INTEGRATION_REPORT="$(
  "$APP_BINARY" --agent-integrations install --live
)"; then
  echo "五 Agent 本机集成安装失败" >&2
  exit 1
fi
threadhelm_set_integration_backup_id "$INTEGRATION_REPORT" || {
  echo "无法读取五 Agent 本机集成恢复点" >&2
  exit 1
}
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
/usr/bin/plutil -lint "$PLIST" >/dev/null
if [[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null)" != "$APP_BINARY" ]] \
  || /usr/bin/plutil -extract ProgramArguments.1 raw "$PLIST" >/dev/null 2>&1
then
  echo "ThreadHelm 登录启动项包含无效或多余的启动参数" >&2
  exit 1
fi

/bin/rm -f "$HEALTH"
if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST"; then
  /bin/sleep 1
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL"

if ! wait_for_panel_health; then
  echo "ThreadHelm 未能从独立安装路径启动" >&2
  exit 1
fi

threadhelm_commit_install_transaction
trap - EXIT INT TERM
cleanup_legacy_products
echo "$INSTALLED_APP"
