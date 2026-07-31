#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatbird-release-test.XXXXXX")"
trap '/bin/rm -rf "$FIXTURE"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

run_verify() {
  CHATBIRD_RELEASE_ROOT="$FIXTURE" \
  CHATBIRD_SKIP_STRICT_PET_MEDIA_CHECKS=true \
  CHATBIRD_SKIP_APP_BINARY_CHECKS=true \
    "$FIXTURE/scripts/build-macos-release.sh" --verify-only >/tmp/chatbird-release-verify.out 2>/tmp/chatbird-release-verify.err
}

expect_fail() {
  local label="$1"
  if run_verify; then
    fail "$label unexpectedly passed"
  fi
}

expect_pass() {
  local label="$1"
  if ! run_verify; then
    /bin/cat /tmp/chatbird-release-verify.err >&2 || true
    fail "$label unexpectedly failed"
  fi
  if [[ -s /tmp/chatbird-release-verify.err ]]; then
    /bin/cat /tmp/chatbird-release-verify.err >&2
    fail "$label wrote unexpected stderr"
  fi
}

write_file() {
  mkdir -p "${1:h}"
  printf "%s" "$2" > "$1"
}

write_command() {
  write_file "$1" "#!/bin/zsh\nexit 0\n"
  /bin/chmod +x "$1"
}

make_stage() {
  local stage="$FIXTURE/build/release/ChatBird-NT-macOS-Universal-1.0.0"
  /bin/rm -rf "$stage"
  mkdir -p \
    "$stage/pet/chatbird-nt" \
    "$stage/preview-qa" \
    "$stage/quota-panel/ChatBird 额度面板.app/Contents/MacOS"
  /bin/cp "$FIXTURE/shared/pet/chatbird-nt/pet.json" "$stage/pet/chatbird-nt/pet.json"
  /bin/cp "$FIXTURE/shared/pet/chatbird-nt/spritesheet.webp" "$stage/pet/chatbird-nt/spritesheet.webp"
  /bin/cp "$FIXTURE/shared/preview/chatbird-nt/panel-preview.png" "$stage/preview-qa/panel-preview.png"
  /bin/cp "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/dev.chatbird.codex-quota-panel.plist.in" \
    "$stage/quota-panel/dev.chatbird.codex-quota-panel.plist.in"
  write_file "$stage/quota-panel/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel" "fake binary"
  /bin/chmod +x "$stage/quota-panel/ChatBird 额度面板.app/Contents/MacOS/ChatBirdQuotaPanel"
  /bin/cp "$FIXTURE/macos/package/安装ChatBird.command" "$stage/安装ChatBird.command"
  /bin/cp "$FIXTURE/macos/package/检查ChatBird.command" "$stage/检查ChatBird.command"
  /bin/cp "$FIXTURE/macos/package/卸载ChatBird.command" "$stage/卸载ChatBird.command"
  /bin/cp "$FIXTURE/macos/README.md" "$stage/README.md"
  /bin/cp "$FIXTURE/macos/VERSION.txt" "$stage/VERSION.txt"
  /bin/cp "$FIXTURE/LICENSE" "$FIXTURE/PRIVACY.md" "$FIXTURE/ASSET-NOTICE.md" "$stage/"
  (
    cd "$stage"
    find . -type f ! -name CHECKSUMS-SHA256.txt -print | sort |
      while IFS= read -r file; do
        /usr/bin/shasum -a 256 "$file"
      done > CHECKSUMS-SHA256.txt
  )
}

make_dist_from_stage() {
  mkdir -p "$FIXTURE/dist"
  /bin/rm -f "$FIXTURE/dist/ChatBird-NT-macOS-Universal-1.0.0.zip" \
    "$FIXTURE/dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256"
  /usr/bin/ditto -c -k --norsrc --keepParent \
    "$FIXTURE/build/release/ChatBird-NT-macOS-Universal-1.0.0" \
    "$FIXTURE/dist/ChatBird-NT-macOS-Universal-1.0.0.zip"
  (
    cd "$FIXTURE/dist"
    /usr/bin/shasum -a 256 ChatBird-NT-macOS-Universal-1.0.0.zip \
      > ChatBird-NT-macOS-Universal-1.0.0.zip.sha256
  )
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/macos/package" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/Resources" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/scripts" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird 额度面板.app" \
  "$FIXTURE/shared/pet/chatbird-nt" \
  "$FIXTURE/shared/preview/chatbird-nt"

/bin/cp "$ROOT/scripts/build-macos-release.sh" "$FIXTURE/scripts/build-macos-release.sh"
/bin/cp "$ROOT/scripts/privacy-audit.sh" "$FIXTURE/scripts/privacy-audit.sh"
/bin/cp "$ROOT/scripts/validate-repository-layout.py" "$FIXTURE/scripts/validate-repository-layout.py"
/bin/chmod +x "$FIXTURE/scripts/build-macos-release.sh" "$FIXTURE/scripts/privacy-audit.sh"

write_file "$FIXTURE/shared/pet/chatbird-nt/pet.json" '{"id":"chatbird-nt","spriteVersionNumber":2}'
write_file "$FIXTURE/shared/pet/chatbird-nt/spritesheet.webp" "fake webp"
write_file "$FIXTURE/shared/preview/chatbird-nt/panel-preview.png" "preview"
write_file "$FIXTURE/macos/README.md" "macOS README"
write_file "$FIXTURE/macos/VERSION.txt" "Version: 1.0.0"
write_file "$FIXTURE/LICENSE" "license"
write_file "$FIXTURE/PRIVACY.md" "privacy"
write_file "$FIXTURE/ASSET-NOTICE.md" "asset notice"
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/dev.chatbird.codex-quota-panel.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.chatbird.codex-quota-panel</string></dict></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/ChatBirdQuotaPanel.entitlements" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift" "print(\"ChatBird\")"
write_command "$FIXTURE/macos/ChatBirdQuotaPanel/scripts/build.sh"
write_command "$FIXTURE/macos/package/安装ChatBird.command"
write_command "$FIXTURE/macos/package/检查ChatBird.command"
write_command "$FIXTURE/macos/package/卸载ChatBird.command"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" add -A

expect_fail "missing dist archive"

make_stage
sleep 1
make_dist_from_stage
/bin/rm -rf "$FIXTURE/build/release"
git -C "$FIXTURE" add -A
expect_pass "valid archive without staging"

sleep 1
write_file "$FIXTURE/macos/README.md" "newer macOS README"
expect_fail "stale archive"

make_stage
sleep 1
make_dist_from_stage
git -C "$FIXTURE" add dist
write_file "$FIXTURE/dist/ChatBird-NT-macOS-Universal-1.0.0.zip.sha256" "bad  ChatBird-NT-macOS-Universal-1.0.0.zip\n"
expect_fail "bad archive checksum"

make_dist_from_stage
git -C "$FIXTURE" add dist
/bin/rm "$FIXTURE/build/release/ChatBird-NT-macOS-Universal-1.0.0/README.md"
expect_fail "invalid staged payload"

/bin/echo "build macOS release verify-only tests passed"
