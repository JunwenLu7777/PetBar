#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "用法：$0 <语义化 Release 版本，例如 1.0.0>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
READMES=("$ROOT/README.md" "$ROOT/macos/README.md")
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
CHANGED=false
INDEX=0

for README in "${READMES[@]}"; do
  [[ -f "$README" ]] || {
    echo "找不到 README：$README" >&2
    exit 1
  }
  grep -qE 'ThreadHelm-macOS-arm64-[0-9]+\.[0-9]+\.[0-9]+\.zip' \
    "$README" || {
      echo "README 中找不到 ThreadHelm 当前版本：$README" >&2
      exit 1
    }
  TEMP_FILE="$TEMP_DIR/readme-$INDEX"
  sed -E \
    "s/ThreadHelm-macOS-arm64-[0-9]+\\.[0-9]+\\.[0-9]+\\.zip/ThreadHelm-macOS-arm64-$VERSION.zip/g; s/当前发行版本为 \\*\\*[0-9]+\\.[0-9]+\\.[0-9]+\\*\\*/当前发行版本为 **$VERSION**/g" \
    "$README" > "$TEMP_FILE"
  if ! cmp -s "$README" "$TEMP_FILE"; then
    CHANGED=true
  fi
  INDEX=$((INDEX + 1))
done

if [[ "$CHANGED" == true ]]; then
  INDEX=0
  for README in "${READMES[@]}"; do
    /bin/cp "$TEMP_DIR/readme-$INDEX" "$README"
    INDEX=$((INDEX + 1))
  done
  echo "README 已更新到 ThreadHelm Release ${VERSION}。"
else
  echo "README 已经指向 ThreadHelm Release ${VERSION}。"
fi
