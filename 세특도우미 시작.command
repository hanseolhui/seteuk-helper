#!/bin/bash
# 세특도우미 실행 — 더블클릭하세요. 이 창을 닫으면 프로그램이 종료됩니다.
cd "$(dirname "$0")" || exit 1
URL="http://127.0.0.1:8765"

if curl -s -o /dev/null --max-time 1 "$URL/api/jobs"; then
  echo "이미 실행 중입니다. 브라우저를 엽니다."
  open "$URL"
  exit 0
fi

PY=""
for c in python3 /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
  if command -v "$c" >/dev/null 2>&1; then
    if [ "$c" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
    if "$c" -c "import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >/dev/null 2>&1; then PY="$c"; break; fi
  fi
done

if [ -z "$PY" ]; then
  echo "────────────────────────────────────────────"
  echo " 처음 한 번만: 애플 '명령어 라인 도구' 설치가 필요합니다."
  echo " 곧 뜨는 창에서 [설치]를 누르고, 끝나면 이 파일을 다시 더블클릭하세요."
  echo "────────────────────────────────────────────"
  xcode-select --install 2>/dev/null
  read -n 1 -s -r -p "아무 키나 누르면 창을 닫습니다…"
  exit 1
fi

mkdir -p data
echo "세특도우미를 시작합니다… (이 창은 열어 두세요. 닫으면 종료됩니다)"
"$PY" app/server.py 2>&1 | tee -a data/server.log
