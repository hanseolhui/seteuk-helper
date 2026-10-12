# -*- coding: utf-8 -*-
"""Gemini REST API 클라이언트 (표준 라이브러리 urllib만 사용)."""
import json
import os
import re
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

API_ROOT = "https://generativelanguage.googleapis.com"

MIME_BY_EXT = {
    ".wav": "audio/wav", ".mp3": "audio/mp3", ".aac": "audio/aac", ".aiff": "audio/aiff",
    ".aif": "audio/aiff", ".ogg": "audio/ogg", ".flac": "audio/flac",
    ".m4a": "audio/mp4", ".mp4": "audio/mp4",
}
NEEDS_CONVERT = {".m4a", ".mp4", ".caf", ".qta", ".mov", ".3gp", ".amr"}


class GeminiError(Exception):
    pass


def _ssl_context():
    ctx = ssl.create_default_context()
    try:
        ctx.load_verify_locations("/etc/ssl/cert.pem")  # macOS 시스템 인증서 (python.org 설치본 대비)
    except Exception:
        pass
    return ctx


_CTX = _ssl_context()


def _request(url, key, data=None, headers=None, method=None, timeout=600, raw=False):
    hdrs = {"x-goog-api-key": key}
    if headers:
        hdrs.update(headers)
    body = data
    if isinstance(data, (dict, list)):
        body = json.dumps(data).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout, context=_CTX)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise _http_error(e.code, detail)
    except urllib.error.URLError as e:
        raise GeminiError("인터넷 연결을 확인하세요 (%s)" % e.reason)
    if raw:
        return resp
    text = resp.read().decode("utf-8")
    return json.loads(text) if text else {}


def _http_error(code, detail):
    msg = detail
    retry = None
    try:
        j = json.loads(detail)
        msg = j.get("error", {}).get("message", detail)
        for d in j.get("error", {}).get("details", []):
            if "retryDelay" in d:
                retry = float(str(d["retryDelay"]).rstrip("s") or 0)
    except Exception:
        pass
    err = GeminiError(_friendly(code, msg))
    err.code = code
    err.retry = retry
    return err


def _friendly(code, msg):
    if code in (400, 403) and ("API key" in msg or "API_KEY" in msg or "permission" in msg.lower()):
        return "API 키가 올바르지 않거나 권한이 없습니다. 설정에서 키를 확인하세요. (%s)" % msg[:200]
    if code == 429:
        return "요청 한도를 초과했습니다(무료 등급 분당/일일 제한). 잠시 후 다시 시도하세요. (%s)" % msg[:200]
    if code == 404:
        return "모델을 찾을 수 없습니다. 설정에서 모델을 다시 선택하세요. (%s)" % msg[:200]
    return "Gemini 오류 %s: %s" % (code, msg[:300])


def list_models(key):
    out = []
    url = API_ROOT + "/v1beta/models?pageSize=200"
    data = _request(url, key, timeout=30)
    for m in data.get("models", []):
        if "generateContent" in m.get("supportedGenerationMethods", []):
            name = m["name"].split("/", 1)[-1]
            out.append({"name": name, "display": m.get("displayName", name)})
    return out


def pick_fallback_model(key):
    """지정 모델이 사라졌을 때 쓸 만한 flash 모델 고르기."""
    names = [m["name"] for m in list_models(key)]
    def score(n):
        s = 0
        if "flash" in n: s += 100
        if "lite" in n: s -= 30
        if any(x in n for x in ("preview", "exp", "tts", "image", "live", "audio", "embedding")): s -= 50
        nums = re.findall(r"(\d+(?:\.\d+)?)", n)
        if nums:
            try: s += float(nums[0]) * 10
            except ValueError: pass
        return s
    names.sort(key=score, reverse=True)
    return names[0] if names else None


