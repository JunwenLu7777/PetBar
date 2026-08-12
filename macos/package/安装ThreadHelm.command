#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

ROOT="${0:A:h}"
TRANSACTION_HELPER="$ROOT/local-install-transaction.zsh"
if [[ ! -f "$TRANSACTION_HELPER" ]]; then
  TRANSACTION_HELPER="${ROOT:h}/ThreadHelm/scripts/local-install-transaction.zsh"
fi
APP_SOURCE="$ROOT/ThreadHelm.app"
APP_DEST="$HOME/Applications/ThreadHelm.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ThreadHelm"
SOURCE_BINARY="$APP_SOURCE/Contents/MacOS/ThreadHelm"
LABEL="dev.threadhelm.app"
LEGACY_LABEL="dev.chatbird.app"
OLDER_LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST_SOURCE="$ROOT/$LABEL.plist.in"
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
HEALTH_PATH="$HEALTH_DIR/panel-health.json"
LEGACY_APP="$HOME/Applications/ChatBird.app"
OLDER_LEGACY_APP="$HOME/Applications/ChatBird 额度面板.app"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE_PATH="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
SESSION_INDEX_PATH="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/threadhelm-native-notification-backup.json"
LEGACY_NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"
VERIFY_ONLY=false

[[ -f "$TRANSACTION_HELPER" ]] || {
  echo "安装包缺少本机安装事务脚本。"
  exit 1
}
source "$TRANSACTION_HELPER"
THREADHELM_APP_DEST="$APP_DEST"
THREADHELM_PLIST_DEST="$PLIST_DEST"
THREADHELM_HEALTH_DIR="$HEALTH_DIR"
THREADHELM_STATE_PATH="$STATE_PATH"
THREADHELM_NATIVE_BACKUP_PATH="$NATIVE_NOTIFICATION_BACKUP"
THREADHELM_LEGACY_NATIVE_BACKUP_PATH="$LEGACY_NATIVE_NOTIFICATION_BACKUP"
THREADHELM_DOMAIN="$DOMAIN"
THREADHELM_LABEL="$LABEL"
THREADHELM_RECOVERY_BINARY="$APP_BINARY"

for ARG in "$@"; do
  case "$ARG" in
    --verify-only) VERIFY_ONLY=true ;;
    *)
      echo "未知参数：$ARG"
      exit 2
      ;;
  esac
done

pause_before_exit() {
  if [[ -t 0 ]]; then
    echo ""
    read -k 1 "?按任意键关闭…"
    echo ""
  fi
}

fail() {
  echo ""
  echo "安装失败：$1"
  if [[ -s "$LOG_PATH" ]]; then
    echo ""
    echo "ThreadHelm 日志最后 12 行："
    /usr/bin/tail -n 12 "$LOG_PATH" 2>/dev/null || true
  fi
  pause_before_exit
  exit 1
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null || true
}

service_has_pid() {
  local label="$1"
  /bin/launchctl print "$DOMAIN/$label" 2>/dev/null \
    | /usr/bin/grep -Eq '^[[:space:]]*pid = [0-9]+'
}

panel_health_is_current() {
  [[ -s "$HEALTH_PATH" ]] \
    && /usr/bin/grep -q '"edition":"threadhelm"' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"productID":"threadhelm"' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"codexWeeklyQuotaOnly":true' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"claudeQuotaPeriods":\["5h","weekly","fable"\]' "$HEALTH_PATH" 2>/dev/null
}

