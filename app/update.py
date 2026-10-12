# -*- coding: utf-8 -*-
"""GitHub 릴리스로 프로그램 업데이트.

- 코드(app 폴더)만 ~/Library/Application Support/세특도우미/code/<버전>/ 에 내려받는다.
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
    req = urllib.request.Request(url, headers={"User-Agent": "seteuk-helper/" + version.VERSION,
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
    def go():
        time.sleep(1.0)
        os.environ["SETEUK_NO_BROWSER"] = "1"
        os.execv(sys.executable, [sys.executable, server_path])
    threading.Thread(target=go, daemon=True).start()
