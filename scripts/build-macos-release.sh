#!/bin/zsh
set -euo pipefail

SCRIPT_PATH="${0:A}"
ROOT="${CHATBIRD_RELEASE_ROOT:-${SCRIPT_PATH:h:h}}"
VERSION="1.0.0"
RELEASE_ID="ChatBird-NT-macOS-Universal-$VERSION"
STAGE="$ROOT/build/release/$RELEASE_ID"
OUT="$ROOT/dist/$RELEASE_ID.zip"
CHECKSUM_OUT="$OUT.sha256"
APP_PROJECT="$ROOT/macos/ChatBirdQuotaPanel"
APP_BUILD="$APP_PROJECT/build/ChatBird 额度面板.app"
LABEL="dev.chatbird.codex-quota-panel"
PLIST_TEMPLATE="$APP_PROJECT/Resources/$LABEL.plist.in"
PET_SOURCE="${CHATBIRD_PET_SOURCE:-$ROOT/shared/pet/chatbird-nt}"
PREVIEW_QA_SOURCE="${CHATBIRD_PREVIEW_QA_SOURCE:-$ROOT/shared/preview/chatbird-nt}"
INSTALL_COMMAND="$ROOT/macos/package/安装ChatBird.command"
CHECK_COMMAND="$ROOT/macos/package/检查ChatBird.command"
UNINSTALL_COMMAND="$ROOT/macos/package/卸载ChatBird.command"
VERIFY_ONLY=false
SKIP_STRICT_PET_MEDIA_CHECKS="${CHATBIRD_SKIP_STRICT_PET_MEDIA_CHECKS:-false}"
SKIP_APP_BINARY_CHECKS="${CHATBIRD_SKIP_APP_BINARY_CHECKS:-false}"

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

require_nonempty_dir() {
  require_dir "$1"
  find "$1" -type f -print -quit | /usr/bin/grep -q . \
    || fail "directory has no files: $1"
}

verify_pet() {
  require_file "$PET_SOURCE/pet.json"
  require_file "$PET_SOURCE/spritesheet.webp"
  [[ "$(/usr/bin/plutil -extract id raw "$PET_SOURCE/pet.json")" == "chatbird-nt" ]] \
    || fail "pet id is not chatbird-nt"
  [[ "$(/usr/bin/plutil -extract spriteVersionNumber raw "$PET_SOURCE/pet.json")" == "2" ]] \
    || fail "pet spriteVersionNumber is not 2"
  [[ "$SKIP_STRICT_PET_MEDIA_CHECKS" == true ]] && return 0
  [[ "$(/usr/bin/sips -g pixelWidth "$PET_SOURCE/spritesheet.webp" | /usr/bin/awk '/pixelWidth:/{print $2}')" == "1536" ]] \
    || fail "pet atlas width is not 1536"
  [[ "$(/usr/bin/sips -g pixelHeight "$PET_SOURCE/spritesheet.webp" | /usr/bin/awk '/pixelHeight:/{print $2}')" == "2288" ]] \
    || fail "pet atlas height is not 2288"
}

verify_inputs() {
  require_dir "$PET_SOURCE"
  verify_pet
  require_nonempty_dir "$PREVIEW_QA_SOURCE"
  require_file "$APP_PROJECT/scripts/build.sh"
  require_file "$PLIST_TEMPLATE"
  require_file "$INSTALL_COMMAND"
  require_file "$CHECK_COMMAND"
  require_file "$UNINSTALL_COMMAND"
  require_file "$ROOT/macos/README.md"
  require_file "$ROOT/macos/VERSION.txt"
  require_file "$ROOT/LICENSE"
  require_file "$ROOT/PRIVACY.md"
  require_file "$ROOT/ASSET-NOTICE.md"
  /usr/bin/plutil -lint "$PLIST_TEMPLATE" >/dev/null
  /bin/zsh -n "$INSTALL_COMMAND" "$CHECK_COMMAND" "$UNINSTALL_COMMAND"
}

verify_release_build_inputs() {
  require_dir "$APP_BUILD"
}