def generate(key, model, prompt, system=None, json_mode=False, file_uri=None, file_mime=None,
             temperature=0.4, on_model_change=None):
    parts = []
    if file_uri:
        parts.append({"file_data": {"mime_type": file_mime, "file_uri": file_uri}})
    parts.append({"text": prompt})
    body = {"contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": temperature}}
    if system:
        body["systemInstruction"] = {"parts": [{"text": system}]}
    if json_mode:
        body["generationConfig"]["responseMimeType"] = "application/json"

    tried_fallback = False
    attempt = 0
    while True:
        url = "%s/v1beta/models/%s:generateContent" % (API_ROOT, model)
        try:
            data = _request(url, key, data=body, timeout=900)
            break
        except GeminiError as e:
            code = getattr(e, "code", None)
            if code == 404 and not tried_fallback:
                tried_fallback = True
                new_model = pick_fallback_model(key)
                if new_model and new_model != model:
                    model = new_model
                    if on_model_change:
                        on_model_change(new_model)
                    continue
            if code in (429, 500, 502, 503, 504) and attempt < 4:
                attempt += 1
                wait = getattr(e, "retry", None) or (15 * attempt)
                time.sleep(min(wait + 1, 90))
                continue
            raise

    cands = data.get("candidates") or []
    if not cands:
        fb = data.get("promptFeedback", {})
        raise GeminiError("응답이 비어 있습니다. (%s)" % (fb.get("blockReason") or "원인 미상"))
    c = cands[0]
    text = "".join(p.get("text", "") for p in c.get("content", {}).get("parts", []) if not p.get("thought"))
    if not text.strip():
        raise GeminiError("응답이 비어 있습니다. (finishReason=%s)" % c.get("finishReason"))
    if c.get("finishReason") == "MAX_TOKENS":
        text += "\n\n[주의: 응답 길이 한도에 도달해 잘렸을 수 있습니다]"
    return text


def prepare_audio(path):
    """Gemini가 공식 지원하는 형식으로 변환. (변환경로, mime, 임시파일여부) 반환."""
    ext = os.path.splitext(path)[1].lower()
    if ext in NEEDS_CONVERT and shutil.which("afconvert"):
        tmpdir = tempfile.mkdtemp(prefix="seteuk-")
        out = os.path.join(tmpdir, "audio.aac")
        r = subprocess.run(["afconvert", "-f", "adts", "-d", "aac", "-c", "1", path, out],
                           capture_output=True)
        if r.returncode == 0 and os.path.getsize(out) > 0:
            return out, "audio/aac", True
        out = os.path.join(tmpdir, "audio.wav")
        r = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, out],
                           capture_output=True)
        if r.returncode == 0:
            return out, "audio/wav", True
    return path, MIME_BY_EXT.get(ext, "audio/mp4"), False


def upload_file(key, path, mime, display_name="recording"):
    size = os.path.getsize(path)
    start = urllib.request.Request(
        API_ROOT + "/upload/v1beta/files",
        data=json.dumps({"file": {"display_name": display_name}}).encode("utf-8"),
        headers={
            "x-goog-api-key": key,
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(size),
            "X-Goog-Upload-Header-Content-Type": mime,
            "Content-Type": "application/json",
        }, method="POST")
    try:
        resp = urllib.request.urlopen(start, timeout=60, context=_CTX)
    except urllib.error.HTTPError as e:
        raise _http_error(e.code, e.read().decode("utf-8", "replace"))
    except urllib.error.URLError as e:
        raise GeminiError("인터넷 연결을 확인하세요 (%s)" % e.reason)
    upload_url = resp.headers.get("x-goog-upload-url") or resp.headers.get("X-Goog-Upload-URL")
    if not upload_url:
        raise GeminiError("파일 업로드 주소를 받지 못했습니다.")
    with open(path, "rb") as f:
        payload = f.read()
    info = _request(upload_url, key, data=payload, method="POST", timeout=1800, headers={
        "Content-Length": str(size),
        "X-Goog-Upload-Offset": "0",
        "X-Goog-Upload-Command": "upload, finalize",
    })
    finfo = info.get("file", info)
    name = finfo.get("name")
    # 처리 완료(ACTIVE)까지 대기
    for _ in range(120):
        if finfo.get("state") in (None, "ACTIVE"):
            break
        if finfo.get("state") == "FAILED":
            raise GeminiError("Gemini가 오디오 파일을 처리하지 못했습니다.")
        time.sleep(3)
        finfo = _request("%s/v1beta/%s" % (API_ROOT, name), key, timeout=30)
    return finfo.get("uri"), finfo.get("mimeType") or mime, name


def delete_file(key, name):
    try:
        _request("%s/v1beta/%s" % (API_ROOT, name), key, method="DELETE", timeout=30)
    except Exception:
        pass


def extract_json(text):
    """응답에서 JSON 부분만 추출 (```json 블록, 앞뒤 설명문 허용)."""
    t = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
    if m:
        t = m.group(1).strip()
    try:
        return json.loads(t)
    except ValueError:
        pass
    for open_ch, close_ch in (("{", "}"), ("[", "]")):
        s, e = t.find(open_ch), t.rfind(close_ch)
        if s != -1 and e > s:
            try:
                return json.loads(t[s:e + 1])
            except ValueError:
                continue
    raise GeminiError("AI 응답에서 JSON을 읽지 못했습니다. 응답 전체를 그대로 붙여넣었는지 확인하세요.")
