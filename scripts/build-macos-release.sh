#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="${0:A}"
ROOT="${THREADHELM_RELEASE_ROOT:-${SCRIPT_PATH:h:h}}"
VERSION="$(/usr/bin/awk -F': ' '$1 == "Version" { print $2; exit }' "$ROOT/macos/VERSION.txt")"
[[ "$VERSION" == <->.<->.<-> ]] || {
  /bin/echo "error: invalid version in $ROOT/macos/VERSION.txt" >&2
  exit 1
}
RELEASE_ID="ThreadHelm-macOS-arm64-$VERSION"
STAGE="$ROOT/build/release/$RELEASE_ID"
OUT="$ROOT/dist/$RELEASE_ID.zip"
CHECKSUM_OUT="$OUT.sha256"
APP_PROJECT="$ROOT/macos/ThreadHelm"
APP_BUILD="$APP_PROJECT/build/ThreadHelm.app"
LABEL="dev.threadhelm.app"
PLIST_TEMPLATE="$APP_PROJECT/Resources/$LABEL.plist.in"
INSTALL_COMMAND="$ROOT/macos/package/安装ThreadHelm.command"
CHECK_COMMAND="$ROOT/macos/package/检查ThreadHelm.command"
UNINSTALL_COMMAND="$ROOT/macos/package/卸载ThreadHelm.command"
TRANSACTION_HELPER="$APP_PROJECT/scripts/local-install-transaction.zsh"
AGENT_TRUTH_ROOT="$APP_PROJECT/Tests/Fixtures/Agents"
VERIFY_ONLY=false
SKIP_APP_BINARY_CHECKS="${THREADHELM_SKIP_APP_BINARY_CHECKS:-false}"

usage() {
  /bin/echo "usage: $0 [--verify-only]"
}

for argument in "$@"; do
  case "$argument" in
    --verify-only) VERIFY_ONLY=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

