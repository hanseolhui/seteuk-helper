# -*- coding: utf-8 -*-
"""AI 프롬프트. API 모드와 수동(복사·붙여넣기) 모드가 같은 문구를 사용한다."""

FORBIDDEN_TERMS = [
    "토익", "TOEIC", "토플", "TOEFL", "텝스", "TEPS", "HSK", "JLPT", "DELF", "IELTS",
    "교외", "외부 대회", "올림피아드", "경시대회", "공모전", "수상", "입상", "금상", "은상", "동상", "대상을",
    "논문", "학회", "특허", "출판", "저서", "발명",
    "해외", "어학연수", "유학",
    "부모", "아버지", "어머니", "아빠", "엄마", "가정형편", "직업이",
    "학원", "과외", "인강",
]


def roster_text(students):
    lines = []
    for s in students:
        line = "%s번 %s" % (s.get("number") if s.get("number") is not None else "-", s["name"])
        if s.get("aliases"):
            line += " (다르게 들릴 수 있는 이름: %s)" % s["aliases"]
        lines.append(line)
    return "\n".join(lines) if lines else "(명단 없음)"


def transcribe(kind, class_label, students):
    context = "수업 중 교사가 학생들을 관찰·평가하며 말한 내용" if kind == "수업" else "교사와 학생의 개별 상담"
    return """다음 오디오는 한국 %s의 %s을(를) 녹음한 것입니다.
오디오를 한국어로 빠짐없이 그대로 받아 적어 주세요.

규칙
- 요약하지 말고 들리는 말을 그대로 적을 것. 불필요한 추임새(음, 어)는 생략 가능.
- 말의 흐름이 바뀌거나 학생이 바뀔 때마다 줄을 바꾸고, 각 문단 앞에 [분:초] 시각을 표시.
- 학생 이름은 아래 명단의 표기를 우선 사용. 명단에 없는 이름은 들리는 대로 적기.
- 교사와 학생의 말이 구분되면 "교사:", "학생:"을 앞에 붙이기.
- 설명이나 머리말 없이 전사문만 출력.

학급: %s
학생 명단
%s
""" % ("학교", context, class_label or "미지정", roster_text(students))


SEGMENT_SYSTEM = "너는 한국 고등학교 교사의 학생 관찰기록을 정리하는 조수다. 반드시 지시된 JSON만 출력한다."


def segment(kind, class_label, students, transcript, date):
    return """아래는 교사가 %s 중 학생들에 대해 말한 내용을 받아 적은 전사문입니다.
학생 명단과 대조하여 학생별 관찰 내용을 분리해 주세요.

[작업 규칙]
1. 교사가 특정 학생을 이름(또는 번호, 성을 뺀 이름)으로 언급하면 그 뒤의 평가·관찰 내용을 그 학생에게 배정.
   이름이 다시 나오지 않아도 다른 학생으로 넘어가기 전까지의 내용은 같은 학생의 것으로 봄.
2. 전사 오류로 이름이 조금 다르게 적혔으면 명단에서 가장 비슷한 학생으로 배정 (예: '김민서'→'김민수').
3. 명단에 없는 이름이거나 판단이 어려우면 unmatched에 넣음.
4. observation: 교사가 관찰한 사실(활동, 태도, 발언, 결과물, 성장)을 1~3문장으로 정리.
   교사의 말에 없는 내용을 지어내지 말 것. 문장은 '~함', '~임', '~보임' 같은 명사형 종결.
5. evidence: 근거가 된 전사문 원문 일부를 그대로 발췌(최대 200자).
6. category: 다음 중 하나 — 발표, 토론, 탐구, 과제, 수업태도, 협업, 질문, 성장, 상담, 기타
7. 한 학생이 여러 번 언급되면 내용별로 여러 항목으로 나누어도 됨.
8. 학급이 언급되면(예: '2학년 3반') class_hint에 적기.
9. 수업 진행 발언, 출결 호명처럼 평가 내용이 없는 언급은 제외.

[출력 형식 — 이 JSON만 출력]
{"class_hint": "", "items": [{"number": 3, "name": "김민수", "category": "발표", "observation": "...", "evidence": "..."}], "unmatched": [{"name_heard": "...", "category": "기타", "observation": "...", "evidence": "..."}]}

[기록 정보] 날짜: %s / 유형: %s / 학급: %s

[학생 명단]
%s

[전사문]
%s
""" % (kind, date or "", kind, class_label or "미지정", roster_text(students), transcript)


