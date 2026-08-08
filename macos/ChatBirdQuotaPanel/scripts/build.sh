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

NATIVE_ARCH="$(/usr/bin/uname -m)"

# 先把各架构编译进临时目录，全部就绪后才替换 build/ 里的 app：编译失败时
# 上一次可用的 app 原样保留，不会留下没有可执行文件的空壳。
# 本机架构必须成功；另一个架构在当前工具链缺少对应 Swift 兼容库时降级并告警，
# 这样本机安装不被阻塞，而发布包仍由 build-macos-release.sh 校验双架构。
BUILT_BINARIES=()
for ARCH in arm64 x86_64; do
  if /usr/bin/swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos12.3" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework Network \
    -framework Security \
    "${SOURCE_FILES[@]}" \
    -o "$TMP_DIR/ChatBirdQuotaPanel-$ARCH" 2>"$TMP_DIR/$ARCH.log"
  then
    BUILT_BINARIES+=("$TMP_DIR/ChatBirdQuotaPanel-$ARCH")
  elif [[ "$ARCH" == "$NATIVE_ARCH" ]]; then
    /bin/cat "$TMP_DIR/$ARCH.log" >&2
    echo "本机架构 $ARCH 构建失败；已保留现有 app 未做改动。" >&2
    exit 1
  else
    echo "警告：$ARCH 构建失败，本次只产出本机架构 $NATIVE_ARCH。" >&2
    echo "      当前工具链缺少 $ARCH 的 Swift 兼容库时会这样；本机安装不受影响。" >&2
    echo "      发布包要求 arm64+x86_64，请在具备 $ARCH 支持的环境执行 scripts/build-macos-release.sh。" >&2
  fi
done

if (( ${#BUILT_BINARIES[@]} == 0 )); then
  echo "没有任何架构构建成功；已保留现有 app 未做改动。" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT"/Resources/ProviderIcon-*.svg "$RESOURCES/"

/usr/bin/lipo -create "${BUILT_BINARIES[@]}" -output "$MACOS/ChatBirdQuotaPanel"

/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$ROOT/Resources/ChatBirdQuotaPanel.entitlements" \
  "$APP"
echo "$APP"
