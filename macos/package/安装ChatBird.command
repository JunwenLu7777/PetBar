#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

ROOT="${0:A:h}"
PET_ID="chatbird-nt"
PET_SOURCE="$ROOT/pet/$PET_ID"
PET_DEST="${CODEX_HOME:-$HOME/.codex}/pets/$PET_ID"
APP_SOURCE="$ROOT/quota-panel/ChatBird 额度面板.app"
APP_DEST="$HOME/Applications/ChatBird 额度面板.app"
APP_BINARY="$APP_DEST/Contents/MacOS/ChatBirdQuotaPanel"
SOURCE_BINARY="$APP_SOURCE/Contents/MacOS/ChatBirdQuotaPanel"
LABEL="dev.chatbird.codex-quota-panel"
PLIST_SOURCE="$ROOT/quota-panel/$LABEL.plist.in"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/ChatBird额度面板.log"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
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
    echo "面板日志最后 12 行："
    /usr/bin/tail -n 12 "$LOG_PATH" 2>/dev/null || true
  fi
  pause_before_exit
  exit 1
}

json_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null || true
}

image_dimension() {
  /usr/bin/sips -g "$2" "$1" 2>/dev/null | /usr/bin/awk -v key="$2:" '$1 == key { print $2 }' || true
}

panel_service_has_pid() {
  /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
    | /usr/bin/grep -Eq '^[[:space:]]*pid = [0-9]+'
}

panel_health_is_current() {
  [[ -s "$HEALTH_PATH" ]] \
    && /usr/bin/grep -q '"edition":"chatbird-nt"' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"petID":"chatbird-nt"' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"codexWeeklyQuotaOnly":true' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"claudeQuotaPeriods":\["5h","weekly","fable"\]' "$HEALTH_PATH" 2>/dev/null
}

wait_for_panel_health() {
  local attempt
  for attempt in {1..80}; do
    if panel_service_has_pid && panel_health_is_current; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

assert_package_is_complete() {
  [[ -f "$PET_SOURCE/pet.json" && -f "$PET_SOURCE/spritesheet.webp" ]] \
    || fail "宠物文件不完整（$PET_ID），请重新解压整个分享包。"
  [[ "$(json_value "$PET_SOURCE/pet.json" id)" == "$PET_ID" ]] \
    || fail "pet.json 的 id 必须是 $PET_ID。"
  [[ "$(json_value "$PET_SOURCE/pet.json" spriteVersionNumber)" == "2" ]] \
    || fail "pet.json 的 spriteVersionNumber 必须是 2。"
  [[ "$(image_dimension "$PET_SOURCE/spritesheet.webp" pixelWidth)" == "1536" ]] \
    || fail "宠物图集宽度必须是 1536。"
  [[ "$(image_dimension "$PET_SOURCE/spritesheet.webp" pixelHeight)" == "2288" ]] \
    || fail "宠物图集高度必须是 2288。"
  [[ -d "$APP_SOURCE" && -x "$SOURCE_BINARY" && -f "$PLIST_SOURCE" ]] \
    || fail "额度面板文件不完整，请重新解压整个分享包。"
  /usr/bin/lipo "$SOURCE_BINARY" -verify_arch arm64 \
    || fail "额度面板不包含 arm64 架构。"
  /usr/bin/lipo "$SOURCE_BINARY" -verify_arch x86_64 \
    || fail "额度面板不包含 x86_64 架构。"
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE" >/dev/null 2>&1 \
    || fail "额度面板签名校验失败，请重新解压整个分享包。"
  /usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null \
    || fail "登录启动项模板无效。"
}

select_chatbird_in_codex() {
  mkdir -p "${CONFIG:h}"
  [[ -f "$CONFIG" ]] || /usr/bin/touch "$CONFIG"
  /bin/cp -p "$CONFIG" "$CONFIG.chatbird-backup-$(date +%Y%m%d-%H%M%S)"

  local tmp_config
  tmp_config="$(/usr/bin/mktemp "$CONFIG.tmp.XXXXXX")"
  /usr/bin/awk '
    BEGIN {
      section = ""
      desktop_seen = 0
      desktop_has_value = 0
      value = "selected-avatar-id = \"custom:chatbird-nt\""
    }
    function add_desktop_value() {
      if (!desktop_has_value) {
        print value
        desktop_has_value = 1
      }
    }
    /^[[:space:]]*\[[^]]+\]/ {
      if (section == "desktop") add_desktop_value()
      if ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) {
        section = "desktop"
        desktop_seen = 1
        desktop_has_value = 0
      } else {
        section = "other"
      }
      print
      next
    }
    {
      if (section == "" && $0 ~ /^[[:space:]]*selected-avatar-id[[:space:]]*=/) next
      if (section == "desktop" && $0 ~ /^[[:space:]]*selected-avatar-id[[:space:]]*=/) {
        if (!desktop_has_value) print value
        desktop_has_value = 1
        next
      }
      print
    }
    END {
      if (section == "desktop") add_desktop_value()
      if (!desktop_seen) {
        print ""
        print "[desktop]"
        print value
      }
    }
  ' "$CONFIG" > "$tmp_config"
  /bin/mv "$tmp_config" "$CONFIG"
}

