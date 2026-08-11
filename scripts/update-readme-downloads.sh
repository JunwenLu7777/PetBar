#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "用法：$0 <语义化 Release 版本，例如 1.0.0>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
CURRENT_VERSION="$(
  grep -oE 'ChatBird-macOS-arm64-[0-9]+\.[0-9]+\.[0-9]+\.zip' "$README" \
    | head -n 1 \
    | sed -E 's/^ChatBird-macOS-arm64-([0-9]+\.[0-9]+\.[0-9]+)\.zip$/\1/'
)"

[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "README 中找不到 ChatBird 当前版本。" >&2
  exit 1
}

if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
  echo "README 已经指向 ChatBird Release ${VERSION}。"
  exit 0
fi

TEMP_FILE="$(mktemp)"
trap 'rm -f "$TEMP_FILE"' EXIT
sed "s/ChatBird-macOS-arm64-$CURRENT_VERSION\\.zip/ChatBird-macOS-arm64-$VERSION.zip/g; s/当前发行版本为 \\*\\*$CURRENT_VERSION\\*\\*/当前发行版本为 **$VERSION**/g" \
  "$README" > "$TEMP_FILE"
mv "$TEMP_FILE" "$README"
trap - EXIT

echo "README 已更新到 ChatBird Release ${VERSION}。"
