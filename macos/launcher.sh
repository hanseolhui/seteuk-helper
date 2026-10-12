#!/bin/bash
# 세특도우미.app 실행기 — 서버를 띄우고 브라우저를 연다. (창 없이 백그라운드 실행)
URL="http://127.0.0.1:8765"
SUPPORT="$HOME/Library/Application Support/세특도우미"
mkdir -p "$SUPPORT"
LOG="$SUPPORT/server.log"

# 이미 실행 중이면 브라우저만 연다
if curl -s -o /dev/null --max-time 1 "$URL/api/version"; then
  open "$URL"; exit 0
fi

PY=""
for c in /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] || continue
  if [ "$c" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
  if "$c" -c "import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 8) else 1)" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  osascript -e 'display dialog "처음 한 번만 애플의 \"명령어 라인 도구\" 설치가 필요합니다.\n\n확인을 누르면 설치 창이 뜹니다. [설치]를 눌러 끝낸 뒤 세특도우미를 다시 실행하세요." buttons {"확인"} default button 1 with title "세특도우미" with icon note' >/dev/null 2>&1
  xcode-select --install >/dev/null 2>&1
  exit 1
fi

RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
# 앱에 들어 있는 코드와 업데이트로 내려받은 코드 중 가장 높은 버전을 실행
CODE="$("$PY" - "$RES/app" "$SUPPORT/code" <<'PYEOF'
import os, re, sys
def ver(app):
    try:
        m = re.search(r'VERSION\s*=\s*"([^"]+)"', open(os.path.join(app, "version.py"), encoding="utf-8").read())
        return tuple(int(x) for x in re.findall(r"\d+", m.group(1))[:3])
    except Exception:
        return None
best, best_v = sys.argv[1], ver(sys.argv[1]) or (0,)
root = sys.argv[2]
if os.path.isdir(root):
    for d in os.listdir(root):
        app = os.path.join(root, d, "app")
        v = ver(app)
        if v and os.path.exists(os.path.join(app, "server.py")) and v > best_v:
            best, best_v = app, v
print(best)
PYEOF
)"
[ -n "$CODE" ] || CODE="$RES/app"

export SETEUK_APP=1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') 시작: $CODE" >> "$LOG"
exec "$PY" "$CODE/server.py" >> "$LOG" 2>&1
