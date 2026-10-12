# -*- coding: utf-8 -*-
"""맥/윈도우 차이를 한곳에 모은다."""
import os
import subprocess
import sys

IS_MAC = sys.platform == "darwin"
IS_WIN = os.name == "nt"


APP_NAME = "쓰담"
OLD_APP_NAME = "세특도우미"  # 1.3 이전 이름


def _support_root():
    if IS_WIN:
        return os.environ.get("APPDATA") or os.path.expanduser("~\\AppData\\Roaming")
    return os.path.expanduser("~/Library/Application Support")


def support_dir():
    """프로그램 데이터 위치 (코드와 분리 → 업데이트·재설치해도 기록 보존). 예전 이름 폴더는 자동으로 옮긴다."""
    new = os.path.join(_support_root(), APP_NAME)
    _migrate_old_support(os.path.join(_support_root(), OLD_APP_NAME), new)
    return new


def _migrate_old_support(old, new):
    try:
        if not os.path.exists(os.path.join(old, "data", "seteuk.db")):
            return
        if os.path.exists(os.path.join(new, "data", "seteuk.db")):
            return
        os.makedirs(new, exist_ok=True)
        import shutil
        for name in os.listdir(old):
            src, dst = os.path.join(old, name), os.path.join(new, name)
            if not os.path.exists(dst):
                shutil.move(src, dst)
        os.rename(old, old + "_옮겨짐")
        print("데이터를 새 위치로 옮겼습니다:", new)
    except OSError as e:
        print("예전 데이터 옮기기 실패:", e)


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
