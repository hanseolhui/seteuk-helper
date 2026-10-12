/**
 * 세특도우미 ↔ 구글시트·드라이브 연결 스크립트 (버전 2)
 *
 * 하는 일
 *  - 세특도우미의 학급별 세특·관찰기록을 이 시트에 자동으로 반영 (앱 → 시트, 보기용 사본)
 *  - 하루 한 번 전체 기록을 압축해 내 구글 드라이브 '세특도우미 백업' 폴더에 저장 (최근 30개)
 *
 * 설치
 *  1. 구글시트에서 [확장 프로그램] → [Apps Script]
 *  2. 기존 내용을 지우고 이 파일 전체를 붙여넣고 저장(⌘S)
 *     (세특도우미의 '스크립트 복사' 버튼을 쓰면 아래 TOKEN이 자동으로 채워져 있습니다)
 *  3. [배포] → [새 배포] → 톱니바퀴에서 '웹 앱'
 *     - 다음 사용자 인증정보로 실행: 나 / 액세스 권한이 있는 사용자: 모든 사용자
 *  4. [배포] → 권한 검토 → 내 계정 → (경고 화면이면 '고급' → '안전하지 않음으로 이동') → 허용
 *  5. 웹 앱 URL(…/exec)을 세특도우미 설정에 붙여넣기
 *
 * 스크립트를 새 버전으로 바꿨을 때: [배포] → [배포 관리] → 연필 → 버전: '새 버전' → 배포 (URL은 그대로)
 */
var TOKEN = '';            // 세특도우미 설정의 '보안 토큰'과 같아야 합니다
var SCRIPT_VERSION = 2;
var BACKUP_FOLDER = '세특도우미 백업';
var REGISTRY = '_세특도우미';

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);
    if (TOKEN && data.token !== TOKEN) return json_({ ok: false, error: '보안 토큰이 일치하지 않습니다.' });
    var action = data.action || 'sync_one';
    if (action === 'ping') return json_({ ok: true, version: SCRIPT_VERSION, url: SpreadsheetApp.getActiveSpreadsheet().getUrl() });
    if (action === 'sync') return json_(sync_(data.sheets || []));
    if (action === 'sync_one') return json_(sync_([{ name: data.sheet, header: data.header, rows: data.rows }], true));
    if (action === 'backup') return json_(backup_(data));
    if (action === 'list_backups') return json_(listBackups_());
    if (action === 'get_backup') return json_(getBackup_(data.id));
    return json_({ ok: false, error: '알 수 없는 요청: ' + action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

function doGet() {
  return json_({ ok: true, version: SCRIPT_VERSION, message: '세특도우미 연결 스크립트가 작동 중입니다.' });
}

function sync_(sheets, keepOthers) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var names = [];
  sheets.forEach(function (s, idx) {
    var name = String(s.name || '세특').substring(0, 90);
    names.push(name);
    var sh = ss.getSheetByName(name) || ss.insertSheet(name, idx);
    var header = s.header || [];
    var rows = s.rows || [];
    sh.clear();
    if (header.length) {
      sh.getRange(1, 1, 1, header.length).setValues([header]).setFontWeight('bold').setBackground('#e6eefc');
      if (rows.length) sh.getRange(2, 1, rows.length, header.length).setValues(rows)
        .setVerticalAlignment('top').setWrap(true);
      sh.setFrozenRows(1);
      (s.widths || []).forEach(function (w, i) { sh.setColumnWidth(i + 1, Math.max(40, Math.round(w * 7.5))); });
    }
    sh.getRange(1, header.length + 2).setValue('세특도우미에서 자동 반영 · ' + new Date().toLocaleString('ko-KR') + ' · 여기서 고친 내용은 다음 동기화 때 덮어써집니다');
    // 실수로 고치지 않게 경고만 표시하는 보호
    var prot = sh.getProtections(SpreadsheetApp.ProtectionType.SHEET);
    if (!prot.length) sh.protect().setWarningOnly(true).setDescription('세특도우미 자동 반영 시트');
  });
  if (!keepOthers) {
    // 예전에 세특도우미가 만든 시트 중 지금 없는 학급 시트 정리
    var reg = ss.getSheetByName(REGISTRY);
    var prev = reg ? reg.getRange('A:A').getValues().map(function (r) { return r[0]; }).filter(String) : [];
    prev.forEach(function (n) {
      if (names.indexOf(n) === -1) { var old = ss.getSheetByName(n); if (old && ss.getSheets().length > 1) ss.deleteSheet(old); }
    });
    if (!reg) { reg = ss.insertSheet(REGISTRY); reg.hideSheet(); }
    reg.clear();
    if (names.length) reg.getRange(1, 1, names.length, 1).setValues(names.map(function (n) { return [n]; }));
    var blank = ss.getSheetByName('시트1') || ss.getSheetByName('Sheet1');
    if (blank && blank.getLastRow() === 0 && ss.getSheets().length > 2) ss.deleteSheet(blank);
  }
  return { ok: true, version: SCRIPT_VERSION, count: sheets.length, url: ss.getUrl() };
}

function folder_() {
  var it = DriveApp.getFoldersByName(BACKUP_FOLDER);
  return it.hasNext() ? it.next() : DriveApp.createFolder(BACKUP_FOLDER);
}

function backup_(data) {
  var f = folder_();
  var blob = Utilities.newBlob(Utilities.base64Decode(data.data), 'application/zip', data.filename);
  var file = f.createFile(blob);
  var keep = data.keep || 30;
  var files = [];
  var it = f.getFiles();
  while (it.hasNext()) files.push(it.next());
  files.sort(function (a, b) { return b.getDateCreated() - a.getDateCreated(); });
  files.slice(keep).forEach(function (x) { x.setTrashed(true); });
  return { ok: true, version: SCRIPT_VERSION, url: file.getUrl() };
}

function listBackups_() {
  var f = folder_();
  var out = [];
  var it = f.getFiles();
  while (it.hasNext()) {
    var x = it.next();
    out.push({ id: x.getId(), name: x.getName(), size: x.getSize(), time: x.getDateCreated().toISOString() });
  }
  out.sort(function (a, b) { return a.time < b.time ? 1 : -1; });
  return { ok: true, version: SCRIPT_VERSION, files: out };
}

function getBackup_(id) {
  var x = DriveApp.getFileById(id);
  if (x.getParents().next().getName() !== BACKUP_FOLDER) return { ok: false, error: '백업 폴더의 파일이 아닙니다.' };
  return { ok: true, version: SCRIPT_VERSION, data: Utilities.base64Encode(x.getBlob().getBytes()) };
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
