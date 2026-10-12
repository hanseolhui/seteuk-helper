# -*- coding: utf-8 -*-
"""AI 작업 큐와 결과 적용 로직.

모든 작업은 build_prompt(op, params) → (Gemini 호출 | 수동 붙여넣기) → apply(op, params, text)
의 3단계로 이루어진다. 수동 모드는 2단계를 사용자가 웹 채팅으로 대신한다.
"""
import datetime
import json
import os
import re
import threading
import traceback

import db
import gemini
import prompts

_wake = threading.Event()
_lock = threading.Lock()


# ───────────────────────── 공용 조회 ─────────────────────────

def _class_info(conn, class_id):
    if not class_id:
        return {"label": "", "subject": ""}
    c = db.row(conn, "SELECT * FROM classes WHERE id=?", (class_id,))
    if not c:
        return {"label": "", "subject": ""}
    c["label"] = db.class_label(c)
    return c


def _students(conn, class_id):
    if not class_id:
        return []
    return db.rows(conn, "SELECT * FROM students WHERE class_id=? ORDER BY number, name", (class_id,))


def _recording(conn, rid):
    r = db.row(conn, "SELECT * FROM recordings WHERE id=?", (rid,))
    if not r:
        raise ValueError("녹음을 찾을 수 없습니다.")
    return r


def _set_rec(conn, rid, **kw):
    sets = ", ".join("%s=?" % k for k in kw)
    conn.execute("UPDATE recordings SET %s WHERE id=?" % sets, list(kw.values()) + [rid])
    conn.commit()


# ───────────────────────── 프롬프트 생성 ─────────────────────────

def build_prompt(op, params):
    conn = db.connect()
    try:
        settings = db.get_settings(conn)
        if op == "transcribe":
            r = _recording(conn, params["recording_id"])
            c = _class_info(conn, r["class_id"])
            return {"prompt": prompts.transcribe(r["kind"], c["label"], _students(conn, r["class_id"])),
                    "audio_path": r["audio_path"]}
        if op == "segment":
            r = _recording(conn, params["recording_id"])
            if not (r.get("transcript") or "").strip():
                raise ValueError("전사문이 없습니다. 먼저 전사하거나 붙여넣으세요.")
            c = _class_info(conn, r["class_id"])
            return {"prompt": prompts.segment(r["kind"], c["label"], _students(conn, r["class_id"]),
                                              r["transcript"], (r["recorded_at"] or "")[:10]),
                    "system": prompts.SEGMENT_SYSTEM, "json": True}
        if op == "draft":
            s = db.row(conn, "SELECT * FROM students WHERE id=?", (params["student_id"],))
            if not s:
                raise ValueError("학생을 찾을 수 없습니다.")
            notes = db.rows(conn, "SELECT * FROM notes WHERE student_id=? AND use_in_draft=1 "
                                  "ORDER BY date, id", (s["id"],))
            if not notes:
                raise ValueError("%s 학생의 관찰기록이 없습니다." % s["name"])
            c = _class_info(conn, s["class_id"])
            return {"prompt": prompts.draft(s, c, notes, settings, params.get("extra", "")),
                    "system": prompts.DRAFT_SYSTEM}
        if op == "shorten":
            text = params.get("text", "")
            limit = int(settings.get("byte_limit") or 1500)
            return {"prompt": prompts.shorten(text, limit, db.neis_bytes(text)),
                    "system": prompts.DRAFT_SYSTEM}
        raise ValueError("알 수 없는 작업: %s" % op)
    finally:
        conn.close()


# ───────────────────────── 결과 적용 ─────────────────────────

def apply(op, params, text):
    if op == "transcribe":
        return apply_transcript(params["recording_id"], text, params.get("chain"))
    if op == "segment":
        return apply_segment(params["recording_id"], text)
    if op in ("draft", "shorten"):
        return apply_draft(params["student_id"], text)
    raise ValueError("알 수 없는 작업: %s" % op)


def apply_transcript(rid, text, chain=False):
    text = (text or "").strip()
    if not text:
        raise ValueError("전사문이 비어 있습니다.")
    conn = db.connect()
    _set_rec(conn, rid, transcript=text, status="전사완료", error="")
    conn.close()
    if chain:
        segment_after_transcript(rid)
    return {"ok": True}