fail() {
  /bin/echo "error: $1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

verify_inputs() {
  require_file "$APP_PROJECT/scripts/build.sh"
  require_file "$PLIST_TEMPLATE"
  require_file "$INSTALL_COMMAND"
  require_file "$CHECK_COMMAND"
  require_file "$UNINSTALL_COMMAND"
  require_file "$TRANSACTION_HELPER"
  require_file "$ROOT/macos/README.md"
  require_file "$ROOT/macos/VERSION.txt"
  require_file "$ROOT/LICENSE"
  require_file "$ROOT/PRIVACY.md"
  require_file "$ROOT/ASSET-NOTICE.md"
  require_file "$AGENT_TRUTH_ROOT/index.json"
  require_file "$AGENT_TRUTH_ROOT/versions.json"
  local agent_id
  for agent_id in codex claudeCode cursor zcode omp; do
    require_file "$AGENT_TRUTH_ROOT/scenarios/$agent_id.json"
  done
  /usr/bin/plutil -lint "$PLIST_TEMPLATE" >/dev/null
  /bin/zsh -n \
    "$INSTALL_COMMAND" "$CHECK_COMMAND" "$UNINSTALL_COMMAND" \
    "$TRANSACTION_HELPER"
}

verify_agent_truth_replay() {
  local binary="$1"
  local output agent_id
  [[ -x "$binary" ]] || fail "ThreadHelm binary is not executable: $binary"
  output="$("$binary" --verify-agent-truth "$AGENT_TRUTH_ROOT")" \
    || fail "five-agent truth replay failed: $binary"
  [[ "$output" == *"agent-truth-replay: agents=5 scenarios=81 persistent-state=unchanged"* ]] \
    || fail "five-agent truth replay summary is incomplete"
  for agent_id in codex claudeCode cursor zcode omp; do
    [[ "$output" == *"agent-truth-metric: agent=$agent_id "* ]] \
      || fail "missing truth metric for $agent_id"
  done
}

verify_app_self_tests() {
  local binary="$1"
  local check flag marker output
  local -a checks
  [[ -x "$binary" ]] || fail "ThreadHelm binary is not executable: $binary"
  checks=(
    '--self-test-lifecycle|lifecycle-self-test:'
    '--self-test-native-notification-state|native-notification-state-self-test:'
    '--self-test-task-progress|task-progress-self-test:'
    '--self-test-weekly-quota|weekly-quota-self-test:'
    '--self-test-claude-quota|claude-quota-self-test:'
    '--self-test-claude-hook|claude-hook-self-test:'
    '--self-test-client-contract|client-contract-self-test:'
    '--self-test-threadhelm-edition|threadhelm-edition-self-test:'
    '--self-test-dynamic-island|dynamic-island:'
  )
  for check in "${checks[@]}"; do
    flag="${check%%|*}"
    marker="${check#*|}"
    output="$("$binary" "$flag")" \
      || fail "ThreadHelm App self-test failed: $flag"
    [[ "$output" == *"$marker"* ]] \
      || fail "ThreadHelm App self-test summary is incomplete: $flag"
  done
}

path_has_forbidden_marker() {
  local candidate_path="${1:l}"
  local component token
  local -a components tokens markers
  markers=(chatbird mayday bubu orange windows codex-only)
  components=("${(@s:/:)candidate_path}")
  for component in "${components[@]}"; do
    tokens=("${(@s:-:)${component//[^[:alnum:]-]/-}}")
    for token in "${tokens[@]}"; do
      for marker in "${markers[@]}"; do
        if [[ "$component" == "$marker" \
              || "$token" == "$marker" \
              || ("$marker" == "chatbird" && "$component" == chatbird*) ]]; then
          return 0
        fi
      done
    done
  done
  return 1
}

scan_release_for_forbidden_terms() {
  local target="$1"
  local forbidden='Mayday|Bubu|bubu|卜卜|Binance|BTC|bitcoin|Codex-Only'
  local matching_path=""
  while IFS= read -r entry_path; do
    if path_has_forbidden_marker "$entry_path"; then
      matching_path="$entry_path"
      break
    fi
  done < <(cd "$target" && find . -print)
  [[ -z "$matching_path" ]] || fail "forbidden legacy path in release: $matching_path"

  local found=false
  while IFS= read -r file; do
    if /usr/bin/file "$file" | /usr/bin/grep -q 'text'; then
      if LC_ALL=C /usr/bin/grep -nE "$forbidden" "$file" >/dev/null; then
        /usr/bin/grep -nE "$forbidden" "$file" >&2 || true
        found=true
      fi
    fi
  done < <(find "$target" -type f -print)
  [[ "$found" == false ]] || fail "forbidden legacy text in release"
}

verify_stage() {
  local target="$1"
  [[ ! -e "$target/pet" ]] || fail "release must not publish a standalone pet directory"
  [[ ! -e "$target/preview-qa" ]] || fail "release must not publish pet preview assets"
  [[ ! -e "$target/quota-panel" ]] || fail "release must not publish a standalone quota-panel directory"
  local unmanaged_artifact
  for unmanaged_artifact in .claude .cursor .zcode .omp; do
    [[ ! -e "$target/$unmanaged_artifact" ]] \
      || fail "release must not contain vendor config or unmanaged hooks: $unmanaged_artifact"
  done
  require_dir "$target/ThreadHelm.app"
  require_file "$target/$LABEL.plist.in"
  require_file "$target/安装ThreadHelm.command"
  require_file "$target/检查ThreadHelm.command"
  require_file "$target/卸载ThreadHelm.command"
  require_file "$target/local-install-transaction.zsh"
  require_file "$target/README.md"
  require_file "$target/VERSION.txt"
  require_file "$target/LICENSE"
  require_file "$target/PRIVACY.md"
  require_file "$target/ASSET-NOTICE.md"
  require_file "$target/CHECKSUMS-SHA256.txt"
  local app="$target/ThreadHelm.app"
  local binary="$app/Contents/MacOS/ThreadHelm"
  local launch_agent="$target/$LABEL.plist.in"
  require_file "$app/Contents/Resources/ThreadHelm.icns"
  [[ ! -e "$app/Contents/Resources/ThreadHelmPetSpritesheet.webp" ]] \
    || fail "release must not contain the desktop-pet spritesheet"
  [[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$launch_agent" 2>/dev/null)" == "__EXECUTABLE__" ]] \
    && ! /usr/bin/plutil -extract ProgramArguments.1 raw "$launch_agent" >/dev/null 2>&1 \
    || fail "launch agent template must contain exactly one executable argument"
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == "dev.threadhelm.app" ]] \
    || fail "ThreadHelm bundle identifier is not dev.threadhelm.app"
  [[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" == "ThreadHelm" ]] \
    || fail "ThreadHelm executable identity is invalid"
  if /usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist" >/dev/null 2>&1; then
    fail "standalone ThreadHelm must not be an LSUIElement helper"
  fi
  if [[ "$SKIP_APP_BINARY_CHECKS" != true ]]; then
    # 本发行只面向 Apple 芯片：要求 arm64，并拒收混入其他架构的胖二进制。
    /usr/bin/lipo "$binary" -verify_arch arm64
    [[ "$(/usr/bin/lipo -archs "$binary")" == "arm64" ]]
    /usr/bin/codesign --verify --deep --strict "$app"
  fi
  scan_release_for_forbidden_terms "$target"
  verify_stage_checksum_manifest "$target"
}

verify_stage_checksum_manifest() {
  local target="$1"
  (
    cd "$target"
    /usr/bin/shasum -a 256 -c CHECKSUMS-SHA256.txt >/dev/null
  ) || fail "release payload checksum manifest is invalid: $target/CHECKSUMS-SHA256.txt"
}

stage_release() {
  /bin/rm -rf "$STAGE"
  mkdir -p "$STAGE"
  /usr/bin/ditto "$APP_BUILD" "$STAGE/ThreadHelm.app"
  /bin/cp "$PLIST_TEMPLATE" "$STAGE/$LABEL.plist.in"
  /bin/cp "$INSTALL_COMMAND" "$STAGE/安装ThreadHelm.command"
  /bin/cp "$CHECK_COMMAND" "$STAGE/检查ThreadHelm.command"
  /bin/cp "$UNINSTALL_COMMAND" "$STAGE/卸载ThreadHelm.command"
  /bin/cp "$TRANSACTION_HELPER" "$STAGE/local-install-transaction.zsh"
  /bin/chmod +x "$STAGE"/*.command
  /bin/cp "$ROOT/macos/README.md" "$STAGE/README.md"
  /bin/cp "$ROOT/macos/VERSION.txt" "$STAGE/VERSION.txt"
  /bin/cp "$ROOT/LICENSE" "$ROOT/PRIVACY.md" "$ROOT/ASSET-NOTICE.md" "$STAGE/"

  (
    cd "$STAGE"
    export LC_ALL=C
    find . -type f ! -name CHECKSUMS-SHA256.txt -print | sort |
      while IFS= read -r file; do
        /usr/bin/shasum -a 256 "$file"
      done > CHECKSUMS-SHA256.txt
  )
}

release_input_paths() {
  local -a input_roots
  input_roots=()
  [[ -d "$APP_BUILD" ]] && input_roots+=("$APP_BUILD")
  [[ -d "$AGENT_TRUTH_ROOT" ]] && input_roots+=("$AGENT_TRUTH_ROOT")

  print -r -- "$SCRIPT_PATH"
  print -r -- "$ROOT/macos/README.md"
  print -r -- "$ROOT/macos/VERSION.txt"
  print -r -- "$ROOT/LICENSE"
  print -r -- "$ROOT/PRIVACY.md"
  print -r -- "$ROOT/ASSET-NOTICE.md"
  print -r -- "$PLIST_TEMPLATE"
  print -r -- "$INSTALL_COMMAND"
  print -r -- "$CHECK_COMMAND"
  print -r -- "$UNINSTALL_COMMAND"
  print -r -- "$TRANSACTION_HELPER"
  if (( ${#input_roots[@]} > 0 )); then
    find "${input_roots[@]}" -type f -print
  fi
}

newest_release_input_mtime() {
  release_input_paths | while IFS= read -r input_path; do
    [[ -e "$input_path" ]] && /usr/bin/stat -f "%m" "$input_path"
  done | /usr/bin/sort -n | /usr/bin/tail -1
}

verify_dist_checksum() {
  require_file "$OUT"
  require_file "$CHECKSUM_OUT"
  (
    cd "$ROOT/dist"
    /usr/bin/shasum -a 256 -c "${RELEASE_ID}.zip.sha256" >/dev/null
  ) || fail "release archive checksum is invalid: $CHECKSUM_OUT"
}

verify_dist_is_fresh_against_local_build() {
  local newest archive_mtime
  newest="$(newest_release_input_mtime)"
  archive_mtime="$(/usr/bin/stat -f "%m" "$OUT")"
  [[ -n "$newest" ]] || fail "could not determine release input mtimes"
  (( archive_mtime >= newest )) || fail "release archive is stale relative to release inputs: $OUT"
}

verify_release_file_matches() {
  local source="$1"
  local packaged="$2"
  /usr/bin/cmp -s "$source" "$packaged" \
    || fail "release payload differs from current source: $packaged"
}

verify_release_directory_matches() {
  local source="$1"
  local packaged="$2"
  /usr/bin/diff -qr "$source" "$packaged" >/dev/null \
    || fail "release payload differs from current source: $packaged"
}

verify_stage_matches_current_sources() {
  local target="$1"
  verify_release_file_matches \
    "$PLIST_TEMPLATE" \
    "$target/$LABEL.plist.in"
  verify_release_file_matches "$INSTALL_COMMAND" "$target/安装ThreadHelm.command"
  verify_release_file_matches "$CHECK_COMMAND" "$target/检查ThreadHelm.command"
  verify_release_file_matches "$UNINSTALL_COMMAND" "$target/卸载ThreadHelm.command"
  verify_release_file_matches \
    "$TRANSACTION_HELPER" \
    "$target/local-install-transaction.zsh"
  verify_release_file_matches "$ROOT/macos/README.md" "$target/README.md"
  verify_release_file_matches "$ROOT/macos/VERSION.txt" "$target/VERSION.txt"
  verify_release_file_matches "$ROOT/LICENSE" "$target/LICENSE"
  verify_release_file_matches "$ROOT/PRIVACY.md" "$target/PRIVACY.md"
  verify_release_file_matches "$ROOT/ASSET-NOTICE.md" "$target/ASSET-NOTICE.md"

  if [[ -d "$APP_BUILD" ]]; then
    verify_release_directory_matches \
      "$APP_BUILD" \
      "$target/ThreadHelm.app"
  fi
}

verify_dist_payload() {
  local unpack_root
  unpack_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/threadhelm-release-verify.XXXXXX")"
  /usr/bin/ditto -x -k "$OUT" "$unpack_root"
  verify_stage "$unpack_root/$RELEASE_ID"
  verify_stage_matches_current_sources "$unpack_root/$RELEASE_ID"
  local binary="$unpack_root/$RELEASE_ID/ThreadHelm.app/Contents/MacOS/ThreadHelm"
  verify_app_self_tests "$binary"
  verify_agent_truth_replay "$binary"
  /bin/rm -rf "$unpack_root"
}

run_repository_checks() {
  /usr/bin/python3 "$ROOT/scripts/validate-repository-layout.py"
  THREADHELM_PRIVACY_AUDIT_ROOT="$ROOT" "$ROOT/scripts/privacy-audit.sh"
}

verify_inputs

if [[ "$VERIFY_ONLY" == true ]]; then
  run_repository_checks
  verify_dist_checksum
  verify_dist_is_fresh_against_local_build
  verify_dist_payload
  if [[ -d "$STAGE" ]]; then
    verify_stage "$STAGE"
    verify_stage_matches_current_sources "$STAGE"
    verify_app_self_tests "$STAGE/ThreadHelm.app/Contents/MacOS/ThreadHelm"
    verify_agent_truth_replay "$STAGE/ThreadHelm.app/Contents/MacOS/ThreadHelm"
  fi
  /bin/echo "verify-only passed"
  exit 0
fi

"$APP_PROJECT/scripts/build.sh" >/dev/null
require_dir "$APP_BUILD"
stage_release
verify_stage "$STAGE"
verify_stage_matches_current_sources "$STAGE"
verify_app_self_tests "$STAGE/ThreadHelm.app/Contents/MacOS/ThreadHelm"
verify_agent_truth_replay "$STAGE/ThreadHelm.app/Contents/MacOS/ThreadHelm"
mkdir -p "$ROOT/dist"
/bin/rm -f "$OUT"
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGE" "$OUT"
(
  cd "$ROOT/dist"
  /usr/bin/shasum -a 256 "$RELEASE_ID.zip" > "$RELEASE_ID.zip.sha256"
)
/bin/echo "$OUT"
