#!/bin/bash
# 세특도우미 설치/재설치 — 터미널에 아래 한 줄을 붙여넣으면 됩니다.
#   curl -fsSL https://raw.githubusercontent.com/hanseolhui/seteuk-helper/main/install.sh | bash
set -e
REPO="hanseolhui/seteuk-helper"
URL="https://github.com/$REPO/releases/latest/download/SeteukHelper-mac.zip"
DEST="/Applications"; [ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
echo "세특도우미 최신 버전을 내려받는 중…"
curl -fL --progress-bar "$URL" -o "$TMP/app.zip"
# 실행 중이면 종료 (학생 기록은 별도 폴더에 있어 안전)
curl -s -X POST -H "X-Seteuk: 1" -H "Content-Type: application/json" -d '{}' http://127.0.0.1:8765/api/shutdown >/dev/null 2>&1 && sleep 1 || true
rm -rf "$DEST/세특도우미.app"
ditto -x -k "$TMP/app.zip" "$DEST"
rm -rf "$TMP"
echo "설치 완료: $DEST/세특도우미.app"
open "$DEST/세특도우미.app"
