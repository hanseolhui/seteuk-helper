#!/bin/bash
# 세특도우미.app 과 설치용 DMG, 업데이트용 코드 묶음을 dist/ 에 만든다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' app/version.py)
BUILD="$ROOT/build"; DIST="$ROOT/dist"
APP="$BUILD/세특도우미.app"
rm -rf "$BUILD" "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

# 1) 앱 번들
cp macos/launcher.sh "$APP/Contents/MacOS/seteuk"; chmod +x "$APP/Contents/MacOS/seteuk"
rsync -a --exclude '__pycache__' --exclude '*.pyc' app "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>세특도우미</string>
  <key>CFBundleDisplayName</key><string>세특도우미</string>
  <key>CFBundleIdentifier</key><string>kr.seteuk.helper</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>seteuk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>메모 앱의 받아쓰기 메모를 가져오기 위해 필요합니다.</string>
</dict></plist>
PLIST

# 2) 아이콘
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s macos/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) macos/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 3) 임시 서명(ad-hoc) — 애플 개발자 인증서가 있으면 SIGN_ID 환경변수로 지정
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"

# 4) 배포 파일
ditto -c -k --norsrc --keepParent "$APP" "$DIST/SeteukHelper-mac.zip"          # 설치 스크립트용
(cd "$ROOT" && zip -qr "$DIST/seteuk-app.zip" app -x '*/__pycache__/*' '*.pyc')   # 앱 내 업데이트용
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
cp 사용설명서.md "$STAGE/사용설명서.md"
hdiutil create -quiet -volname "세특도우미 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/SeteukHelper.dmg"
echo "완료: $DIST (버전 $VERSION)"; ls -la "$DIST"