def apply_segment(rid, text):
    data = gemini.extract_json(text) if isinstance(text, str) else text
    if isinstance(data, list):
        data = {"items": data}
    conn = db.connect()
    try:
        r = _recording(conn, rid)
        class_id = r["class_id"]
        if not class_id and data.get("class_hint"):
            class_id = guess_class(conn, data["class_hint"])
            if class_id:
                conn.execute("UPDATE recordings SET class_id=? WHERE id=?", (class_id, rid))
        students = _students(conn, class_id)
        date = (r["recorded_at"] or "")[:10] or datetime.date.today().isoformat()
        # 재분리 시 이전 결과 교체
        conn.execute("DELETE FROM notes WHERE recording_id=?", (rid,))
        conn.execute("DELETE FROM unmatched WHERE recording_id=?", (rid,))
        matched, unmatched = 0, 0
        for it in data.get("items", []) or []:
            content = (it.get("observation") or it.get("content") or "").strip()
            if not content:
                continue
            st = match_student(students, it.get("number"), it.get("name"))
            if st:
                conn.execute("INSERT INTO notes(student_id, recording_id, date, kind, category, content, evidence) "
                             "VALUES (?,?,?,?,?,?,?)",
                             (st["id"], rid, date, r["kind"], it.get("category", ""), content,
                              (it.get("evidence") or "")[:400]))
                matched += 1
            else:
                conn.execute("INSERT INTO unmatched(recording_id, name_heard, content, evidence, category) "
                             "VALUES (?,?,?,?,?)",
                             (rid, "%s %s" % (it.get("number") or "", it.get("name") or ""), content,
                              (it.get("evidence") or "")[:400], it.get("category", "")))
                unmatched += 1
        for it in data.get("unmatched", []) or []:
            content = (it.get("observation") or it.get("content") or "").strip()
            if content:
                conn.execute("INSERT INTO unmatched(recording_id, name_heard, content, evidence, category) "
                             "VALUES (?,?,?,?,?)",
                             (rid, it.get("name_heard", ""), content, (it.get("evidence") or "")[:400],
                              it.get("category", "")))
                unmatched += 1
        status = "확인필요" if unmatched else "완료"
        conn.execute("UPDATE recordings SET status=?, error='' WHERE id=?", (status, rid))
        conn.commit()
        return {"ok": True, "matched": matched, "unmatched": unmatched}
    finally:
        conn.close()


def apply_draft(student_id, text):
    text = (text or "").strip().strip('"').strip()
    text = re.sub(r"^```\w*\s*|\s*```$", "", text).strip()
    if not text:
        raise ValueError("초안이 비어 있습니다.")
    conn = db.connect()
    conn.execute("INSERT INTO drafts(student_id, content, bytes) VALUES (?,?,?)",
                 (student_id, text, db.neis_bytes(text)))
    conn.commit()
    conn.close()
    return {"ok": True, "bytes": db.neis_bytes(text)}


# ───────────────────────── 이름 매칭 ─────────────────────────

def _lev(a, b):
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _aliases(s):
    return [a.strip() for a in re.split(r"[,，/]", s.get("aliases") or "") if a.strip()]


def match_student(students, number, name):
    name = re.sub(r"\s+", "", str(name or ""))
    try:
        number = int(str(number).replace("번", "").strip()) if number not in (None, "") else None
    except ValueError:
        number = None
    if not students:
        return None
    if name:
        exact = [s for s in students if s["name"] == name]
        if len(exact) == 1:
            return exact[0]
        if exact and number is not None:
            for s in exact:
                if s["number"] == number:
                    return s
        al = [s for s in students if name in _aliases(s)]
        if len(al) == 1:
            return al[0]
        given = [s for s in students if len(s["name"]) >= 3 and s["name"][1:] == name]
        if len(given) == 1:
            return given[0]
    if number is not None:
        by_num = [s for s in students if s["number"] == number]
        if by_num and (not name or _lev(by_num[0]["name"], name) <= 1):
            return by_num[0]
    if name:
        near = [s for s in students if _lev(s["name"], name) <= 1]
        if len(near) == 1:
            return near[0]
    return None


