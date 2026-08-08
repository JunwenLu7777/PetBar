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

# 当前发行只面向 Apple 芯片，因此只构建 arm64。
# 先编译进临时目录，成功后才替换 build/ 里的 app：编译失败时上一次可用的
# app 原样保留，不会留下没有可执行文件的空壳。
if ! /usr/bin/swiftc \
  -swift-version 5 \
  -O \
  -target "arm64-apple-macos12.3" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Network \
  -framework Security \
  "${SOURCE_FILES[@]}" \
  -o "$TMP_DIR/ChatBirdQuotaPanel-arm64" 2>"$TMP_DIR/arm64.log"
then
  /bin/cat "$TMP_DIR/arm64.log" >&2
  echo "arm64 构建失败；已保留现有 app 未做改动。" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT"/Resources/ProviderIcon-*.svg "$RESOURCES/"

cp "$TMP_DIR/ChatBirdQuotaPanel-arm64" "$MACOS/ChatBirdQuotaPanel"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT/Resources/ChatBirdQuotaPanel.entitlements" \
  "$APP"
echo "$APP"