wait_for_panel_health() {
  local attempt
  for attempt in {1..80}; do
    if service_has_pid "$LABEL" && panel_health_is_current; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

assert_package_is_complete() {
  [[ -d "$APP_SOURCE" && -x "$SOURCE_BINARY" && -f "$PLIST_SOURCE" \
      && -f "$TRANSACTION_HELPER" ]] \
    || fail "ThreadHelm.app、登录启动项模板或事务脚本不完整，请重新解压整个分享包。"
  /usr/bin/lipo "$SOURCE_BINARY" -verify_arch arm64 \
    || fail "ThreadHelm.app 不包含 arm64 架构。"
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE" >/dev/null 2>&1 \
    || fail "ThreadHelm.app 签名校验失败，请重新解压整个分享包。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleIdentifier)" == "$LABEL" ]] \
    || fail "ThreadHelm.app 的 Bundle ID 必须是 $LABEL。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleExecutable)" == "ThreadHelm" ]] \
    || fail "ThreadHelm.app 的可执行程序必须是 ThreadHelm。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" LSUIElement)" != "1" ]] \
    || fail "ThreadHelm.app 不能是后台 LSUIElement 应用。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleIconFile)" == "ThreadHelm.icns" ]] \
    || fail "ThreadHelm.app 缺少自己的 App Icon。"
  [[ "$(plist_value "$PLIST_SOURCE" Label)" == "$LABEL" ]] \
    || fail "登录启动项模板 Label 必须是 $LABEL。"
  [[ "$(plist_value "$PLIST_SOURCE" ProgramArguments.0)" == "__EXECUTABLE__" ]] \
    && ! /usr/bin/plutil -extract ProgramArguments.1 raw "$PLIST_SOURCE" >/dev/null 2>&1 \
    || fail "登录启动项模板必须且只能包含一个可执行程序参数。"
  /usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null \
    || fail "登录启动项模板无效。"
  local unmanaged_artifact
  for unmanaged_artifact in .claude .cursor .zcode .pi; do
    [[ ! -e "$ROOT/$unmanaged_artifact" ]] \
      || fail "安装包不得携带厂商配置或未受管 Hook：$unmanaged_artifact"
  done
}

stop_service_and_processes() {
  local label
  for label in "$LABEL" "$LEGACY_LABEL" "$OLDER_LEGACY_LABEL"; do
    /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    for _ in {1..20}; do
      /bin/launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
      /bin/sleep 0.1
    done
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
  fail "无法停止现有 ThreadHelm 或旧 ChatBird 进程。"
}

migrate_notification_backup() {
  if [[ ! -e "$NATIVE_NOTIFICATION_BACKUP" \
        && -f "$LEGACY_NATIVE_NOTIFICATION_BACKUP" ]]; then
    /bin/mv "$LEGACY_NATIVE_NOTIFICATION_BACKUP" "$NATIVE_NOTIFICATION_BACKUP"
  fi
}

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
  local temporary_config
  backup="$CONFIG.threadhelm-migration-backup-$(date +%Y%m%d-%H%M%S)"
  temporary_config="$(/usr/bin/mktemp "$CONFIG.tmp.XXXXXX")"
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
  ' "$CONFIG" > "$temporary_config"
  /bin/mv "$temporary_config" "$CONFIG"
  echo "已备份并移除旧 Codex 宠物选择：$backup"
}

cleanup_legacy_products() {
  /bin/rm -rf \
    "$LEGACY_APP" \
    "$OLDER_LEGACY_APP" \
    "$LEGACY_HEALTH_DIR" \
    "$OLDER_LEGACY_HEALTH_DIR"
  /bin/rm -f \
    "$LEGACY_PLIST_DEST" \
    "$OLDER_LEGACY_PLIST_DEST" \
    "$LEGACY_LOG_PATH" \
    "$OLDER_LEGACY_LOG_PATH" \
    "$OLDER_LEGACY_ALT_LOG_PATH" \
    "$LEGACY_NATIVE_NOTIFICATION_BACKUP"
  remove_legacy_codex_pet_selection
}

echo "正在校验 ThreadHelm 安装包…"
assert_package_is_complete
if [[ "$VERIFY_ONLY" == "true" ]]; then
  echo "校验通过：ThreadHelm 独立 App 安装包完整。"
  pause_before_exit
  exit 0
fi

MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
MACOS_REMAINDER="${MACOS_VERSION#*.}"
MACOS_MINOR="${MACOS_REMAINDER%%.*}"
if (( MACOS_MAJOR < 12 || (MACOS_MAJOR == 12 && MACOS_MINOR < 3) )); then
  fail "需要 macOS 12.3 或更高版本，当前版本为 $MACOS_VERSION。"
