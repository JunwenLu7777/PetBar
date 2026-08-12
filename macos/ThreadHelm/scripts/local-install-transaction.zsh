#!/bin/zsh

# Shared owner-only install transaction support. The caller sets the
# THREADHELM_* paths below before invoking begin/commit/rollback.

typeset -g THREADHELM_TRANSACTION_ACTIVE=false
typeset -g THREADHELM_TRANSACTION_DIR=""
typeset -g THREADHELM_INTEGRATION_BACKUP_ID=""

threadhelm_assert_safe_transaction_path() {
  local value="$1"
  local label="$2"
  [[ -n "$value" && "$value" == /* && "$value" != "/" \
    && "$value" != "$HOME" ]] \
    || {
      /bin/echo "不安全的 $label 路径：$value" >&2
      return 1
    }
}

threadhelm_require_transaction_configuration() {
  local name
  for name in \
    THREADHELM_APP_DEST \
    THREADHELM_PLIST_DEST \
    THREADHELM_HEALTH_DIR \
    THREADHELM_STATE_PATH \
    THREADHELM_NATIVE_BACKUP_PATH \
    THREADHELM_LEGACY_NATIVE_BACKUP_PATH \
    THREADHELM_DOMAIN \
    THREADHELM_LABEL
  do
    [[ -n "${(P)name:-}" ]] || {
      /bin/echo "缺少安装事务参数：$name" >&2
      return 1
    }
  done

  [[ "$THREADHELM_APP_DEST" == "$HOME/Applications/ThreadHelm.app" ]] \
    || {
      /bin/echo "ThreadHelm App 目标路径不符合本机安装边界" >&2
      return 1
    }
  [[ "$THREADHELM_PLIST_DEST" \
      == "$HOME/Library/LaunchAgents/dev.threadhelm.app.plist" ]] \
    || {
      /bin/echo "ThreadHelm LaunchAgent 目标路径不符合本机安装边界" >&2
      return 1
    }
  [[ "$THREADHELM_HEALTH_DIR" \
      == "$HOME/Library/Caches/dev.threadhelm.app" ]] \
    || {
      /bin/echo "ThreadHelm 健康目录不符合本机安装边界" >&2
      return 1
    }

  threadhelm_assert_safe_transaction_path \
    "$THREADHELM_STATE_PATH" "Codex 状态文件"
  threadhelm_assert_safe_transaction_path \
    "$THREADHELM_NATIVE_BACKUP_PATH" "Codex 恢复点"
  threadhelm_assert_safe_transaction_path \
    "$THREADHELM_LEGACY_NATIVE_BACKUP_PATH" "旧 Codex 恢复点"
  [[ "${THREADHELM_STATE_PATH:t}" == ".codex-global-state.json" \
    && "${THREADHELM_NATIVE_BACKUP_PATH:t}" \
      == "threadhelm-native-notification-backup.json" \
    && "${THREADHELM_LEGACY_NATIVE_BACKUP_PATH:t}" \
      == "chatbird-native-notification-backup.json" ]] \
    || {
      /bin/echo "Codex 状态或恢复点文件名无效" >&2
      return 1
    }
}

threadhelm_snapshot_transaction_path() {
  local source_path="$1"
  local key="$2"
  local marker="$THREADHELM_TRANSACTION_DIR/$key.state"
  local payload="$THREADHELM_TRANSACTION_DIR/payload/$key"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    print -r -- "present" > "$marker"
    /usr/bin/ditto "$source_path" "$payload"
  else
    print -r -- "missing" > "$marker"
  fi
}

threadhelm_restore_transaction_path() {
  local target_path="$1"
  local key="$2"
  local marker="$THREADHELM_TRANSACTION_DIR/$key.state"
  local payload="$THREADHELM_TRANSACTION_DIR/payload/$key"
  [[ -f "$marker" ]] || return 1
  /bin/rm -rf "$target_path"
  if [[ "$(<"$marker")" == "present" ]]; then
    /bin/mkdir -p "${target_path:h}"
    /usr/bin/ditto "$payload" "$target_path"
  fi
}

threadhelm_begin_install_transaction() {
  [[ "$THREADHELM_TRANSACTION_ACTIVE" != "true" ]] || return 1
  threadhelm_require_transaction_configuration
  local transaction_root="$HOME/Library/Application Support/ThreadHelm/Install Transactions"
  /bin/mkdir -p "$transaction_root"
  /bin/chmod 700 "$transaction_root"
  THREADHELM_TRANSACTION_DIR="$(
    /usr/bin/mktemp -d "$transaction_root/install.XXXXXX"
  )"
  /bin/chmod 700 "$THREADHELM_TRANSACTION_DIR"
  /bin/mkdir -p "$THREADHELM_TRANSACTION_DIR/payload"

  threadhelm_snapshot_transaction_path "$THREADHELM_APP_DEST" app
  threadhelm_snapshot_transaction_path "$THREADHELM_PLIST_DEST" launch_agent
  threadhelm_snapshot_transaction_path "$THREADHELM_HEALTH_DIR" health
  threadhelm_snapshot_transaction_path "$THREADHELM_STATE_PATH" codex_state
  threadhelm_snapshot_transaction_path \
    "$THREADHELM_NATIVE_BACKUP_PATH" native_backup
  threadhelm_snapshot_transaction_path \
    "$THREADHELM_LEGACY_NATIVE_BACKUP_PATH" legacy_native_backup
  THREADHELM_INTEGRATION_BACKUP_ID=""
  THREADHELM_TRANSACTION_ACTIVE=true
}

threadhelm_set_integration_backup_id() {
  [[ "$THREADHELM_TRANSACTION_ACTIVE" == "true" ]] || return 1
  local report="$1"
  local report_path="$THREADHELM_TRANSACTION_DIR/integration-report.json"
  print -rn -- "$report" > "$report_path"
  local backup_id
  backup_id="$(
    /usr/bin/plutil -extract backupID raw -o - "$report_path" 2>/dev/null
  )" || return 1
  [[ "$backup_id" =~ \
    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
  ]] || return 1
  THREADHELM_INTEGRATION_BACKUP_ID="$backup_id"
}

threadhelm_rollback_install_transaction() {
  [[ "$THREADHELM_TRANSACTION_ACTIVE" == "true" ]] || return 0
  THREADHELM_TRANSACTION_ACTIVE=false
  local rollback_failed=0
  local launchctl_path="${THREADHELM_LAUNCHCTL:-/bin/launchctl}"

  "$launchctl_path" bootout \
    "$THREADHELM_DOMAIN/$THREADHELM_LABEL" 2>/dev/null || true

  if [[ -n "$THREADHELM_INTEGRATION_BACKUP_ID" ]]; then
    if [[ ! -x "${THREADHELM_RECOVERY_BINARY:-}" ]] \
      || ! "$THREADHELM_RECOVERY_BINARY" \
        --agent-integrations restore \
        "$THREADHELM_INTEGRATION_BACKUP_ID" --live
    then
      /bin/echo "警告：Agent 集成自动恢复失败，备份编号：$THREADHELM_INTEGRATION_BACKUP_ID" >&2
      rollback_failed=1
    fi
  fi

  threadhelm_restore_transaction_path "$THREADHELM_APP_DEST" app \
    || rollback_failed=1
  threadhelm_restore_transaction_path \
    "$THREADHELM_PLIST_DEST" launch_agent || rollback_failed=1
  threadhelm_restore_transaction_path "$THREADHELM_HEALTH_DIR" health \
    || rollback_failed=1
  threadhelm_restore_transaction_path "$THREADHELM_STATE_PATH" codex_state \
    || rollback_failed=1
  threadhelm_restore_transaction_path \
    "$THREADHELM_NATIVE_BACKUP_PATH" native_backup || rollback_failed=1
  threadhelm_restore_transaction_path \
    "$THREADHELM_LEGACY_NATIVE_BACKUP_PATH" legacy_native_backup \
    || rollback_failed=1

  if [[ -f "$THREADHELM_PLIST_DEST" ]]; then
    "$launchctl_path" bootstrap \
      "$THREADHELM_DOMAIN" "$THREADHELM_PLIST_DEST" \
      || rollback_failed=1
    "$launchctl_path" kickstart -k \
      "$THREADHELM_DOMAIN/$THREADHELM_LABEL" \
      || rollback_failed=1
  fi

  if (( rollback_failed != 0 )); then
    /bin/echo \
      "ThreadHelm 自动回滚未完整完成；本机事务快照保留在：$THREADHELM_TRANSACTION_DIR" \
      >&2
    /bin/echo "请按本机运维说明手工恢复。" >&2
    return 1
  fi
  /bin/rm -rf "$THREADHELM_TRANSACTION_DIR"
  THREADHELM_TRANSACTION_DIR=""
  THREADHELM_INTEGRATION_BACKUP_ID=""
  /bin/echo "ThreadHelm 安装未完成，旧 App、启动项和受管配置已恢复。" >&2
}

threadhelm_commit_install_transaction() {
  [[ "$THREADHELM_TRANSACTION_ACTIVE" == "true" ]] || return 1
  THREADHELM_TRANSACTION_ACTIVE=false
  /bin/rm -rf "$THREADHELM_TRANSACTION_DIR"
  THREADHELM_TRANSACTION_DIR=""
  THREADHELM_INTEGRATION_BACKUP_ID=""
}