DRAFT_SYSTEM = "너는 한국 학교생활기록부 교과 세부능력 및 특기사항(세특) 작성을 돕는 전문 조수다."


def draft(student, class_info, notes, settings, extra=""):
    limit = int(settings.get("byte_limit") or 1500)
    approx_chars = int(limit / 3 * 0.95)
    subject = (class_info.get("subject") or settings.get("teacher_subject") or "해당 교과")
    note_lines = []
    for n in notes:
        tag = "[%s/%s%s]" % (n.get("date") or "날짜미상", n.get("kind") or "",
                             ("/" + n["category"]) if n.get("category") else "")
        line = "%s %s" % (tag, n["content"])
        if n.get("evidence"):
            line += "  (원문: %s)" % n["evidence"][:160]
        note_lines.append("- " + line)
    style = (settings.get("style_examples") or "").strip()
    guidance = (settings.get("draft_guidance") or "").strip()
    out = """%s %s 과목 학교생활기록부 '세부능력 및 특기사항' 초안을 작성해 주세요.

[작성 원칙]
- 아래 교사의 관찰기록에 있는 사실만 근거로 작성. 기록에 없는 활동·성과·역량을 지어내지 말 것.
- 구체적 활동(무엇을 했는지) → 과정에서 드러난 태도·사고 → 역량·성장 순으로 자연스럽게 연결.
- 문장은 '~함', '~임', '~보임', '~돋보임' 등 명사형 종결. 학생 이름이나 '학생은'이라는 주어를 쓰지 말 것.
- 막연한 칭찬어(성실함, 우수함)만 나열하지 말고 관찰된 근거와 함께 서술.
- 상담 기록은 학업·진로와 관련된 내용만 활용하고, 가정사·건강·교우관계 등 민감한 개인사는 쓰지 말 것.
- 기재 금지: 교외 대회·수상, 공인어학시험 점수, 논문·학회, 특허, 도서 출간, 해외 활동, 부모의 직업·사회경제적 지위, 사교육, 특정 대학·기관·상호명.
- 분량: NEIS 기준 %d바이트 이내(한글 약 %d자 이내), 한 문단. 줄바꿈 없이.
- 머리말·설명·따옴표 없이 세특 본문만 출력.
""" % (("%s학년" % class_info["grade"]) if class_info.get("grade") else "", subject, limit, approx_chars)
    if guidance:
        out += "\n[교사의 추가 지침]\n%s\n" % guidance
    if style:
        out += "\n[문체 참고 예시 — 문체만 참고하고 내용은 베끼지 말 것]\n%s\n" % style
    if extra:
        out += "\n[이번 학생에 대해 특히 강조할 점]\n%s\n" % extra
    out += "\n[학교급] %s\n" % (settings.get("school_level") or "고등학교")
    out += "[학생] %s번 (이름은 본문에 쓰지 말 것)\n" % (student.get("number") or "-")
    if student.get("memo"):
        out += "[교사 메모] %s\n" % student["memo"]
    out += "\n[관찰기록 %d건]\n%s\n" % (len(notes), "\n".join(note_lines) if note_lines else "(기록 없음)")
    return out


def shorten(text, target_bytes, current_bytes):
    return """다음 학교생활기록부 세특 문장을 NEIS 기준 %d바이트 이하(한글 약 %d자 이하)로 줄여 주세요.
현재 %d바이트입니다. 핵심 활동과 역량 서술은 남기고 중복·수식어를 덜어내세요.
명사형 종결(~함, ~임)을 유지하고, 새로운 내용을 추가하지 말고, 본문만 출력하세요.

%s
""" % (target_bytes, int(target_bytes / 3 * 0.95), current_bytes, text)


def check_forbidden(text):
    found = []
    low = (text or "").lower()
    for t in FORBIDDEN_TERMS:
        if t.lower() in low and t not in found:
            found.append(t)
    return found