echo "正在校验 ChatBird 安装包…"
assert_package_is_complete
if [[ "$VERIFY_ONLY" == "true" ]]; then
  echo "校验通过：ChatBird 安装包完整。"
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
[[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] \
  || fail "不支持当前 Mac 架构：$ARCH。"
/usr/bin/lipo "$SOURCE_BINARY" -verify_arch "$ARCH" \
  || fail "额度面板不包含 $ARCH 架构。"

mkdir -p "${PET_DEST:h}" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HEALTH_DIR"

if [[ -e "$PET_DEST" ]]; then
  PET_BACKUP="$PET_DEST.backup-$(date +%Y%m%d-%H%M%S)"
  /bin/mv "$PET_DEST" "$PET_BACKUP"
  echo "已有同名宠物已备份到：$PET_BACKUP"
fi
/usr/bin/ditto "$PET_SOURCE" "$PET_DEST"

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in {1..20}; do
  /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true
for _ in {1..20}; do
  /usr/bin/pgrep -x ChatBirdQuotaPanel >/dev/null 2>&1 || break
  /bin/sleep 0.1
done

/bin/rm -rf "$APP_DEST"
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/usr/bin/xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DEST" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_DEST" \
  || fail "额度面板自动签名失败，请重新下载分享包。"
CLAUDE_HOOK_STATUS="warning"
if ! "$APP_BINARY" --install-claude-hook; then
  echo "警告：Claude Code 权限确认 Hook 安装命令失败；Codex 核心安装将继续。" >&2
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
  echo "警告：无法读取 Claude Code 权限确认 Hook 状态；Codex 核心安装将继续。" >&2
fi
"$APP_BINARY" \
  --prepare-codex-overlay-notifications \
  "$STATE_PATH" \
  "$SESSION_INDEX_PATH" \
  "$NATIVE_NOTIFICATION_BACKUP" \
  || fail "无法准备 Codex 原生任务气泡的静音状态。"
/bin/rm -f "$HEALTH_PATH"

/bin/cp "$PLIST_SOURCE" "$PLIST_DEST"
/usr/bin/plutil -replace ProgramArguments.0 -string "$APP_BINARY" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CHATBIRD_PANEL_HEALTH_FILE -string "$HEALTH_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CHATBIRD_CODEX_STATE_FILE -string "$STATE_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -lint "$PLIST_DEST" >/dev/null

if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST"; then
  /bin/sleep 1
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "无法注册额度面板登录启动项。"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
  || fail "额度面板启动请求失败。"

if ! wait_for_panel_health; then
  echo "首次启动未通过自检，正在自动重试…"
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/sleep 0.5
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "额度面板重试注册失败。"
  /bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
    || fail "额度面板重试启动失败。"
  wait_for_panel_health \
    || fail "额度面板进程没有保持运行。请把上面的日志发给维护者。"
fi

select_chatbird_in_codex

echo ""
echo "安装完成："
echo "  ✓ ChatBird 宠物"
echo "  ✓ ChatBird 额度面板"
echo "  ✓ 已在 Codex 中选中 ChatBird"
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
echo "请完全退出并重新打开 Codex。ChatBird 会等 Codex 状态稳定后再同步，旧任务气泡不会在下次打开时恢复。"
echo "辅助功能已授权时，ChatBird 会调用 Codex 自带的“静音任务”菜单；不会移动鼠标或发送按键，只匹配固定辅助功能标签且不保留相关字符串。"
echo "未授权不影响额度与任务面板，也不需要 API Key。"
pause_before_exit
