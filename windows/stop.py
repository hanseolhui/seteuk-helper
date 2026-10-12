# 설치·제거 전에 실행 중인 쓰담 서버를 끈다.
import urllib.request
try:
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8765/api/shutdown", data=b"{}",
                           headers={"X-Seteuk": "1", "Content-Type": "application/json"}), timeout=2)
except Exception:
    pass
