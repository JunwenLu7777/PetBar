#!/bin/zsh
emulate -L zsh
setopt PIPE_FAIL

PET_DIR="${CODEX_HOME:-$HOME/.codex}/pets/chatbird-nt"
APP="$HOME/Applications/ChatBird 额度面板.app"
BIN="$APP/Contents/MacOS/ChatBirdQuotaPanel"
LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
HEALTH="$HOME/Library/Caches/$LABEL/panel-health.json"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
FAILED=0

check() {
  if eval "$2"; then
    echo "✓ $1"
  else
    echo "✗ $1"
    FAILED=1
  fi
}

json_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

image_dimension() {
  /usr/bin/sips -g "$2" "$1" 2>/dev/null | /usr/bin/awk -v key="$2:" '$1 == key { print $2 }'
}

echo "ChatBird 安装检查"
echo "───────────────"
check "宠物文件完整" '[[ -f "$PET_DIR/pet.json" && -f "$PET_DIR/spritesheet.webp" ]]'
check "pet.json id 正确" '[[ -f "$PET_DIR/pet.json" && "$(json_value "$PET_DIR/pet.json" id)" == "chatbird-nt" ]]'
check "pet.json spriteVersionNumber 为 2" '[[ -f "$PET_DIR/pet.json" && "$(json_value "$PET_DIR/pet.json" spriteVersionNumber)" == "2" ]]'
check "宠物图集为 1536x2288" '[[ -f "$PET_DIR/spritesheet.webp" && "$(image_dimension "$PET_DIR/spritesheet.webp" pixelWidth)" == "1536" && "$(image_dimension "$PET_DIR/spritesheet.webp" pixelHeight)" == "2288" ]]'
check "额度面板已安装" '[[ -x "$BIN" ]]'
check "额度面板为 Universal 2" '[[ -x "$BIN" ]] && /usr/bin/lipo "$BIN" -verify_arch arm64 && /usr/bin/lipo "$BIN" -verify_arch x86_64'
check "额度面板支持当前 Mac" '[[ -x "$BIN" ]] && /usr/bin/lipo "$BIN" -verify_arch "$(/usr/bin/uname -m)"'
check "额度面板签名正常" '[[ -d "$APP" ]] && /usr/bin/codesign --verify --deep --strict "$APP"'
if [[ -x "$BIN" ]] && "$BIN" --check-accessibility >/dev/null 2>&1; then
  echo "✓ 当前运行中新任务气泡自动静音已授权"
else
  echo "… 当前运行中新任务气泡自动静音未授权（不影响其他功能）"
fi
check "登录启动项存在" '[[ -f "$PLIST" ]]'
check "登录启动项标签正确" '[[ -f "$PLIST" && "$(/usr/bin/plutil -extract Label raw "$PLIST" 2>/dev/null)" == "$LABEL" ]]'
check "额度面板进程正在运行" '/bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | /usr/bin/grep -Eq "^[[:space:]]*pid = [0-9]+"'
check "健康文件 edition 正确" '[[ -s "$HEALTH" ]] && /usr/bin/grep -q '"'"'"edition":"chatbird-nt"'"'"' "$HEALTH"'
check "健康文件 petID 正确" '[[ -s "$HEALTH" ]] && /usr/bin/grep -q '"'"'"petID":"chatbird-nt"'"'"' "$HEALTH"'
check "健康文件 Codex 周额度配置正确" '[[ -s "$HEALTH" ]] && /usr/bin/grep -q '"'"'"codexWeeklyQuotaOnly":true'"'"' "$HEALTH"'
check "健康文件 Claude 三项额度配置正确" '[[ -s "$HEALTH" ]] && /usr/bin/grep -q '"'"'"claudeQuotaPeriods":\["5h","weekly","fable"\]'"'"' "$HEALTH"'
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
  echo "面板状态："
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
  echo "有项目未通过：请先确认 Codex 已安装并已登录，再重新运行“安装ChatBird.command”。"
  echo "日志：$HOME/Library/Logs/ChatBird额度面板.log"
fi

if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
exit "$FAILED"
