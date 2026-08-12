#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/threadhelm-release-test.XXXXXX")"
VERIFY_OUTPUT="$FIXTURE/.git/threadhelm-test-output/verify.out"
VERIFY_ERROR="$FIXTURE/.git/threadhelm-test-output/verify.err"
trap '/bin/rm -rf "$FIXTURE"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

run_verify() {
  THREADHELM_RELEASE_ROOT="$FIXTURE" \
  THREADHELM_SKIP_APP_BINARY_CHECKS=true \
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
  local stage="$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0"
  local local_app="$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app"
  /bin/rm -rf "$stage"
  mkdir -p \
    "$stage/ThreadHelm.app/Contents/MacOS" \
    "$stage/ThreadHelm.app/Contents/Resources"
  /bin/cp "$FIXTURE/macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in" \
    "$stage/dev.threadhelm.app.plist.in"
  if [[ -d "$local_app" ]]; then
    /bin/rm -rf "$stage/ThreadHelm.app"
    /usr/bin/ditto "$local_app" "$stage/ThreadHelm.app"
  else
    write_file "$stage/ThreadHelm.app/Contents/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.threadhelm.app</string><key>CFBundleExecutable</key><string>ThreadHelm</string><key>CFBundleIconFile</key><string>ThreadHelm.icns</string></dict></plist>'
    write_file "$stage/ThreadHelm.app/Contents/MacOS/ThreadHelm" "fake binary"
    write_file "$stage/ThreadHelm.app/Contents/Resources/ThreadHelm.icns" "fake icon"
    /bin/chmod +x "$stage/ThreadHelm.app/Contents/MacOS/ThreadHelm"
  fi
  /bin/cp "$FIXTURE/macos/package/安装ThreadHelm.command" "$stage/安装ThreadHelm.command"
  /bin/cp "$FIXTURE/macos/package/检查ThreadHelm.command" "$stage/检查ThreadHelm.command"
  /bin/cp "$FIXTURE/macos/package/卸载ThreadHelm.command" "$stage/卸载ThreadHelm.command"
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
  /bin/rm -f "$FIXTURE/dist/ThreadHelm-macOS-arm64-1.1.0.zip" \
    "$FIXTURE/dist/ThreadHelm-macOS-arm64-1.1.0.zip.sha256"
  /usr/bin/ditto -c -k --norsrc --keepParent \
    "$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0" \
    "$FIXTURE/dist/ThreadHelm-macOS-arm64-1.1.0.zip"
  (
    cd "$FIXTURE/dist"
    /usr/bin/shasum -a 256 ThreadHelm-macOS-arm64-1.1.0.zip \
      > ThreadHelm-macOS-arm64-1.1.0.zip.sha256
  )
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/macos/package" \
  "$FIXTURE/macos/ThreadHelm/Resources" \
  "$FIXTURE/macos/ThreadHelm/Sources/ThreadHelm" \
  "$FIXTURE/macos/ThreadHelm/scripts"

/bin/cp "$ROOT/scripts/build-macos-release.sh" "$FIXTURE/scripts/build-macos-release.sh"
/bin/cp "$ROOT/scripts/privacy-audit.sh" "$FIXTURE/scripts/privacy-audit.sh"
/bin/cp "$ROOT/scripts/validate-repository-layout.py" "$FIXTURE/scripts/validate-repository-layout.py"
/bin/chmod +x "$FIXTURE/scripts/build-macos-release.sh" "$FIXTURE/scripts/privacy-audit.sh"

write_file "$FIXTURE/macos/README.md" "macOS README"
write_file "$FIXTURE/macos/VERSION.txt" "Version: 1.1.0"
write_file "$FIXTURE/LICENSE" "license"
write_file "$FIXTURE/PRIVACY.md" "privacy"
write_file "$FIXTURE/ASSET-NOTICE.md" "asset notice"
write_file "$FIXTURE/macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.threadhelm.app</string><key>ProgramArguments</key><array><string>__EXECUTABLE__</string></array></dict></plist>'
write_file "$FIXTURE/macos/ThreadHelm/Resources/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ThreadHelm/Resources/ThreadHelm.entitlements" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
write_file "$FIXTURE/macos/ThreadHelm/Sources/ThreadHelm/main.swift" "print(\"ThreadHelm\")"
write_command "$FIXTURE/macos/ThreadHelm/scripts/build.sh"
write_command "$FIXTURE/macos/package/安装ThreadHelm.command"
write_command "$FIXTURE/macos/package/检查ThreadHelm.command"
write_command "$FIXTURE/macos/package/卸载ThreadHelm.command"

git -C "$FIXTURE" init -q
mkdir -p "${VERIFY_OUTPUT:h}"
git -C "$FIXTURE" add -A

expect_fail "missing dist archive"

make_stage
[[ ! -e "$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0/preview-qa" ]] \
  || fail "valid stage contains pet preview assets"
[[ ! -e "$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0/ThreadHelm.app/Contents/Resources/ThreadHelmPetSpritesheet.webp" ]] \
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
mkdir -p "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS" \
  "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/Resources"
write_file "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/Info.plist" '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.threadhelm.app</string><key>CFBundleExecutable</key><string>ThreadHelm</string><key>CFBundleIconFile</key><string>ThreadHelm.icns</string></dict></plist>'
write_file "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm" "fake binary"
write_file "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/Resources/ThreadHelm.icns" "fake icon"
/bin/chmod +x "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm"
expect_fail "archive older than matching local app build"

make_stage
make_dist_from_stage
expect_pass "matching local app build"

write_file "$FIXTURE/macos/ThreadHelm/build/ThreadHelm.app/Contents/MacOS/ThreadHelm" "newer local binary"
expect_fail "stale archive relative to local app build"

make_stage
make_dist_from_stage
git -C "$FIXTURE" add dist
write_file "$FIXTURE/dist/ThreadHelm-macOS-arm64-1.1.0.zip.sha256" "bad  ThreadHelm-macOS-arm64-1.1.0.zip\n"
expect_fail "bad archive checksum"

make_dist_from_stage
git -C "$FIXTURE" add dist
/bin/rm "$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0/README.md"
expect_fail "invalid staged payload"

write_file "$FIXTURE/macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.threadhelm.app</string><key>ProgramArguments</key><array><string>__EXECUTABLE__</string><string>__EXECUTABLE__</string></array></dict></plist>'
make_stage
make_dist_from_stage
git -C "$FIXTURE" add dist
expect_fail "launch agent template with extra program argument"

write_file "$FIXTURE/macos/ThreadHelm/Resources/dev.threadhelm.app.plist.in" '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>dev.threadhelm.app</string><key>ProgramArguments</key><array><string>__EXECUTABLE__</string></array></dict></plist>'
make_stage
write_file "$FIXTURE/build/release/ThreadHelm-macOS-arm64-1.1.0/Chat""Bird.app/legacy.txt" "legacy app"
make_dist_from_stage
git -C "$FIXTURE" add dist
expect_fail "legacy-branded payload path"

/bin/echo "build macOS release verify-only tests passed"
