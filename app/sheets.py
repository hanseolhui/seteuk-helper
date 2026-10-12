# -*- coding: utf-8 -*-
"""출력: 구글시트(Apps Script 웹앱), CSV, TSV."""
import csv
import io
import json
import urllib.error
import urllib.request

import db
import gemini

HEADER = ["번호", "이름", "관찰기록 수", "세특 초안", "바이트", "상태", "최종 수정", "관찰기록 요약"]


def class_table(conn, class_id):
    c = db.row(conn, "SELECT * FROM classes WHERE id=?", (class_id,))
    if not c:
        raise ValueError("학급을 찾을 수 없습니다.")
    students = db.rows(conn, "SELECT * FROM students WHERE class_id=? ORDER BY number, name", (class_id,))
    out = []
    for s in students:
        notes = db.rows(conn, "SELECT date, content FROM notes WHERE student_id=? ORDER BY date, id", (s["id"],))
        d = db.row(conn, "SELECT * FROM drafts WHERE student_id=? ORDER BY (status='확정') DESC, id DESC LIMIT 1",
                   (s["id"],))
        summary = "\n".join("(%s) %s" % (n["date"] or "", n["content"]) for n in notes)
        out.append([s["number"] or "", s["name"], len(notes),
                    d["content"] if d else "", d["bytes"] if d else 0,
                    d["status"] if d else "미작성", d["created_at"] if d else "", summary[:45000]])
    return db.class_label(c), out


def to_csv(header, rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(header)
    w.writerows(rows)
    return "﻿" + buf.getvalue()  # 엑셀 한글 깨짐 방지 BOM


def to_tsv(header, rows):
    def cell(v):
        v = str(v)
        if any(ch in v for ch in "\t\n\""):
            v = '"' + v.replace('"', '""') + '"'
        return v
    return "\n".join("\t".join(cell(v) for v in r) for r in [header] + rows)


def send_to_sheets(url, token, sheet_name, header, rows):
    if not url:
        raise ValueError("설정에서 구글시트 웹앱 주소를 먼저 입력하세요.")
    body = json.dumps({"token": token or "", "sheet": sheet_name, "header": header, "rows": rows},
                      ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "text/plain;charset=utf-8"},
                                 method="POST")
    try:
        # Apps Script는 302로 결과 주소를 돌려주며, urllib가 GET으로 따라간다
        resp = urllib.request.urlopen(req, timeout=60, context=gemini._CTX)
        text = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise ValueError("구글시트 전송 실패 (HTTP %s). 웹앱 배포 설정(액세스: 모든 사용자)을 확인하세요." % e.code)
    except urllib.error.URLError as e:
        raise ValueError("구글시트에 연결하지 못했습니다: %s" % e.reason)
    try:
        res = json.loads(text)
    except ValueError:
        raise ValueError("구글시트 응답을 이해하지 못했습니다. 웹앱 주소가 '/exec'로 끝나는지 확인하세요.")
    if not res.get("ok"):
        raise ValueError("구글시트 오류: %s" % res.get("error", "알 수 없음"))
    return res
