#!/bin/bash
# 构建 FishAi.app 到 build/
#   ./build.sh           开发构建：本机架构，FishAi Dev 证书（或 ad-hoc）签名
#   ./build.sh release   发布构建：通用二进制，Developer ID 签名 → 打包 dmg → 公证 → 装订
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-dev}"
case "$MODE" in
    dev|release) ;;
    *) echo "usage: $0 [dev|release]" >&2; exit 1 ;;
esac

VERSION="0.1.0"
BUILD_NUMBER="1"

# 发布构建先检查证书和公证凭据，避免编译完才失败
if [ "$MODE" = release ]; then
    # 默认取钥匙串里第一个 Developer ID Application 证书，也可以用 FISHAI_DEVELOPER_ID 指定
    IDENTITY="${FISHAI_DEVELOPER_ID:-$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
    if [ -z "$IDENTITY" ]; then
        echo "error: no \"Developer ID Application\" certificate found in keychain" >&2
        exit 1
    fi
    # 公证凭据通过 xcrun notarytool store-credentials 存在钥匙串里
    NOTARY_PROFILE="${FISHAI_NOTARY_PROFILE:-FishAi-notary}"
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "error: notary profile \"$NOTARY_PROFILE\" not found, run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\"" >&2
        exit 1
    fi
    # 发布版同时支持 Apple 芯片和 Intel
    SWIFT_ARGS=(-c release --arch arm64 --arch x86_64)
else
    SWIFT_ARGS=(-c release)
fi

swift build "${SWIFT_ARGS[@]}"
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/FishAi"

APP="build/FishAi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FishAi"
cp Resources/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FishAi</string>
    <key>CFBundleDisplayName</key><string>FishAi</string>
    <key>CFBundleIdentifier</key><string>com.lglgl.FishAi</string>
    <key>CFBundleExecutable</key><string>FishAi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [ "$MODE" = dev ]; then
    # 使用固定证书签名，系统才能在重新构建后保留屏幕录制、钥匙串等授权；
    # 找不到证书时退回 ad-hoc 签名（每次构建都需要重新授权）
    IDENTITY="${FISHAI_SIGN_IDENTITY:-FishAi Dev}"
    if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
        /usr/bin/codesign --force --sign "$IDENTITY" "$APP"
    else
        echo "warning: signing identity \"$IDENTITY\" not found, using ad-hoc signature" >&2
        /usr/bin/codesign --force --sign - "$APP"
    fi
    echo "Built $APP"
    exit 0
fi

# 公证要求开启 Hardened Runtime 并带安全时间戳
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"

# 打包 dmg：内含 FishAi.app 和指向 /Applications 的快捷方式
DMG="build/FishAi-$VERSION.dmg"
STAGING="build/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "FishAi" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGING"
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 公证 dmg（里面的 .app 一并公证），再把公证票据装订到 dmg 和本地的 .app 上
NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)"
if ! grep -q "status: Accepted" <<<"$NOTARY_OUT"; then
    # 公证被拒时打印苹果返回的详细原因
    SUBMISSION_ID="$(sed -n 's/^ *id: //p' <<<"$NOTARY_OUT" | head -n 1)"
    [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "error: notarization failed" >&2
    exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

spctl --assess --type open --context context:primary-signature --verbose "$DMG"
spctl --assess --type execute --verbose "$APP"
echo "Built and notarized $DMG"