def guess_class(conn, hint):
    m = re.search(r"(\d)\s*학년\s*(\d{1,2})\s*반", hint or "") or re.search(r"(?<!\d)(\d)\s*-\s*(\d{1,2})(?!\d)", hint or "")
    if not m:
        return None
    g, c = int(m.group(1)), int(m.group(2))
    r = db.row(conn, "SELECT id FROM classes WHERE grade=? AND class_no=? ORDER BY year DESC, semester DESC, id DESC",
               (g, c))
    return r["id"] if r else None


def guess_class_by_time(conn, recorded_at, settings=None):
    """시간표(요일·교시 → 학급)로 녹음 시각의 학급을 찾는다. 수업 끝나고 15분까지는 그 수업으로 본다."""
    settings = settings or db.get_settings(conn)
    try:
        table = json.loads(settings.get("timetable") or "{}")
        dt = datetime.datetime.strptime((recorded_at or "")[:16], "%Y-%m-%d %H:%M")
    except (ValueError, TypeError):
        return None
    if not table:
        return None
    minute = dt.hour * 60 + dt.minute
    for i, line in enumerate((settings.get("period_times") or "").splitlines(), 1):
        m = re.match(r"\s*(\d{1,2}):(\d{2})\s*[-~]\s*(\d{1,2}):(\d{2})", line)
        if not m:
            continue
        start = int(m.group(1)) * 60 + int(m.group(2))
        end = int(m.group(3)) * 60 + int(m.group(4))
        if start - 5 <= minute <= end + 15:
            cid = table.get("%d-%d" % (dt.isoweekday(), i))
            if cid and db.row(conn, "SELECT id FROM classes WHERE id=?", (int(cid),)):
                return int(cid)
    return None


def auto_process(rid, force=False):
    """새로 들어온 기록을 설정에 맞게 자동 처리. API 키가 없으면 AI 없이 이름 기준으로 나눈다."""
    conn = db.connect()
    r = db.row(conn, "SELECT id, class_id, transcript, audio_path FROM recordings WHERE id=?", (rid,))
    settings = db.get_settings(conn)
    conn.close()
    if not r or (not force and settings.get("auto_process") != "1"):
        return
    has_text = bool((r["transcript"] or "").strip())
    if not has_text and r["audio_path"]:
        if use_whisper(settings):
            import whisper
            if whisper.available():
                enqueue("transcribe", {"recording_id": rid, "chain": True}, "내 맥에서 받아쓰기 #%d" % rid)
            else:
                conn = db.connect()
                _set_rec(conn, rid, status="보관됨", error="받아쓰기 모델을 내려받으면 자동으로 글자로 바뀝니다 (설정 → 받아쓰기 엔진)")
                conn.close()
        elif ai_ready(settings):
            enqueue("transcribe", {"recording_id": rid, "chain": True}, "전사 #%d" % rid)
    elif has_text:
        segment_after_transcript(rid, settings)


def process_pending():
    """받아쓰기 모델 설치 직후: 글자로 안 바뀐 채 기다리던 녹음을 모두 처리."""
    conn = db.connect()
    ids = [r["id"] for r in db.rows(conn, "SELECT id FROM recordings WHERE audio_path IS NOT NULL "
                                          "AND (transcript IS NULL OR transcript='') AND status IN ('보관됨','오류')")]
    conn.close()
    for rid in ids:
        auto_process(rid, force=True)
    return len(ids)


def ai_ready(settings):
    return settings.get("mode") == "api" and bool(settings.get("gemini_api_key"))


def use_whisper(settings):
    """받아쓰기 엔진: 기본은 내 맥(Whisper). 설정에서 Gemini를 고른 경우와 Intel 맥만 Gemini."""
    import whisper
    engine = settings.get("stt_engine") or "whisper"
    if engine == "gemini" or not whisper.supported():  # Intel 맥은 Whisper 불가 → Gemini
        return False
    return True  # 기본: 녹음이 맥 밖으로 나가지 않는 내 맥 받아쓰기


def segment_after_transcript(rid, settings=None):
    """전사문이 생긴 뒤: Gemini 키가 있으면 AI 분리, 없으면 이름 기준 규칙 분리."""
    settings = settings or db.get_settings()
    if ai_ready(settings):
        enqueue("segment", {"recording_id": rid}, "학생별 분리 #%d" % rid)
    else:
        try:
            rule_segment(rid)
        except ValueError:
            pass  # 학급 미지정 등 → 녹음함에서 사용자가 처리


