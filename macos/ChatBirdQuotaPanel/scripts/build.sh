#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/ChatBird 额度面板.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SOURCE_FILES=("$ROOT"/Sources/ChatBirdQuotaPanel/*.swift(N))

if (( ${#SOURCE_FILES[@]} == 0 )); then
  echo "没有找到 Swift 源文件" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT"/Resources/ProviderIcon-*.svg "$RESOURCES/"

for ARCH in arm64 x86_64; do
  /usr/bin/swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos12.3" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Network \
    -framework Security \
    "${SOURCE_FILES[@]}" \
    -o "$TMP_DIR/ChatBirdQuotaPanel-$ARCH"
done

/usr/bin/lipo -create \
  "$TMP_DIR/ChatBirdQuotaPanel-arm64" \
  "$TMP_DIR/ChatBirdQuotaPanel-x86_64" \
  -output "$MACOS/ChatBirdQuotaPanel"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT/Resources/ChatBirdQuotaPanel.entitlements" \
  "$APP"
echo "$APP"
