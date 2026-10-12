# -*- coding: utf-8 -*-
"""GitHub 릴리스로 프로그램 업데이트.

- 코드(app 폴더)만 ~/Library/Application Support/쓰담/code/<버전>/ 에 내려받는다.
- 학생 데이터(data 폴더)는 건드리지 않는다.
- 앱 실행기는 '앱에 들어 있는 코드'와 '내려받은 코드' 중 가장 높은 버전을 실행한다.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import subprocess
import zipfile

import db
import gemini
import version

CODE_DIR = os.path.join(db.SUPPORT_DIR, "code")
_cache = {"at": 0, "data": None}


def vtuple(v):
    nums = re.findall(r"\d+", str(v or ""))
    return tuple(int(x) for x in nums[:3]) + (0,) * (3 - len(nums[:3]))


def _get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "sseudam/" + version.VERSION,
                                               "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=timeout, context=gemini._CTX)


def check(force=False):
    if not version.UPDATE_REPO:
        return {"enabled": False, "current": version.VERSION}
    if not force and _cache["data"] and time.time() - _cache["at"] < 3600:
        return _cache["data"]
    try:
        resp = _get("https://api.github.com/repos/%s/releases/latest" % version.UPDATE_REPO)
        rel = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            out = {"enabled": True, "current": version.VERSION, "available": False, "message": "아직 배포된 버전이 없습니다."}
            return out
        return {"enabled": True, "current": version.VERSION, "available": False, "error": "업데이트 확인 실패 (HTTP %s)" % e.code}
    except Exception as e:  # noqa
        return {"enabled": True, "current": version.VERSION, "available": False, "error": "업데이트 확인 실패: %s" % e}
    latest = (rel.get("tag_name") or "").lstrip("vV")
    asset = next((a for a in rel.get("assets", []) if a.get("name") == version.UPDATE_ASSET), None)
    out = {
        "enabled": True, "current": version.VERSION, "latest": latest,
        "available": bool(asset) and vtuple(latest) > vtuple(version.VERSION),
        "notes": rel.get("body") or "", "name": rel.get("name") or latest,
        "published_at": rel.get("published_at"),
        "url": asset.get("browser_download_url") if asset else None,
        "digest": (asset or {}).get("digest") or "",
    }
    _cache.update(at=time.time(), data=out)
    return out


def apply():
    info = check(force=True)
    if not info.get("available"):
        raise ValueError(info.get("error") or "설치할 새 버전이 없습니다.")
    latest = info["latest"]
    os.makedirs(CODE_DIR, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="seteuk-update-", dir=CODE_DIR)
    try:
        zpath = os.path.join(tmpdir, "update.zip")
        with _get(info["url"], timeout=120) as resp, open(zpath, "wb") as f:
            shutil.copyfileobj(resp, f)
        if info["digest"].startswith("sha256:"):
            h = hashlib.sha256()
            with open(zpath, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            if h.hexdigest() != info["digest"].split(":", 1)[1]:
                raise ValueError("내려받은 파일이 손상되었습니다. 다시 시도하세요.")
        extract = os.path.join(tmpdir, "x")
        with zipfile.ZipFile(zpath) as z:
            for m in z.namelist():
                if m.startswith("/") or ".." in m.split("/"):
                    raise ValueError("잘못된 업데이트 파일입니다.")
            z.extractall(extract)
        ver_file = os.path.join(extract, "app", "version.py")
        if not os.path.exists(os.path.join(extract, "app", "server.py")) or not os.path.exists(ver_file):
            raise ValueError("업데이트 파일 구성이 올바르지 않습니다.")
        with open(ver_file, encoding="utf-8") as f:
            m = re.search(r'VERSION\s*=\s*"([^"]+)"', f.read())
        if not m or vtuple(m.group(1)) != vtuple(latest):
            raise ValueError("업데이트 파일의 버전 정보가 맞지 않습니다.")
        target = os.path.join(CODE_DIR, latest)
        if os.path.exists(target):
            shutil.rmtree(target)
        os.rename(extract, target)
        _cleanup_old(keep=latest)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    restart(os.path.join(CODE_DIR, latest, "app", "server.py"))
    return {"ok": True, "version": latest}


def _cleanup_old(keep):
    """최근 2개 버전만 남긴다 (문제 생기면 이전 버전으로 돌아갈 수 있게)."""
    vers = sorted((d for d in os.listdir(CODE_DIR) if re.match(r"^\d+\.\d+", d)), key=vtuple)
    for d in vers[:-2]:
        if d != keep:
            shutil.rmtree(os.path.join(CODE_DIR, d), ignore_errors=True)


def restart(server_path):
    import platform_util

    def go():
        time.sleep(1.0)
        os.environ["SETEUK_NO_BROWSER"] = "1"
        if platform_util.IS_WIN:  # 윈도우에는 진짜 execv가 없음 → 새 프로세스를 띄우고 종료
            subprocess.Popen([sys.executable, server_path], env=dict(os.environ), creationflags=0x00000008 | 0x00000200)
            os._exit(0)
        os.execv(sys.executable, [sys.executable, server_path])
    threading.Thread(target=go, daemon=True).start()


# ───────────────────────── 앱 셸(.app) 업데이트 ─────────────────────────

def shell_version():
    try:
        return int(os.environ.get("SETEUK_SHELL") or 1)
    except ValueError:
        return 1


def shell_outdated():
    """예전 맥 앱(1.1, 창 없는 실행기)에서 돌 때만 '새 앱으로 바꾸기'를 안내. 개발 실행·윈도우는 해당 없음."""
    import platform_util
    return bool(platform_util.IS_MAC and os.environ.get("SETEUK_APP")) and shell_version() < version.SHELL_REQUIRED


APP_BUNDLE = "쓰담.app"
OLD_BUNDLES = ["세특도우미.app"]


def _installed_app_path():
    """지금 설치된 앱 위치 (예전 이름 포함)."""
    p = os.environ.get("SETEUK_APP_PATH")
    if p and p.endswith(".app"):
        return p
    here = os.path.abspath(os.path.join(db.APP_DIR, "..", "..", ".."))
    if here.endswith(".app"):
        return here
    for folder in ("/Applications", os.path.expanduser("~/Applications")):
        for name in [APP_BUNDLE] + OLD_BUNDLES:
            if os.path.isdir(os.path.join(folder, name)):
                return os.path.join(folder, name)
    return os.path.join("/Applications", APP_BUNDLE)


def _asset_url(name):
    resp = _get("https://api.github.com/repos/%s/releases/latest" % version.UPDATE_REPO)
    rel = json.loads(resp.read().decode("utf-8"))
    a = next((x for x in rel.get("assets", []) if x.get("name") == name), None)
    if not a:
        raise ValueError("최신 릴리스에 %s 파일이 없습니다." % name)
    return a["browser_download_url"], a.get("digest") or ""


def _download(url, dest, digest=""):
    with _get(url, timeout=300) as resp, open(dest, "wb") as f:
        shutil.copyfileobj(resp, f)
    if digest.startswith("sha256:"):
        h = hashlib.sha256()
        with open(dest, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != digest.split(":", 1)[1]:
            raise ValueError("내려받은 파일이 손상되었습니다. 다시 시도하세요.")


def install_app():
    """최신 쓰담.app 을 받아 설치 위치에 교체하고, 새 앱을 실행한 뒤 지금 서버를 끝낸다."""
    url, digest = _asset_url(version.APP_ASSET)
    current = _installed_app_path()
    parent = os.path.dirname(current)
    if not os.access(parent, os.W_OK):
        parent = os.path.expanduser("~/Applications")
        os.makedirs(parent, exist_ok=True)
    target = os.path.join(parent, APP_BUNDLE)
    tmp = tempfile.mkdtemp(prefix="seteuk-app-")
    zpath = os.path.join(tmp, "app.zip")
    _download(url, zpath, digest)
    r = subprocess.run(["ditto", "-x", "-k", zpath, tmp], capture_output=True)
    apps = [d for d in os.listdir(tmp) if d.endswith(".app")]
    new_app = os.path.join(tmp, apps[0]) if apps else ""
    if r.returncode != 0 or not new_app:
        raise ValueError("앱 파일을 풀지 못했습니다.")
    old = target + ".old"
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(target):
        os.rename(target, old)
    try:
        shutil.move(new_app, target)
    except Exception:
        if os.path.exists(old):
            os.rename(old, target)
        raise
    shutil.rmtree(old, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)
    # 예전 이름(세특도우미.app)은 정리
    for name in OLD_BUNDLES:
        legacy = os.path.join(parent, name)
        if os.path.isdir(legacy) and legacy != target:
            shutil.rmtree(legacy, ignore_errors=True)
    # 지금 서버가 내려간 뒤 새 앱이 서버를 새로 띄우도록 잠시 뒤 실행
    subprocess.Popen(["/bin/bash", "-c", "sleep 2; open %s" % shlex_quote(target)], start_new_session=True)
    threading.Thread(target=lambda: (time.sleep(0.8), os._exit(0)), daemon=True).start()
    return {"ok": True, "path": target}


def shlex_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def fetch_whisper_binary(dest_dir):
    """앱 안에 Whisper 실행 파일이 없을 때(예전 앱) 릴리스에서 받아온다."""
    url, digest = _asset_url(version.WHISPER_ASSET)
    os.makedirs(dest_dir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="seteuk-wbin-")
    try:
        zpath = os.path.join(tmp, "w.zip")
        _download(url, zpath, digest)
        with zipfile.ZipFile(zpath) as z:
            data = z.read("whisper-cli")
        out = os.path.join(dest_dir, "whisper-cli")
        with open(out, "wb") as f:
            f.write(data)
        os.chmod(out, 0o755)
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
