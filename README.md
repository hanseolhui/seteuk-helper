# 세특도우미 (seteuk-helper)

수업 중 교사가 말로 남긴 학생 평가·상담 기록을 학생별로 자동 분류해 쌓고, 학기말 **세특(세부능력 및 특기사항) 초안**을 뽑아 주는 macOS 앱.

- 아이폰 **음성메모** 자동 가져오기 (iCloud 동기화) · **메모 앱 받아쓰기** 가져오기 · 단축어/폴더
- Gemini(사용자 본인 키) 전사·학생별 분리·초안 / 키 없는 **수동 모드** / AI 없는 이름 기준 분리
- 시간표로 학급 자동 지정, 대시보드, NEIS 바이트 계산, 구글시트 내보내기
- 표준 라이브러리만 쓰는 Python 3.8+ 로컬 서버 + 바닐라 JS UI (외부 의존성 0)
- 학생 데이터는 `~/Library/Application Support/세특도우미/data`에만 저장 — 이 저장소에는 코드만 있음

사용자 안내: [사용설명서.md](사용설명서.md) · 구조: [ARCHITECTURE.md](ARCHITECTURE.md)

## 설치 (사용자)
```bash
curl -fsSL https://raw.githubusercontent.com/hanseolhui/seteuk-helper/main/install.sh | bash
```
또는 [Releases](https://github.com/hanseolhui/seteuk-helper/releases/latest)의 `SeteukHelper.dmg`.

## 개발
```bash
python3 app/server.py          # http://127.0.0.1:8765 (데이터: ~/Library/Application Support/세특도우미/data)
SETEUK_DATA=/tmp/seteuk-test python3 app/server.py   # 테스트용 별도 데이터
```

## 배포 (업데이트 내보내기)
```bash
git commit -am "변경 내용"
tools/release.sh 1.2.0 "바뀐 점 설명"
```
`app/version.py` 버전을 올리고, `macos/build_app.sh`로 `dist/`에 3개 파일을 만든 뒤 태그·푸시하고 GitHub 릴리스를 생성합니다.

| 파일 | 용도 |
|---|---|
| `SeteukHelper.dmg` | 처음 설치용 (드래그 설치) |
| `SeteukHelper-mac.zip` | `install.sh` 한 줄 설치용 |
| `seteuk-app.zip` | **앱 내 자동 업데이트용** (app/ 코드만) |

사용자 앱은 실행 시 `releases/latest`를 확인 → 배너 표시 → 버튼을 누르면 `seteuk-app.zip`을 받아 SHA-256 검증 후
`~/Library/Application Support/세특도우미/code/<버전>/`에 풀고 재시작합니다. 앱 번들은 수정하지 않으므로 서명이 깨지지 않으며,
실행기는 번들 코드와 내려받은 코드 중 높은 버전을 실행합니다. **저장소는 public이어야** 사용자가 토큰 없이 업데이트를 받습니다.

### 코드 서명 (선택)
기본은 ad-hoc 서명이라 DMG 첫 실행 시 "그래도 열기"가 필요합니다(`install.sh` 경로는 불필요).
Apple Developer ID가 있으면 `SIGN_ID="Developer ID Application: …" macos/build_app.sh` 후 공증(notarytool)하면 경고 없이 열립니다.
