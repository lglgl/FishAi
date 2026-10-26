#!/bin/bash
# 构建 FishAi.app 到 build/
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FishAi"

APP="build/FishAi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/FishAi"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FishAi</string>
    <key>CFBundleDisplayName</key><string>FishAi</string>
    <key>CFBundleIdentifier</key><string>com.lglgl.FishAi</string>
    <key>CFBundleExecutable</key><string>FishAi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

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
