#!/bin/bash
# 윈도우 설치 프로그램(dist/Sseudam-Setup.exe) 만들기 — 맥에서 실행
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' app/version.py)
PYVER="${PYVER:-3.12.10}"
CACHE="$HOME/.cache/sseudam-build"; mkdir -p "$CACHE"
W="$ROOT/build/win"; rm -rf "$W"; mkdir -p "$W/python" "$W/bin/whisper" "$ROOT/dist"

# 1) 공식 임베디드 파이썬 (설치 필요 없음)
PYZIP="$CACHE/python-$PYVER-embed-amd64.zip"
[ -f "$PYZIP" ] || curl -fL -o "$PYZIP" "https://www.python.org/ftp/python/$PYVER/python-$PYVER-embed-amd64.zip"
unzip -q "$PYZIP" -d "$W/python"

# 2) whisper.cpp 공식 윈도우 실행 파일 (CPU)
# 실행 파일은 태그 릴리스가 아니라 빌드 릴리스(bNNNN)에 붙어 있음 → 최근 릴리스에서 찾기. OpenBLAS판이 CPU에서 더 빠름
WZIP="$CACHE/whisper-blas-bin-x64.zip"
if [ ! -f "$WZIP" ]; then
  URL=$(curl -fsSL 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=10' | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    for a in r['assets']:
        if a['name'] == 'whisper-blas-bin-x64.zip':
            print(a['browser_download_url']); sys.exit()
")
  echo "whisper: $URL"
  curl -fL -o "$WZIP" "$URL"
fi
TMPW=$(mktemp -d); unzip -q "$WZIP" -d "$TMPW"
find "$TMPW" -type f \( -name "whisper-cli.exe" -o -name "*.dll" \) -exec cp {} "$W/bin/whisper/" \;
rm -f "$W/bin/whisper/SDL2.dll" "$W/bin/whisper/llama.dll"   # whisper-cli에는 필요 없음
rm -rf "$TMPW"
[ -f "$W/bin/whisper/whisper-cli.exe" ] || { echo "whisper-cli.exe 없음"; exit 1; }

# 3) 프로그램 코드·실행기·아이콘
rsync -a --exclude '__pycache__' --exclude '*.pyc' app "$W/"
cp windows/launcher.pyw windows/stop.py "$W/"
python3 windows/make_ico.py macos/icon-1024.png "$W/sseudam.ico"
cp 사용설명서.md "$W/사용설명서.md"

# 4) 설치 프로그램
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 makensis -INPUTCHARSET UTF8 -V2 -DVERSION="$VERSION" -DSRC="$W" windows/installer.nsi
ls -la "$ROOT/dist/Sseudam-Setup.exe"
