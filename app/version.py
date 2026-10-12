# -*- coding: utf-8 -*-
# 릴리스할 때 tools/release.sh 가 VERSION 을 올립니다.
VERSION = "1.3.0"

# 업데이트를 받아올 GitHub 저장소 ("소유자/저장소"). 비우면 업데이트 확인을 하지 않습니다.
# 저장소는 공개(public)여야 선생님 맥에서 토큰 없이 받아올 수 있습니다. (코드만 올라가고 학생 데이터는 올라가지 않음)
UPDATE_REPO = "hanseolhui/seteuk-helper"

# 릴리스에 첨부하는 코드 묶음 파일 이름
UPDATE_ASSET = "seteuk-app.zip"

# 앱 셸(창·메뉴·Whisper 실행 파일이 든 .app) 버전. 셸이 이보다 낮으면 화면에서 '앱 업데이트'를 안내한다.
SHELL_REQUIRED = 2
APP_ASSET = "SeteukHelper-mac.zip"
WHISPER_ASSET = "whisper-cli-arm64.zip"
