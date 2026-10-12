# -*- coding: utf-8 -*-
"""프롬프트_모음.md 생성 (앱의 '프롬프트 안내' 화면과 같은 내용). 실행: python3 tools/make_prompt_doc.py"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "app"))
import db, prompts  # noqa: E402

out = ["# 세특도우미 프롬프트 모음", "",
       "Gemini(gemini.google.com)나 ChatGPT(chatgpt.com) 웹 화면에서 **직접 복사해 붙여넣어 쓰는 문구**입니다.",
       "API 키 없이, 지금 쓰는 구독(월 2~3만 원 요금제)만으로 쓸 수 있습니다.", "",
       "> 앱 안 **프롬프트 안내** 메뉴에도 같은 내용이 있고 **복사 버튼**이 있습니다. 그쪽은 설정한 바이트 한도·추가 지침이 반영됩니다.",
       "> 아래 문구의 **[대괄호]** 부분만 실제 내용으로 바꾸면 됩니다.", "",
       "## 가장 쉬운 사용 순서", "",
       "1. **①**의 지침으로 Gemini 'Gem'(또는 ChatGPT 'GPT')을 **한 번만** 만들어 둡니다.",
       "2. 녹음은 세특도우미가 **이 맥 안에서(Whisper)** 글자로 바꾸고 학생별로 나눕니다. (②③은 필요할 때만)",
       "3. 학생 화면 **관찰기록 복사** → Gem에 `이 학생 세특 써줘`와 함께 붙여넣기 → 결과를 학생 화면 편집창에 붙여넣고 **확정**.",
       "4. 너무 길면 Gem에 `1500바이트 이내로 줄여줘` 또는 **⑤** 사용.", ""]
for t in prompts.guide(db.DEFAULT_SETTINGS):
    out += ["---", "", "## " + t["title"], "", "**언제:** " + t["when"], ""]
    out += ["%d. %s" % (i + 1, s) for i, s in enumerate(t["steps"])]
    out += ["", "```text", t["prompt"].strip(), "```", ""]
with open(os.path.join(ROOT, "프롬프트_모음.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(out))
print("ok")
