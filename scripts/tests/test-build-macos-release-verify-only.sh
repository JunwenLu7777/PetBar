#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatbird-release-test.XXXXXX")"
VERIFY_OUTPUT="$FIXTURE/.git/chatbird-test-output/verify.out"
VERIFY_ERROR="$FIXTURE/.git/chatbird-test-output/verify.err"
trap '/bin/rm -rf "$FIXTURE"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

run_verify() {
  CHATBIRD_RELEASE_ROOT="$FIXTURE" \
  CHATBIRD_SKIP_APP_BINARY_CHECKS=true \
    "$FIXTURE/scripts/build-macos-release.sh" --verify-only \
      >"$VERIFY_OUTPUT" 2>"$VERIFY_ERROR"
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
    /bin/cat "$VERIFY_ERROR" >&2 || true
    fail "$label unexpectedly failed"
  fi
  if [[ -s "$VERIFY_ERROR" ]]; then
    /bin/cat "$VERIFY_ERROR" >&2
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
  local stage="$FIXTURE/build/release/ChatBird-macOS-arm64-1.1.0"
  local local_app="$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app"
  /bin/rm -rf "$stage"
  mkdir -p \
    "$stage/ChatBird.app/Contents/MacOS" \
    "$stage/ChatBird.app/Contents/Resources"
  /bin/cp "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/dev.chatbird.app.plist.in" \
    "$stage/dev.chatbird.app.plist.in"
  if [[ -d "$local_app" ]]; then
    /bin/rm -rf "$stage/ChatBird.app"
    /usr/bin/ditto "$local_app" "$stage/ChatBird.app"
  else
    write_file "$stage/ChatBird.app/Contents/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.chatbird.app</string><key>CFBundleExecutable</key><string>ChatBird</string><key>CFBundleIconFile</key><string>ChatBird.icns</string></dict></plist>'
    write_file "$stage/ChatBird.app/Contents/MacOS/ChatBird" "fake binary"
    write_file "$stage/ChatBird.app/Contents/Resources/ChatBird.icns" "fake icon"
    /bin/chmod +x "$stage/ChatBird.app/Contents/MacOS/ChatBird"
  fi
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
  /bin/rm -f "$FIXTURE/dist/ChatBird-macOS-arm64-1.1.0.zip" \
    "$FIXTURE/dist/ChatBird-macOS-arm64-1.1.0.zip.sha256"
  /usr/bin/ditto -c -k --norsrc --keepParent \
    "$FIXTURE/build/release/ChatBird-macOS-arm64-1.1.0" \
    "$FIXTURE/dist/ChatBird-macOS-arm64-1.1.0.zip"
  (
    cd "$FIXTURE/dist"
    /usr/bin/shasum -a 256 ChatBird-macOS-arm64-1.1.0.zip \
      > ChatBird-macOS-arm64-1.1.0.zip.sha256
  )
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/macos/package" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/Resources" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/scripts"

/bin/cp "$ROOT/scripts/build-macos-release.sh" "$FIXTURE/scripts/build-macos-release.sh"
/bin/cp "$ROOT/scripts/privacy-audit.sh" "$FIXTURE/scripts/privacy-audit.sh"
/bin/cp "$ROOT/scripts/validate-repository-layout.py" "$FIXTURE/scripts/validate-repository-layout.py"
/bin/chmod +x "$FIXTURE/scripts/build-macos-release.sh" "$FIXTURE/scripts/privacy-audit.sh"

write_file "$FIXTURE/macos/README.md" "macOS README"
write_file "$FIXTURE/macos/VERSION.txt" "Version: 1.1.0"
write_file "$FIXTURE/LICENSE" "license"
write_file "$FIXTURE/PRIVACY.md" "privacy"
write_file "$FIXTURE/ASSET-NOTICE.md" "asset notice"
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/dev.chatbird.app.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.chatbird.app</string><key>ProgramArguments</key><array><string>__EXECUTABLE__</string></array></dict></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/ChatBirdQuotaPanel.entitlements" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Sources/ChatBirdQuotaPanel/main.swift" "print(\"ChatBird\")"
write_command "$FIXTURE/macos/ChatBirdQuotaPanel/scripts/build.sh"
write_command "$FIXTURE/macos/package/安装ChatBird.command"
write_command "$FIXTURE/macos/package/检查ChatBird.command"
write_command "$FIXTURE/macos/package/卸载ChatBird.command"

git -C "$FIXTURE" init -q
mkdir -p "${VERIFY_OUTPUT:h}"
git -C "$FIXTURE" add -A

expect_fail "missing dist archive"

make_stage
[[ ! -e "$FIXTURE/build/release/ChatBird-macOS-arm64-1.1.0/preview-qa" ]] \
  || fail "valid stage contains pet preview assets"
[[ ! -e "$FIXTURE/build/release/ChatBird-macOS-arm64-1.1.0/ChatBird.app/Contents/Resources/ChatBirdPetSpritesheet.webp" ]] \
  || fail "valid stage contains pet spritesheet"
sleep 1
make_dist_from_stage
/bin/rm -rf "$FIXTURE/build/release"
git -C "$FIXTURE" add -A
expect_pass "valid archive without staging or local app build"

write_file "$FIXTURE/macos/README.md" "newer macOS README"
expect_fail "stale source payload without local app build"

make_stage
make_dist_from_stage
/bin/rm -rf "$FIXTURE/build/release"
expect_pass "refreshed source payload without local app build"

/bin/sleep 1
mkdir -p "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS" \
  "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/Resources"
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.chatbird.app</string><key>CFBundleExecutable</key><string>ChatBird</string><key>CFBundleIconFile</key><string>ChatBird.icns</string></dict></plist>'
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird" "fake binary"
write_file "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/Resources/ChatBird.icns" "fake icon"
/bin/chmod +x "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird"
expect_fail "archive older than matching local app build"

make_stage
make_dist_from_stage
expect_pass "matching local app build"

write_file "$FIXTURE/macos/ChatBirdQuotaPanel/build/ChatBird.app/Contents/MacOS/ChatBird" "newer local binary"
expect_fail "stale archive relative to local app build"

make_stage
make_dist_from_stage
git -C "$FIXTURE" add dist
write_file "$FIXTURE/dist/ChatBird-macOS-arm64-1.1.0.zip.sha256" "bad  ChatBird-macOS-arm64-1.1.0.zip\n"
expect_fail "bad archive checksum"

make_dist_from_stage
git -C "$FIXTURE" add dist
/bin/rm "$FIXTURE/build/release/ChatBird-macOS-arm64-1.1.0/README.md"
expect_fail "invalid staged payload"

write_file "$FIXTURE/macos/ChatBirdQuotaPanel/Resources/dev.chatbird.app.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.chatbird.app</string><key>ProgramArguments</key><array><string>__EXECUTABLE__</string><string>__EXECUTABLE__</string></array></dict></plist>'
make_stage
make_dist_from_stage
git -C "$FIXTURE" add dist
expect_fail "launch agent template with extra program argument"

/bin/echo "build macOS release verify-only tests passed"
