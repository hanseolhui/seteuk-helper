/**
 * 세특도우미 → 구글시트 연결 스크립트
 *
 * 사용법
 * 1. 구글시트에서 [확장 프로그램] → [Apps Script]
 * 2. 기존 내용을 지우고 이 파일 전체를 붙여넣고 저장(⌘S)
 * 3. [배포] → [새 배포] → 톱니바퀴에서 '웹 앱' 선택
 *    - 다음 사용자 인증정보로 실행: 나
 *    - 액세스 권한이 있는 사용자: 모든 사용자
 * 4. [배포] → 권한 검토 → 본인 계정 선택 → (경고 화면이면 '고급' → '안전하지 않음으로 이동') → 허용
 * 5. 표시된 웹 앱 URL(…/exec)을 세특도우미 설정에 붙여넣기
 *
 * 보안을 위해 아래 TOKEN에 아무 문자열이나 넣고, 세특도우미 설정의 '보안 토큰'에도 똑같이 넣으세요.
 */
var TOKEN = '';

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    if (TOKEN && data.token !== TOKEN) {
      return json_({ ok: false, error: '보안 토큰이 일치하지 않습니다.' });
    }
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var name = String(data.sheet || '세특').substring(0, 90);
    var sh = ss.getSheetByName(name) || ss.insertSheet(name);
    var header = data.header || [];
    var rows = data.rows || [];
    sh.clearContents();
    sh.getRange(1, 1, 1, header.length).setValues([header]).setFontWeight('bold').setBackground('#e6eefc');
    if (rows.length) {
      sh.getRange(2, 1, rows.length, header.length).setValues(rows);
    }
    sh.setFrozenRows(1);
    sh.setColumnWidth(1, 50);
    sh.setColumnWidth(2, 80);
    sh.setColumnWidth(4, 520);
    sh.setColumnWidth(8, 420);
    sh.getRange(2, 1, Math.max(rows.length, 1), header.length).setVerticalAlignment('top').setWrap(true);
    sh.getRange(1, header.length + 2).setValue('마지막 전송: ' + new Date().toLocaleString('ko-KR'));
    return json_({ ok: true, count: rows.length });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

function doGet() {
  return json_({ ok: true, message: '세특도우미 연결 스크립트가 작동 중입니다.' });
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
