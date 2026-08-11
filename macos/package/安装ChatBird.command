#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

ROOT="${0:A:h}"
APP_SOURCE="$ROOT/ChatBird.app"
APP_DEST="$HOME/Applications/ChatBird.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ChatBird"
SOURCE_BINARY="$APP_SOURCE/Contents/MacOS/ChatBird"
LABEL="dev.chatbird.app"
LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST_SOURCE="$ROOT/$LABEL.plist.in"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST_DEST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LOG_PATH="$HOME/Library/Logs/ChatBird.log"
LEGACY_LOG_PATH="$HOME/Library/Logs/ChatBird额度面板.log"
LEGACY_ALT_LOG_PATH="$HOME/Library/Logs/ChatBirdQuotaPanel.log"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
HEALTH_PATH="$HEALTH_DIR/panel-health.json"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STATE_PATH="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
SESSION_INDEX_PATH="${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
DOMAIN="gui/$(id -u)"
VERIFY_ONLY=false

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
    echo "ChatBird 日志最后 12 行："
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
    && /usr/bin/grep -q '"edition":"chatbird-nt"' "$HEALTH_PATH" 2>/dev/null \
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
  [[ -d "$APP_SOURCE" && -x "$SOURCE_BINARY" && -f "$PLIST_SOURCE" ]] \
    || fail "ChatBird.app 或登录启动项模板不完整，请重新解压整个分享包。"
  /usr/bin/lipo "$SOURCE_BINARY" -verify_arch arm64 \
    || fail "ChatBird.app 不包含 arm64 架构。"
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE" >/dev/null 2>&1 \
    || fail "ChatBird.app 签名校验失败，请重新解压整个分享包。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleIdentifier)" == "$LABEL" ]] \
    || fail "ChatBird.app 的 Bundle ID 必须是 $LABEL。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleExecutable)" == "ChatBird" ]] \
    || fail "ChatBird.app 的可执行程序必须是 ChatBird。"
  [[ "$(plist_value "$APP_SOURCE/Contents/Info.plist" LSUIElement)" != "1" ]] \
    || fail "ChatBird.app 不能是后台 LSUIElement 应用。"
  [[ -n "$(plist_value "$APP_SOURCE/Contents/Info.plist" CFBundleIconFile)" ]] \
    || fail "ChatBird.app 缺少自己的 App Icon。"
  [[ "$(plist_value "$PLIST_SOURCE" Label)" == "$LABEL" ]] \
    || fail "登录启动项模板 Label 必须是 $LABEL。"
  [[ "$(plist_value "$PLIST_SOURCE" ProgramArguments.0)" == "__EXECUTABLE__" ]] \
    && ! /usr/bin/plutil -extract ProgramArguments.1 raw "$PLIST_SOURCE" >/dev/null 2>&1 \
    || fail "登录启动项模板必须且只能包含一个可执行程序参数。"
  /usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null \
    || fail "登录启动项模板无效。"
}

stop_service_and_processes() {
  local label
  for label in "$LABEL" "$LEGACY_LABEL"; do
    /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    for _ in {1..20}; do
      /bin/launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
      /bin/sleep 0.1
    done
  done
  /usr/bin/pkill -x ChatBird 2>/dev/null || true
  /usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true
  for _ in {1..20}; do
    ! /usr/bin/pgrep -x ChatBird >/dev/null 2>&1 \
      && ! /usr/bin/pgrep -x ChatBirdQuotaPanel >/dev/null 2>&1 \
      && break
    /bin/sleep 0.1
  done
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

echo "正在校验 ChatBird 安装包…"
assert_package_is_complete
if [[ "$VERIFY_ONLY" == "true" ]]; then
  echo "校验通过：ChatBird 独立 App 安装包完整。"
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
  || fail "ChatBird.app 不包含 $ARCH 架构。"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HEALTH_DIR" "${CONFIG:h}"

stop_service_and_processes
remove_legacy_codex_pet_selection

/bin/rm -rf "$APP_DEST" "$HOME/Applications/ChatBird 额度面板.app" "$HEALTH_DIR" "$LEGACY_HEALTH_DIR"
/bin/rm -f \
  "$PLIST_DEST" \
  "$LEGACY_PLIST_DEST" \
  "$LEGACY_LOG_PATH" \
  "$LEGACY_ALT_LOG_PATH"
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/usr/bin/xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DEST" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_DEST" \
  || fail "ChatBird.app 自动签名失败，请重新下载分享包。"

CLAUDE_HOOK_STATUS="warning"
if ! "$APP_BINARY" --install-claude-hook; then
  echo "警告：Claude Code 权限确认 Hook 安装命令失败；ChatBird 核心安装将继续。" >&2
fi
CLAUDE_HOOK_STATUS_OUTPUT=""
if CLAUDE_HOOK_STATUS_OUTPUT="$("$APP_BINARY" --print-claude-hook-status)"; then
  case "$CLAUDE_HOOK_STATUS_OUTPUT" in
    installed*) CLAUDE_HOOK_STATUS="enabled" ;;
    unavailable) CLAUDE_HOOK_STATUS="skipped" ;;
    conflict*) CLAUDE_HOOK_STATUS="conflict" ;;
    *) CLAUDE_HOOK_STATUS="warning" ;;
  esac
