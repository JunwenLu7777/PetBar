#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/threadhelm-local-transaction.XXXXXX")"
trap '/bin/rm -rf "$FIXTURE"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

HELPER="$ROOT/macos/ThreadHelm/scripts/local-install-transaction.zsh"
[[ -f "$HELPER" ]] || fail "missing shared local transaction helper"

export HOME="$FIXTURE/home"
mkdir -p \
  "$HOME/Applications/ThreadHelm.app/Contents/MacOS" \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Caches/dev.threadhelm.app" \
  "$HOME/.codex"

THREADHELM_APP_DEST="$HOME/Applications/ThreadHelm.app"
THREADHELM_PLIST_DEST="$HOME/Library/LaunchAgents/dev.threadhelm.app.plist"
THREADHELM_HEALTH_DIR="$HOME/Library/Caches/dev.threadhelm.app"
THREADHELM_STATE_PATH="$HOME/.codex/.codex-global-state.json"
THREADHELM_NATIVE_BACKUP_PATH="$HOME/.codex/threadhelm-native-notification-backup.json"
THREADHELM_LEGACY_NATIVE_BACKUP_PATH="$HOME/.codex/chatbird-native-notification-backup.json"
THREADHELM_DOMAIN="gui/501"
THREADHELM_LABEL="dev.threadhelm.app"
THREADHELM_LAUNCHCTL="$FIXTURE/fake-launchctl"
THREADHELM_RECOVERY_BINARY="$FIXTURE/fake-threadhelm"
THREADHELM_TEST_LOG="$FIXTURE/calls.log"
export THREADHELM_TEST_LOG

print -r -- $'#!/bin/zsh\nprint -r -- "$@" >> "$THREADHELM_TEST_LOG"\nexit 0' \
  > "$THREADHELM_LAUNCHCTL"
print -r -- $'#!/bin/zsh\nprint -r -- "$@" >> "$THREADHELM_TEST_LOG"\nexit 0' \
  > "$THREADHELM_RECOVERY_BINARY"
/bin/chmod +x "$THREADHELM_LAUNCHCTL" "$THREADHELM_RECOVERY_BINARY"

print -r -- "old-app" > "$THREADHELM_APP_DEST/Contents/MacOS/ThreadHelm"
print -r -- "old-plist" > "$THREADHELM_PLIST_DEST"
print -r -- "old-health" > "$THREADHELM_HEALTH_DIR/panel-health.json"
print -r -- "old-state" > "$THREADHELM_STATE_PATH"
print -r -- "old-native-backup" > "$THREADHELM_NATIVE_BACKUP_PATH"
print -r -- "old-legacy-backup" > "$THREADHELM_LEGACY_NATIVE_BACKUP_PATH"

source "$HELPER"
threadhelm_begin_install_transaction
threadhelm_set_integration_backup_id \
  '{"backupID":"01234567-89ab-cdef-0123-456789abcdef"}'

print -r -- "new-app" > "$THREADHELM_APP_DEST/Contents/MacOS/ThreadHelm"
print -r -- "new-plist" > "$THREADHELM_PLIST_DEST"
print -r -- "new-health" > "$THREADHELM_HEALTH_DIR/panel-health.json"
print -r -- "new-state" > "$THREADHELM_STATE_PATH"
/bin/rm -f "$THREADHELM_NATIVE_BACKUP_PATH" \
  "$THREADHELM_LEGACY_NATIVE_BACKUP_PATH"

threadhelm_rollback_install_transaction

[[ "$(<"$THREADHELM_APP_DEST/Contents/MacOS/ThreadHelm")" == "old-app" ]] \
  || fail "old app was not restored"
[[ "$(<"$THREADHELM_PLIST_DEST")" == "old-plist" ]] \
  || fail "old LaunchAgent was not restored"
[[ "$(<"$THREADHELM_HEALTH_DIR/panel-health.json")" == "old-health" ]] \
  || fail "old health state was not restored"
[[ "$(<"$THREADHELM_STATE_PATH")" == "old-state" ]] \
  || fail "old Codex state was not restored"
[[ "$(<"$THREADHELM_NATIVE_BACKUP_PATH")" == "old-native-backup" ]] \
  || fail "native notification backup was not restored"
[[ "$(<"$THREADHELM_LEGACY_NATIVE_BACKUP_PATH")" == "old-legacy-backup" ]] \
  || fail "legacy notification backup was not restored"
/usr/bin/grep -Fq -e \
  '--agent-integrations restore 01234567-89ab-cdef-0123-456789abcdef --live' \
  "$THREADHELM_TEST_LOG" \
  || fail "managed integration restore was not invoked"
/usr/bin/grep -Fq -e \
  "bootstrap $THREADHELM_DOMAIN $THREADHELM_PLIST_DEST" \
  "$THREADHELM_TEST_LOG" \
  || fail "old LaunchAgent was not restarted"

threadhelm_begin_install_transaction
print -r -- "committed-app" > \
  "$THREADHELM_APP_DEST/Contents/MacOS/ThreadHelm"
threadhelm_commit_install_transaction
threadhelm_rollback_install_transaction
[[ "$(<"$THREADHELM_APP_DEST/Contents/MacOS/ThreadHelm")" == "committed-app" ]] \
  || fail "committed install was rolled back"

print -r -- $'#!/bin/zsh\nexit 1' > "$THREADHELM_RECOVERY_BINARY"
/bin/chmod +x "$THREADHELM_RECOVERY_BINARY"
threadhelm_begin_install_transaction
threadhelm_set_integration_backup_id \
  '{"backupID":"fedcba98-7654-3210-fedc-ba9876543210"}'
FAILED_TRANSACTION_DIR="$THREADHELM_TRANSACTION_DIR"
if threadhelm_rollback_install_transaction; then
  fail "failed integration recovery reported a complete rollback"
fi
[[ -d "$FAILED_TRANSACTION_DIR" \
    && -f "$FAILED_TRANSACTION_DIR/app.state" \
    && -d "$FAILED_TRANSACTION_DIR/payload" ]] \
  || fail "failed rollback did not preserve its local transaction snapshot"
/bin/rm -rf "$FAILED_TRANSACTION_DIR"

/bin/echo "ThreadHelm local transaction tests passed"
