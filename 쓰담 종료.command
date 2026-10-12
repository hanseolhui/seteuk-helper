#!/bin/bash
curl -s -X POST -H "X-Seteuk: 1" -H "Content-Type: application/json" -d '{}' http://127.0.0.1:8765/api/shutdown >/dev/null && echo "쓰담을 종료했습니다." || echo "실행 중이 아닙니다."
sleep 1