# ───────────────────────── 규칙 기반 분리 (AI 없이) ─────────────────────────

def rule_segment(rid):
    """전사문에서 학생 이름이 언급된 지점을 기준으로 내용을 나눈다."""
    conn = db.connect()
    try:
        r = _recording(conn, rid)
        if not r["class_id"]:
            cid = guess_class(conn, (r["title"] or "") + " " + (r["transcript"] or "")[:300])
            if cid:
                conn.execute("UPDATE recordings SET class_id=? WHERE id=?", (cid, rid))
                r["class_id"] = cid
        students = _students(conn, r["class_id"])
        if not students:
            raise ValueError("학급과 학생 명단이 있어야 분리할 수 있습니다.")
        text = re.sub(r"\[\d{1,2}:\d{2}(?::\d{2})?\]", " ", r["transcript"] or "")
        text = re.sub(r"(교사|선생님|학생)\s*:", " ", text)
        # 학생별 검색어 (긴 것 우선)
        keys = []
        for s in students:
            names = {s["name"]} | set(_aliases(s))
            if len(s["name"]) >= 3:
                names.add(s["name"][1:])
            for n in names:
                if len(n) >= 2:
                    keys.append((n, s))
        keys.sort(key=lambda x: -len(x[0]))
        hits = []
        for n, s in keys:
            for m in re.finditer(re.escape(n), text):
                if any(h[0] <= m.start() < h[1] for h in hits):
                    continue
                hits.append((m.start(), m.end(), s))
        for m in re.finditer(r"(?:^|[\s.,])(\d{1,2})\s*번(?=[\s,.]|$)", text):
            num = int(m.group(1))
            st = [s for s in students if s["number"] == num]
            pos = m.start(1)
            if st and not any(h[0] <= pos < h[1] for h in hits):
                hits.append((pos, m.end(), st[0]))
        hits.sort(key=lambda h: h[0])
        # 각 언급이 포함된 문장의 시작점부터 다음 언급 문장 직전까지를 그 학생 몫으로 본다
        starts = []
        for start, _end, _s in hits:
            st = _sentence_start(text, start)
            if starts and st <= starts[-1]:
                st = start  # 같은 문장에 두 학생이 나오면 이름 위치에서 자름
            starts.append(st)
        blocks = []  # [학생, 시작, 끝]
        for i, (_start, _end, s) in enumerate(hits):
            stop = starts[i + 1] if i + 1 < len(hits) else len(text)
            if blocks and blocks[-1][0]["id"] == s["id"]:
                blocks[-1][2] = stop  # 연속된 같은 학생 언급은 합치기
            else:
                blocks.append([s, starts[i], stop])
        date = (r["recorded_at"] or "")[:10] or datetime.date.today().isoformat()
        conn.execute("DELETE FROM notes WHERE recording_id=?", (rid,))
        conn.execute("DELETE FROM unmatched WHERE recording_id=?", (rid,))
        count = 0
        for s, a, b in blocks:
            chunk = re.sub(r"\s+", " ", text[a:b]).strip()
            if len(chunk) < 6:
                continue
            conn.execute("INSERT INTO notes(student_id, recording_id, date, kind, category, content, evidence) "
                         "VALUES (?,?,?,?,?,?,?)",
                         (s["id"], rid, date, r["kind"], "기타", chunk[:1200], ""))
            count += 1
        conn.execute("UPDATE recordings SET status='확인필요', error='' WHERE id=?", (rid,))
        conn.commit()
        return {"ok": True, "matched": count, "unmatched": 0}
    finally:
        conn.close()


def _sentence_start(text, pos):
    i = pos
    while i > 0 and text[i - 1] not in ".?!\n。":
        i -= 1
        if pos - i > 40:  # 너무 멀리 거슬러 가지 않음
            return pos
    return i


# ───────────────────────── 작업 큐 ─────────────────────────

def enqueue(op, params, label=""):
    conn = db.connect()
    cur = conn.execute("INSERT INTO jobs(op, params, label) VALUES (?,?,?)",
                       (op, json.dumps(params, ensure_ascii=False), label))
    jid = cur.lastrowid
    if op == "transcribe":
        conn.execute("UPDATE recordings SET status='대기중', error='' WHERE id=?", (params["recording_id"],))
    conn.commit()
    conn.close()
    _wake.set()
    return jid


