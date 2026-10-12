; 쓰담 윈도우 설치 프로그램 (macOS/리눅스에서 makensis로 빌드)
Unicode true
!include "MUI2.nsh"
!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef SRC
  !define SRC "..\build\win"
!endif

Name "쓰담"
OutFile "..\dist\Sseudam-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\Sseudam"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "쓰담 ${VERSION} — 말로 담고, 글로 씁니다"
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "쓰담"
VIAddVersionKey "FileDescription" "쓰담 설치"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "쓰담"

!define MUI_ICON "${SRC}\sseudam.ico"
!define MUI_UNICON "${SRC}\sseudam.ico"
!define MUI_WELCOMEPAGE_TITLE "쓰담 설치"
!define MUI_WELCOMEPAGE_TEXT "수업·상담 중 말로 남긴 학생 관찰을 학생별로 정리하고, 학기말 생기부 초안을 만드는 프로그램입니다.$\r$\n$\r$\n관리자 권한 없이 이 사용자 계정에만 설치됩니다. 학생 기록은 업데이트·재설치해도 그대로 유지됩니다."
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_RUN_TEXT "지금 쓰담 실행"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Korean"

Function LaunchApp
  Exec '"$INSTDIR\python\pythonw.exe" "$INSTDIR\launcher.pyw"'
FunctionEnd

Section "install"
  ; 실행 중이면 끄기 (업데이트 설치)
  IfFileExists "$INSTDIR\python\pythonw.exe" 0 +3
    nsExec::Exec '"$INSTDIR\python\pythonw.exe" "$INSTDIR\stop.py"'
    Sleep 1500
  SetOutPath "$INSTDIR"
  RMDir /r "$INSTDIR\app"
  File /r "${SRC}\*.*"
  CreateShortcut "$SMPROGRAMS\쓰담.lnk" "$INSTDIR\python\pythonw.exe" '"$INSTDIR\launcher.pyw"' "$INSTDIR\sseudam.ico" 0
  CreateShortcut "$DESKTOP\쓰담.lnk" "$INSTDIR\python\pythonw.exe" '"$INSTDIR\launcher.pyw"' "$INSTDIR\sseudam.ico" 0
  WriteUninstaller "$INSTDIR\uninstall.exe"
  !define UK "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sseudam"
  WriteRegStr HKCU "${UK}" "DisplayName" "쓰담"
  WriteRegStr HKCU "${UK}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UK}" "Publisher" "쓰담"
  WriteRegStr HKCU "${UK}" "DisplayIcon" "$INSTDIR\sseudam.ico"
  WriteRegStr HKCU "${UK}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UK}" "URLInfoAbout" "https://hanseolhui.github.io/sseudam/"
  WriteRegDWORD HKCU "${UK}" "NoModify" 1
  WriteRegDWORD HKCU "${UK}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  nsExec::Exec '"$INSTDIR\python\pythonw.exe" "$INSTDIR\stop.py"'
  Sleep 1000
  Delete "$SMPROGRAMS\쓰담.lnk"
  Delete "$DESKTOP\쓰담.lnk"
  Delete "$SMSTARTUP\쓰담.lnk"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Sseudam"
  ; 학생 기록(%APPDATA%\쓰담)은 지우지 않음
SectionEnd
