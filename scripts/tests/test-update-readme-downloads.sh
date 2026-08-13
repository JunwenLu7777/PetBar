#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/threadhelm-readme-update.XXXXXX")"
trap '/bin/rm -rf "$FIXTURE"' EXIT

fail() {
  /bin/echo "test failure: $1" >&2
  exit 1
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/macos"
/bin/cp "$ROOT/scripts/update-readme-downloads.sh" \
  "$FIXTURE/scripts/update-readme-downloads.sh"
/bin/chmod +x "$FIXTURE/scripts/update-readme-downloads.sh"

print -r -- $'# ThreadHelm\n\n当前发行版本为 **1.1.0**\n\nThreadHelm-macOS-arm64-1.1.0.zip' \
  > "$FIXTURE/README.md"
print -r -- $'# ThreadHelm macOS 版\n\n完整解压 `ThreadHelm-macOS-arm64-1.1.0.zip`。' \
  > "$FIXTURE/macos/README.md"

"$FIXTURE/scripts/update-readme-downloads.sh" 1.2.3 >/dev/null

/usr/bin/grep -Fq '当前发行版本为 **1.2.3**' "$FIXTURE/README.md" \
  || fail "root README version was not updated"
/usr/bin/grep -Fq 'ThreadHelm-macOS-arm64-1.2.3.zip' "$FIXTURE/README.md" \
  || fail "root README archive was not updated"
/usr/bin/grep -Fq 'ThreadHelm-macOS-arm64-1.2.3.zip' \
  "$FIXTURE/macos/README.md" \
  || fail "packaged README archive was not updated"

"$FIXTURE/scripts/update-readme-downloads.sh" 1.2.3 >/dev/null \
  || fail "README update is not idempotent"

if "$FIXTURE/scripts/update-readme-downloads.sh" invalid >/dev/null 2>&1; then
  fail "invalid release version was accepted"
fi

print -r -- $'# ThreadHelm\n\n当前发行版本为 **1.2.3**\n\nThreadHelm-macOS-arm64-1.2.3.zip' \
  > "$FIXTURE/README.md"
print -r -- '# package README without an archive' \
  > "$FIXTURE/macos/README.md"
ROOT_BEFORE="$(/usr/bin/shasum -a 256 "$FIXTURE/README.md")"
if "$FIXTURE/scripts/update-readme-downloads.sh" 2.0.0 >/dev/null 2>&1; then
  fail "malformed packaged README was accepted"
fi
[[ "$(/usr/bin/shasum -a 256 "$FIXTURE/README.md")" == "$ROOT_BEFORE" ]] \
  || fail "failed update partially modified the root README"

/bin/echo "ThreadHelm README download update tests passed"