def _set_job_msg(job_id, msg):
    if not job_id:
        return
    conn = db.connect()
    conn.execute("UPDATE jobs SET message=? WHERE id=?", (msg, job_id))
    conn.commit()
    conn.close()


def _run_whisper(params, job_id=None):
    import whisper
    rid = params["recording_id"]
    conn = db.connect()
    r = _recording(conn, rid)
    students = _students(conn, r["class_id"])
    _set_rec(conn, rid, status="전사중", error="")
    conn.close()
    if not r["audio_path"] or not os.path.exists(r["audio_path"]):
        raise ValueError("녹음 파일이 없습니다.")
    last = [-1]

    def progress(p):
        if p >= last[0] + 5:
            last[0] = p
            _set_job_msg(job_id, "내 맥에서 받아쓰는 중 %d%%" % p)
    text = whisper.transcribe(r["audio_path"], students, r["kind"], on_progress=progress)
    return apply_transcript(rid, text, params.get("chain"))


def _run_api(op, params, job_id=None):
    settings = db.get_settings()
    if op == "transcribe" and use_whisper(settings):
        return _run_whisper(params, job_id)
    key = (settings.get("gemini_api_key") or "").strip()
    if not key:
        raise ValueError("Gemini API 키가 없습니다. 설정에서 입력하거나 '수동 모드'를 사용하세요.")
    model = settings.get("gemini_model") or "gemini-2.5-flash"

    def on_change(new_model):
        db.set_settings({"gemini_model": new_model})

    p = build_prompt(op, params)
    if op == "transcribe":
        rid = params["recording_id"]
        conn = db.connect()
        _set_rec(conn, rid, status="전사중", error="")
        conn.close()
        path = p["audio_path"]
        if not path or not os.path.exists(path):
            raise ValueError("녹음 파일이 없습니다.")
        conv, mime, is_tmp = gemini.prepare_audio(path)
        name = None
        try:
            uri, mime2, name = gemini.upload_file(key, conv, mime, "rec-%d" % rid)
            text = gemini.generate(key, model, p["prompt"], file_uri=uri, file_mime=mime2,
                                   temperature=0.1, on_model_change=on_change)
        finally:
            if name:
                gemini.delete_file(key, name)
            if is_tmp:
                try:
                    os.remove(conv)
                    os.rmdir(os.path.dirname(conv))
                except OSError:
                    pass
        return apply(op, params, text)
    if op == "segment":
        conn = db.connect()
        _set_rec(conn, params["recording_id"], status="분리중", error="")
        conn.close()
    text = gemini.generate(key, model, p["prompt"], system=p.get("system"), json_mode=p.get("json", False),
                           temperature=0.2 if op == "segment" else 0.6, on_model_change=on_change)
    return apply(op, params, text)


def _worker():
    while True:
        _wake.wait(5)
        _wake.clear()
        while True:
            conn = db.connect()
            job = db.row(conn, "SELECT * FROM jobs WHERE status='대기' ORDER BY id LIMIT 1")
            if not job:
                conn.close()
                break
            conn.execute("UPDATE jobs SET status='진행중' WHERE id=?", (job["id"],))
            conn.commit()
            conn.close()
            params = json.loads(job["params"] or "{}")
            status, msg = "완료", ""
            try:
                res = _run_api(job["op"], params, job["id"])
                if isinstance(res, dict) and "matched" in res:
                    msg = "배정 %d건, 미배정 %d건" % (res["matched"], res["unmatched"])
            except Exception as e:  # noqa
                status, msg = "실패", str(e)
                traceback.print_exc()
                if "recording_id" in params:
                    conn = db.connect()
                    _set_rec(conn, params["recording_id"], status="오류", error=msg[:500])
                    conn.close()
            conn = db.connect()
            conn.execute("UPDATE jobs SET status=?, message=?, finished_at=datetime('now','localtime') WHERE id=?",
                         (status, msg[:500], job["id"]))
            conn.commit()
            conn.close()


def start_worker():
    t = threading.Thread(target=_worker, daemon=True, name="ai-worker")
    t.start()
