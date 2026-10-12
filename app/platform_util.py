# -*- coding: utf-8 -*-
"""맥/윈도우 차이를 한곳에 모은다."""
import os
import subprocess
import sys

IS_MAC = sys.platform == "darwin"
IS_WIN = os.name == "nt"


def support_dir():
    """프로그램 데이터 위치 (코드와 분리 → 업데이트·재설치해도 기록 보존)"""
    if IS_WIN:
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~\\AppData\\Roaming"), "세특도우미")
    return os.path.expanduser("~/Library/Application Support/세특도우미")


def downloads_dir():
    d = os.path.join(os.path.expanduser("~"), "Downloads")
    os.makedirs(d, exist_ok=True)
    return d


def icloud_drive_dir():
    """iCloud Drive 루트 (맥: Mobile Documents, 윈도우: iCloud for Windows의 iCloudDrive)"""
    if IS_WIN:
        return os.path.join(os.path.expanduser("~"), "iCloudDrive")
    return os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs")


def icloud_container_dir(container):
    """앱 전용 iCloud 폴더 (예: iCloud~kr~seteuk~recorder). 아이폰 녹음 앱이 여기에 저장한다."""
    if IS_WIN:
        return os.path.join(os.path.expanduser("~"), "iCloudDrive", container)
    return os.path.expanduser("~/Library/Mobile Documents/%s/Documents" % container)


def open_path(path, reveal=False):
    """파일/폴더를 탐색기(Finder)에서 연다. reveal=True면 파일을 선택한 상태로."""
    try:
        if IS_MAC:
            subprocess.Popen(["open", "-R", path] if reveal else ["open", path])
        elif IS_WIN:
            if reveal:
                subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
            else:
                os.startfile(path)  # noqa
        else:
            subprocess.Popen(["xdg-open", os.path.dirname(path) if reveal else path])
    except Exception as e:  # noqa
        print("열기 실패:", e)


def open_url(url):
    import webbrowser
    webbrowser.open(url)
