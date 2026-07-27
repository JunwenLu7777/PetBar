#!/bin/zsh
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ChatBirdQuotaPanel"
BUNDLE_ID="dev.chatbird.codex-quota-panel"
ROOT="${0:A:h:h}"
PROJECT="$ROOT/macos/ChatBirdQuotaPanel"
APP_BUNDLE="$PROJECT/build/ChatBird 额度面板.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALL_SCRIPT="$PROJECT/scripts/install.sh"
LABEL="dev.chatbird.codex-quota-panel"
DOMAIN="gui/$(id -u)"

install_and_launch() {
  "$INSTALL_SCRIPT"
}

case "$MODE" in
  run)
    install_and_launch
    ;;
  --debug|debug)
    /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    "$PROJECT/scripts/build.sh"
    exec /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    install_and_launch
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    install_and_launch
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    install_and_launch >/dev/null
    for _ in {1..40}; do
      RUNNING_PID="$(/usr/bin/pgrep -x "$APP_NAME" | /usr/bin/head -1 || true)"
      if [[ -n "$RUNNING_PID" ]] \
        && [[ "$(/bin/ps -p "$RUNNING_PID" -o command=)" == "$APP_BINARY" ]]
      then
        echo "ChatBird 额度面板已启动"
        exit 0
      fi
      /bin/sleep 0.1
    done
    echo "ChatBird 额度面板未能启动" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