else
  echo "警告：无法读取 Claude Code 权限确认 Hook 状态；ChatBird 核心安装将继续。" >&2
fi
"$APP_BINARY" \
  --prepare-codex-overlay-notifications \
  "$STATE_PATH" \
  "$SESSION_INDEX_PATH" \
  "$NATIVE_NOTIFICATION_BACKUP" \
  || fail "无法准备 Codex 原生任务气泡的静音状态。"
/bin/rm -f "$HEALTH_PATH"

/bin/cp "$PLIST_SOURCE" "$PLIST_DEST"
# `plutil -replace ProgramArguments.0` inserts before the existing array item
# on supported macOS versions. Rebuild the array so launchd receives exactly
# one argument: the standalone ChatBird executable.
/usr/bin/plutil -replace ProgramArguments -json '[]' "$PLIST_DEST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$APP_BINARY" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CHATBIRD_PANEL_HEALTH_FILE -string "$HEALTH_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CHATBIRD_CODEX_STATE_FILE -string "$STATE_PATH" "$PLIST_DEST"
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
    || fail "无法注册 ChatBird 登录启动项。"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
  || fail "ChatBird 启动请求失败。"

if ! wait_for_panel_health; then
  echo "首次启动未通过自检，正在自动重试…"
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/sleep 0.5
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "ChatBird 重试注册失败。"
  /bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
    || fail "ChatBird 重试启动失败。"
  wait_for_panel_health \
    || fail "ChatBird 进程没有保持运行。请把上面的日志发给维护者。"
fi

echo ""
echo "安装完成："
echo "  ✓ ChatBird 独立 App"
echo "  ✓ 自有桌面宠物和灵动岛"
echo "  ✓ 已移除旧 Codex ChatBird 宠物选择（如果存在）"
echo "  ✓ 已启用 Codex 原生任务气泡静音同步"
case "$CLAUDE_HOOK_STATUS" in
  enabled) echo "  ✓ 已启用 Claude Code 权限确认 Hook" ;;
  conflict) echo "  … 已保留现有 PermissionRequest Hook，未启用 ChatBird Hook" ;;
  warning) echo "  … Claude Code 权限确认 Hook 未启用，请检查上方警告" ;;
  *) echo "  … 未检测到 Claude CLI，已跳过 Claude Code 权限确认 Hook" ;;
esac
if "$APP_BINARY" --check-accessibility >/dev/null 2>&1; then
  echo "  ✓ 当前运行中新任务气泡自动静音已启用"
else
  echo "  … 新任务气泡自动静音可在系统辅助功能设置中启用"
fi
echo "  ✓ 随登录自动启动"
echo ""
echo "ChatBird 现在以独立 App 运行：可从 Dock、启动台或 ~/Applications/ChatBird.app 启动。"
echo "旧 ~/.codex/pets/chatbird-nt 不会被安装器删除；如你确认不再需要，可之后手动清理。"
echo "辅助功能已授权时，ChatBird 会调用 Codex 自带的“静音任务”菜单；不会移动鼠标或发送按键，只匹配固定辅助功能标签且不保留相关字符串。"
echo "未授权不影响额度与任务面板，也不需要 API Key。"
pause_before_exit