path_has_forbidden_marker() {
  local candidate_path="${1:l}"
  local component token
  local -a components tokens markers
  markers=(mayday bubu orange windows codex-only)
  components=("${(@s:/:)candidate_path}")
  for component in "${components[@]}"; do
    tokens=("${(@s:-:)${component//[^[:alnum:]-]/-}}")
    for token in "${tokens[@]}"; do
      for marker in "${markers[@]}"; do
        if [[ "$component" == "$marker" || "$token" == "$marker" ]]; then
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
  require_file "$target/pet/chatbird-nt/pet.json"
  require_file "$target/pet/chatbird-nt/spritesheet.webp"
  require_dir "$target/quota-panel/ChatBird 额度面板.app"
  require_file "$target/quota-panel/$LABEL.plist.in"
  require_file "$target/安装ChatBird.command"
  require_file "$target/检查ChatBird.command"
  require_file "$target/卸载ChatBird.command"
  require_file "$target/README.md"
  require_file "$target/VERSION.txt"
  require_file "$target/LICENSE"
  require_file "$target/PRIVACY.md"
  require_file "$target/ASSET-NOTICE.md"
  require_file "$target/CHECKSUMS-SHA256.txt"
  require_nonempty_dir "$target/preview-qa"

  local binary="$target/quota-panel/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
  if [[ "$SKIP_APP_BINARY_CHECKS" != true ]]; then
    /usr/bin/lipo "$binary" -verify_arch arm64
    /usr/bin/lipo "$binary" -verify_arch x86_64
    /usr/bin/codesign --verify --deep --strict "$target/quota-panel/ChatBird 额度面板.app"
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
  mkdir -p "$STAGE/pet" "$STAGE/quota-panel" "$STAGE/preview-qa"
  /usr/bin/ditto "$PET_SOURCE" "$STAGE/pet/chatbird-nt"
  /usr/bin/ditto "$PREVIEW_QA_SOURCE" "$STAGE/preview-qa"
  /usr/bin/ditto "$APP_BUILD" "$STAGE/quota-panel/ChatBird 额度面板.app"
  /bin/cp "$PLIST_TEMPLATE" "$STAGE/quota-panel/$LABEL.plist.in"
  /bin/cp "$INSTALL_COMMAND" "$STAGE/安装ChatBird.command"
  /bin/cp "$CHECK_COMMAND" "$STAGE/检查ChatBird.command"
  /bin/cp "$UNINSTALL_COMMAND" "$STAGE/卸载ChatBird.command"
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
  find "$PET_SOURCE" "$PREVIEW_QA_SOURCE" "$APP_BUILD" -type f -print
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

verify_dist_is_fresh() {
  local newest archive_mtime
  newest="$(newest_release_input_mtime)"
  archive_mtime="$(/usr/bin/stat -f "%m" "$OUT")"
  [[ -n "$newest" ]] || fail "could not determine release input mtimes"
  (( archive_mtime >= newest )) || fail "release archive is stale relative to release inputs: $OUT"
}

verify_dist_payload() {
  local unpack_root
  unpack_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatbird-release-verify.XXXXXX")"
  /usr/bin/ditto -x -k "$OUT" "$unpack_root"
  verify_stage "$unpack_root/$RELEASE_ID"
  /bin/rm -rf "$unpack_root"
}

run_repository_checks() {
  /usr/bin/python3 "$ROOT/scripts/validate-repository-layout.py"
  CHATBIRD_PRIVACY_AUDIT_ROOT="$ROOT" "$ROOT/scripts/privacy-audit.sh"
}

verify_inputs

if [[ "$VERIFY_ONLY" == true ]]; then
  verify_release_build_inputs
  run_repository_checks
  verify_dist_checksum
  verify_dist_is_fresh
  verify_dist_payload
  if [[ -d "$STAGE" ]]; then
    verify_stage "$STAGE"
  fi
  /bin/echo "verify-only passed"
  exit 0
fi

"$APP_PROJECT/scripts/build.sh" >/dev/null
require_dir "$APP_BUILD"
stage_release
verify_stage "$STAGE"
mkdir -p "$ROOT/dist"
/bin/rm -f "$OUT"
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGE" "$OUT"
(
  cd "$ROOT/dist"
  /usr/bin/shasum -a 256 "$RELEASE_ID.zip" > "$RELEASE_ID.zip.sha256"
)
/bin/echo "$OUT"
