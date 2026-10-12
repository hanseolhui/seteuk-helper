#!/bin/bash
# 쓰담 설치·업데이트 — 터미널에 아래 한 줄을 붙여넣으면 됩니다. (애플 공증을 받은 최신 릴리스를 응용 프로그램 폴더에 설치)
#   curl -fsSL https://raw.githubusercontent.com/hanseolhui/sseudam/main/install.sh | bash
# 학생 기록은 ~/Library/Application Support/쓰담 에 따로 있어서 다시 설치해도 그대로예요.
set -euo pipefail

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

echo "▶ 쓰담 설치"
REPO="hanseolhui/sseudam"
if [ -n "${SSEUDAM_DEST:-}" ]; then DEST="$SSEUDAM_DEST"
elif [ -w /Applications ]; then DEST="/Applications"
else DEST="$HOME/Applications"; fi
mkdir -p "$DEST"

TMP=$(mktemp -d -t sseudam)
trap 'rm -rf "$TMP"' EXIT

TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
     | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
URL="https://github.com/$REPO/releases/latest/download/Sseudam-mac.zip"
[ -n "$TAG" ] && URL="https://github.com/$REPO/releases/download/$TAG/Sseudam-mac.zip"
if curl -fL --progress-bar "$URL" -o "$TMP/app.zip" \
   && mkdir -p "$TMP/out" && ditto -x -k "$TMP/app.zip" "$TMP/out" \
   && spctl --assess --type execute "$TMP/out/쓰담.app" 2>/dev/null; then
  ok "애플 공증을 받은 최신 버전 다운로드 (${TAG:-latest})"
else
  warn "내려받지 못했어요. 인터넷 연결을 확인하거나 https://hanseolhui.github.io/sseudam/ 에서 받아 주세요."
  exit 1
fi

# 실행 중이면 종료 (기록은 안전)
curl -s -m 3 -X POST -H "X-Seteuk: 1" -H "Content-Type: application/json" -d '{}' http://127.0.0.1:8765/api/shutdown >/dev/null 2>&1 || true
pkill -x Sseudam 2>/dev/null || true
sleep 1

rm -rf "$DEST/쓰담.app"
ditto "$TMP/out/쓰담.app" "$DEST/쓰담.app"
xattr -dr com.apple.quarantine "$DEST/쓰담.app" 2>/dev/null || true
ok "설치 완료: $DEST/쓰담.app"
# 예전 이름(세특도우미)·예전 위치 사본은 휴지통으로
for old in "$DEST/세특도우미.app" "$HOME/Applications/쓰담.app" "$HOME/Applications/세특도우미.app"; do
  [ "$old" != "$DEST/쓰담.app" ] && [ -d "$old" ] && mv "$old" "$HOME/.Trash/" 2>/dev/null && ok "예전 앱을 휴지통으로: $(basename "$old")"
done

if [ "${SSEUDAM_NO_OPEN:-0}" != "1" ]; then
  open "$DEST/쓰담.app"
  ok "실행 완료"
fi
echo
echo "  아이폰 쓰담 앱으로 녹음하면 iCloud로 자동으로 들어와요 (같은 Apple ID)."
echo "  아이폰 기본 '음성메모' 앱도 가져오려면: 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한 > ＋ > 쓰담"