fi
ARCH="$(/usr/bin/uname -m)"
[[ "$ARCH" == "arm64" ]] \
  || fail "当前版本只支持 Apple 芯片（arm64）；本机架构为 $ARCH。"
/usr/bin/lipo "$SOURCE_BINARY" -verify_arch "$ARCH" \
  || fail "ThreadHelm.app 不包含 $ARCH 架构。"

mkdir -p \
  "$HOME/Applications" \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Logs" \
  "$HEALTH_DIR" \
  "${CONFIG:h}"

threadhelm_begin_install_transaction
trap 'threadhelm_rollback_install_transaction' EXIT
trap 'exit 130' INT TERM
stop_service_and_processes
migrate_notification_backup

/bin/rm -rf "$APP_DEST" "$HEALTH_DIR"
/bin/rm -f "$PLIST_DEST"
mkdir -p "$HEALTH_DIR"
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/usr/bin/xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DEST" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_DEST" \
  || fail "ThreadHelm.app 自动签名失败，请重新下载分享包。"

INTEGRATION_REPORT=""
INTEGRATION_REPORT="$(
  "$APP_BINARY" --agent-integrations install --live
)" || fail "无法安全安装 Claude、Cursor、ZCode 和 Pi 的受管集成。"
threadhelm_set_integration_backup_id "$INTEGRATION_REPORT" \
  || fail "无法读取五 Agent 本机集成恢复点。"
"$APP_BINARY" \
  --prepare-codex-overlay-notifications \
  "$STATE_PATH" \
  "$SESSION_INDEX_PATH" \
  "$NATIVE_NOTIFICATION_BACKUP" \
  || fail "无法准备 Codex 原生任务气泡的静音状态。"
/bin/rm -f "$HEALTH_PATH"

/bin/cp "$PLIST_SOURCE" "$PLIST_DEST"
/usr/bin/plutil -replace ProgramArguments -json '[]' "$PLIST_DEST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$APP_BINARY" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.THREADHELM_PANEL_HEALTH_FILE -string "$HEALTH_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.THREADHELM_CODEX_STATE_FILE -string "$STATE_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -lint "$PLIST_DEST" >/dev/null
if [[ "$(plist_value "$PLIST_DEST" ProgramArguments.0)" != "$APP_BINARY" ]] \
  || /usr/bin/plutil -extract ProgramArguments.1 raw "$PLIST_DEST" >/dev/null 2>&1
then
  fail "登录启动项包含无效或多余的启动参数。"
fi

if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST"; then
  /bin/sleep 1
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "无法注册 ThreadHelm 登录启动项。"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
  || fail "ThreadHelm 启动请求失败。"

if ! wait_for_panel_health; then
  echo "首次启动未通过自检，正在自动重试…"
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/sleep 0.5
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "ThreadHelm 重试注册失败。"
  /bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
    || fail "ThreadHelm 重试启动失败。"
  wait_for_panel_health \
    || fail "ThreadHelm 进程没有保持运行。请把上面的日志发给维护者。"
fi

threadhelm_commit_install_transaction
trap - EXIT INT TERM
cleanup_legacy_products

echo ""
echo "安装完成："
echo "  ✓ ThreadHelm 独立 App"
echo "  ✓ Codex、Claude、Cursor、ZCode 与 Pi 本机控制台"
echo "  ✓ 已清理旧 ChatBird App 与启动项"
echo "  ✓ 已启用 Codex 原生任务气泡静音同步"
echo "  ✓ 已处理四个受管集成；Codex 集成保持只读、不写配置"
if "$APP_BINARY" --check-accessibility >/dev/null 2>&1; then
  echo "  ✓ 当前运行中新任务气泡自动静音已启用"
else
  echo "  … 可在系统辅助功能设置中重新授权 ThreadHelm（不影响其他功能）"
fi
echo "  ✓ 随登录自动启动"
echo ""
echo "ThreadHelm 现在以独立 App 运行：可从 Dock、启动台或 ~/Applications/ThreadHelm.app 启动。"
echo "旧 ~/.codex/pets/chatbird-nt 不会被安装器删除。"
pause_before_exit
