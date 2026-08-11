#!/bin/zsh
emulate -L zsh
setopt PIPE_FAIL

APP="$HOME/Applications/ChatBird.app"
BIN="$APP/Contents/MacOS/ChatBird"
LABEL="dev.chatbird.app"
LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
DOMAIN="gui/$(id -u)"
HEALTH="$HOME/Library/Caches/$LABEL/panel-health.json"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
FAILED=0

check() {
  local label="$1"
  local predicate="$2"
  if run_check "$predicate"; then
    echo "✓ $label"
  else
    echo "✗ $label"
    FAILED=1
  fi
}

warn_if() {
  local label="$1"
  local predicate="$2"
  if run_check "$predicate"; then
    echo "… $label"
  fi
}

run_check() {
  case "$1" in
    app-installed)
      [[ -d "$APP" && -x "$BIN" ]]
      ;;
    app-arm64)
      [[ -x "$BIN" ]] \
        && /usr/bin/lipo "$BIN" -verify_arch arm64 \
        && [[ "$(/usr/bin/lipo -archs "$BIN")" == "arm64" ]]
      ;;
    app-current-arch)
      [[ -x "$BIN" ]] && /usr/bin/lipo "$BIN" -verify_arch "$(/usr/bin/uname -m)"
      ;;
    app-signature)
      [[ -d "$APP" ]] && /usr/bin/codesign --verify --deep --strict "$APP"
      ;;
    bundle-id)
      [[ -f "$APP/Contents/Info.plist" \
        && "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null)" == "$LABEL" ]]
      ;;
    executable-name)
      [[ -f "$APP/Contents/Info.plist" \
        && "$(/usr/bin/plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist" 2>/dev/null)" == "ChatBird" ]]
      ;;
    dock-app)
      [[ -f "$APP/Contents/Info.plist" \
        && "$(/usr/bin/plutil -extract LSUIElement raw "$APP/Contents/Info.plist" 2>/dev/null)" != "1" ]]
      ;;
    app-icon)
      [[ -f "$APP/Contents/Info.plist" \
        && -n "$(/usr/bin/plutil -extract CFBundleIconFile raw "$APP/Contents/Info.plist" 2>/dev/null)" \
        && -f "$APP/Contents/Resources/ChatBird.icns" ]]
      ;;
    launch-agent-exists)
      [[ -f "$PLIST" ]]
      ;;
    launch-agent-label)
      [[ -f "$PLIST" && "$(/usr/bin/plutil -extract Label raw "$PLIST" 2>/dev/null)" == "$LABEL" ]]
      ;;
    launch-agent-program)
      [[ -f "$PLIST" \
        && "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null)" == "$BIN" ]] \
        && ! /usr/bin/plutil -extract ProgramArguments.1 raw "$PLIST" >/dev/null 2>&1
      ;;
    app-running)
      /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | /usr/bin/grep -Eq "^[[:space:]]*pid = [0-9]+"
      ;;
    health-edition)
      [[ -s "$HEALTH" ]] && /usr/bin/grep -q '"edition":"chatbird-nt"' "$HEALTH"
      ;;
    health-codex-weekly)
      [[ -s "$HEALTH" ]] && /usr/bin/grep -q '"codexWeeklyQuotaOnly":true' "$HEALTH"
      ;;
    health-claude-periods)
      [[ -s "$HEALTH" ]] && /usr/bin/grep -q '"claudeQuotaPeriods":\["5h","weekly","fable"\]' "$HEALTH"
      ;;
    legacy-launch-agent)
      [[ -f "$LEGACY_PLIST" ]] || /bin/launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1
      ;;
    legacy-process)
      /usr/bin/pgrep -x ChatBirdQuotaPanel >/dev/null 2>&1
      ;;
    legacy-codex-pet-selected)
      [[ -f "$CONFIG" ]] && /usr/bin/awk '
        BEGIN { section = ""; found = 0 }
        /^[[:space:]]*\[[^]]+\]/ {
          section = ($0 ~ /^[[:space:]]*\[desktop\][[:space:]]*($|#)/) ? "desktop" : "other"
        }
        section == "desktop" && /^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"/ {
          found = 1
        }
        END { exit(found ? 0 : 1) }
      ' "$CONFIG"
      ;;
    *)
      return 2
      ;;
  esac
}

echo "ChatBird 安装检查"
echo "───────────────"
check "ChatBird 独立 App 已安装" app-installed
check "ChatBird 为 arm64" app-arm64
check "ChatBird 支持当前 Mac" app-current-arch
check "ChatBird 签名正常" app-signature
check "Bundle ID 为 dev.chatbird.app" bundle-id
check "可执行程序为 ChatBird" executable-name
check "不是 LSUIElement 后台应用" dock-app
check "已配置独立 App Icon" app-icon
if [[ -x "$BIN" ]] && "$BIN" --check-accessibility >/dev/null 2>&1; then
  echo "✓ 当前运行中新任务气泡自动静音已授权"
else
  echo "… 当前运行中新任务气泡自动静音未授权（不影响其他功能）"
fi
check "登录启动项存在" launch-agent-exists
check "登录启动项标签正确" launch-agent-label
check "登录启动项只启动 ~/Applications/ChatBird.app" launch-agent-program
check "ChatBird 进程正在运行" app-running
check "健康文件 edition 正确" health-edition
check "健康文件 Codex 周额度配置正确" health-codex-weekly
check "健康文件 Claude 三项额度配置正确" health-claude-periods
warn_if "检测到旧 LaunchAgent 残留，可重新运行安装或卸载清理" legacy-launch-agent
warn_if "检测到旧 ChatBirdQuotaPanel 进程残留，可重新运行安装或卸载清理" legacy-process
if run_check legacy-codex-pet-selected; then
  echo "✗ Codex 仍选中了旧 custom:chatbird-nt 宠物"
  FAILED=1
else
  echo "✓ Codex 未选中旧 custom:chatbird-nt 宠物"
fi
if [[ -s "$NATIVE_NOTIFICATION_BACKUP" ]]; then
  echo "✓ Codex 原生气泡恢复点存在"
elif /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
  || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1
then
  echo "… Codex 原生气泡静音等待 Codex 完全退出后同步"
else
  echo "✗ Codex 原生气泡恢复点不存在"
  FAILED=1
fi
if [[ -s "$HEALTH" ]]; then
  echo ""
  echo "ChatBird 状态："
  /bin/cat "$HEALTH"
  echo ""
fi

if [[ -x "$BIN" ]]; then
  echo ""
  echo "Codex 额度读取："
  "$BIN" --print-quota || FAILED=1

  if [[ -x "${CLAUDE_BIN:-}" || -x "$HOME/.local/bin/claude" || -x "/opt/homebrew/bin/claude" || -x "/usr/local/bin/claude" ]]; then
    echo ""
    echo "Claude Code 额度读取："
    "$BIN" --print-claude-quota || FAILED=1
  else
    echo ""
    echo "Claude Code 未安装，跳过可选的 Claude 额度检查。"
  fi

  echo ""
  echo "Codex + Claude 任务读取："
  "$BIN" --print-task-progress || FAILED=1
fi

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "全部检查通过。"
else
  echo "有项目未通过：请重新运行“安装ChatBird.command”；如果仍失败，把日志发给维护者。"
  echo "日志：$HOME/Library/Logs/ChatBird.log"
fi

if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
exit "$FAILED"
