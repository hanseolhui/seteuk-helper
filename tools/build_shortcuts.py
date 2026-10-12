# -*- coding: utf-8 -*-
"""아이폰 단축어 파일 만들기 → shortcuts sign 으로 서명 → dist/ 에 저장.

만든 단축어는 녹음/받아쓰기 결과를 iCloud Drive › Shortcuts › 쓰담 폴더에 저장하고,
컴퓨터의 쓰담이 그 폴더를 자동으로 가져온다.
실행: python3 tools/build_shortcuts.py   (이 맥이 iCloud에 로그인돼 있어야 서명됨)
"""
import os
import plistlib
import subprocess
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dist")
FOLDER = "쓰담"


def _date_name(prefix, ext=""):
    """'세특 20261012 1030' 형태의 이름 (현재 날짜 변수 + 사용자 지정 형식)"""
    return {
        "Value": {
            "string": prefix + "￼" + ext,
            "attachmentsByRange": {
                "{%d, 1}" % len(prefix): {
                    "Type": "CurrentDate",
                    "Aggrandizements": [{
                        "Type": "WFDateFormatVariableAggrandizement",
                        "WFDateFormatStyle": "Custom",
                        "WFDateFormat": "yyyyMMdd HHmm",
                    }],
                }
            },
        },
        "WFSerializationType": "WFTextTokenString",
    }


def _output(uid, name):
    return {"Value": {"OutputUUID": uid, "Type": "ActionOutput", "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}


def _workflow(actions, color, glyph):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2302.0.4",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": color, "WFWorkflowIconGlyphNumber": glyph},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
    }


def record_shortcut():
    rec, named = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    return _workflow([
        {"WFWorkflowActionIdentifier": "is.workflow.actions.recordaudio",
         "WFWorkflowActionParameters": {"UUID": rec, "WFRecordingCompression": "Normal",
                                        "WFRecordingStart": "Immediately", "WFRecordingEnd": "On Tap"}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.setitemname",
         "WFWorkflowActionParameters": {"UUID": named, "WFInput": _output(rec, "Recorded Audio"),
                                        "WFName": _date_name("쓰담 ")}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
         "WFWorkflowActionParameters": {"WFInput": _output(named, "Renamed Item"), "WFAskWhereToSave": False,
                                        "WFFileDestinationPath": FOLDER + "/", "WFSaveFileOverwrite": False}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.notification",
         "WFWorkflowActionParameters": {"WFNotificationActionTitle": "쓰담 녹음 저장됨",
                                        "WFNotificationActionBody": "컴퓨터의 쓰담으로 자동 전송됩니다.",
                                        "WFNotificationActionSound": False}},
    ], 4282601983, 59511)  # 파랑, 마이크


def dictate_shortcut():
    txt, named = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    return _workflow([
        {"WFWorkflowActionIdentifier": "is.workflow.actions.dictatetext",
         "WFWorkflowActionParameters": {"UUID": txt, "WFDictateTextLanguage": "ko-KR",
                                        "WFDictateTextStopListening": "On Tap"}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.setitemname",
         "WFWorkflowActionParameters": {"UUID": named, "WFInput": _output(txt, "Dictated Text"),
                                        "WFName": _date_name("쓰담 메모 ", ".txt")}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
         "WFWorkflowActionParameters": {"WFInput": _output(named, "Renamed Item"), "WFAskWhereToSave": False,
                                        "WFFileDestinationPath": FOLDER + "/", "WFSaveFileOverwrite": False}},
        {"WFWorkflowActionIdentifier": "is.workflow.actions.notification",
         "WFWorkflowActionParameters": {"WFNotificationActionTitle": "쓰담 메모 저장됨",
                                        "WFNotificationActionBody": "컴퓨터의 쓰담으로 자동 전송됩니다.",
                                        "WFNotificationActionSound": False}},
    ], 4292093695, 59759)  # 초록, 말풍선


def main():
    os.makedirs(OUT, exist_ok=True)
    ok = True
    for name, wf in (("쓰담 녹음", record_shortcut()), ("쓰담 받아쓰기", dictate_shortcut())):
        raw = os.path.join(OUT, name + ".unsigned.shortcut")
        signed = os.path.join(OUT, name + ".shortcut")
        with open(raw, "wb") as f:
            plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
        r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", raw, "--output", signed],
                           capture_output=True, text=True)
        if r.returncode == 0 and os.path.exists(signed):
            os.remove(raw)
            print("서명 완료:", signed)
        else:
            ok = False
            print("서명 실패(%s): %s" % (name, (r.stderr or r.stdout).strip()))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
