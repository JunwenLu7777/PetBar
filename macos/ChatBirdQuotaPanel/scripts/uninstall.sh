#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DOMAIN="gui/$(id -u)"
LABEL="dev.chatbird.app"
LEGACY_LABEL="dev.chatbird.codex-quota-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
BUILD_APP="$ROOT/build/ChatBird.app"
INSTALLED_APP="$HOME/Applications/ChatBird.app"
LEGACY_APP_SHORTCUT="$HOME/Applications/ChatBird 额度面板.app"
BUILD_BIN="$BUILD_APP/Contents/MacOS/ChatBird"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/ChatBird"
LEGACY_BIN="$LEGACY_APP_SHORTCUT/Contents/MacOS/ChatBirdQuotaPanel"
HEALTH_DIR="$HOME/Library/Caches/$LABEL"
LEGACY_HEALTH_DIR="$HOME/Library/Caches/$LEGACY_LABEL"
LOG="$HOME/Library/Logs/ChatBird.log"
LEGACY_LOG="$HOME/Library/Logs/ChatBird额度面板.log"
STATE="${CODEX_HOME:-$HOME/.codex}/.codex-global-state.json"
NATIVE_NOTIFICATION_BACKUP="${CODEX_HOME:-$HOME/.codex}/chatbird-native-notification-backup.json"
CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"

detach_legacy_codex_pet_selection() {
  [[ -f "$CONFIG" ]] || return 0
  /usr/bin/grep -Eq \
    '^[[:space:]]*selected-avatar-id[[:space:]]*=[[:space:]]*"custom:chatbird-nt"' \
    "$CONFIG" || return 0

  /bin/cp -p "$CONFIG" "$CONFIG.chatbird-independent-backup-$(date +%Y%m%d-%H%M%S)"
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

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/bin/launchctl bootout "$DOMAIN/$LEGACY_LABEL" 2>/dev/null || true
/usr/bin/pkill -x ChatBird 2>/dev/null || true
/usr/bin/pkill -x ChatBirdQuotaPanel 2>/dev/null || true

CLEANUP_BIN=""
for candidate in "$INSTALLED_BIN" "$BUILD_BIN" "$LEGACY_BIN"; do
  if [[ -x "$candidate" ]]; then
    CLEANUP_BIN="$candidate"
    break
  fi
done
if [[ -n "$CLEANUP_BIN" ]]; then
  "$CLEANUP_BIN" --uninstall-claude-hook
  "$CLEANUP_BIN" \
    --restore-codex-overlay-notifications \
    "$STATE" \
    "$NATIVE_NOTIFICATION_BACKUP"
fi

detach_legacy_codex_pet_selection

/bin/rm -f "$PLIST" "$LEGACY_PLIST" "$LOG" "$LEGACY_LOG"
/bin/rm -rf \
  "$INSTALLED_APP" \
  "$LEGACY_APP_SHORTCUT" \
  "$HEALTH_DIR" \
  "$LEGACY_HEALTH_DIR"
echo "ChatBird 已卸载"
