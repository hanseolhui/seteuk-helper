/* 쓰담 프론트엔드 (외부 라이브러리 없음) */
'use strict';

const $ = (sel, root) => (root || document).querySelector(sel);
const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
const view = $('#view');
const state = { settings: null, classes: [], jobsActive: 0, lastJobIds: '' };

const CATEGORIES = ['발표', '토론', '탐구', '과제', '수업태도', '협업', '질문', '성장', '상담', '기타'];
const STATUS_COLOR = { '보관됨': 'amber', '대기중': 'blue', '전사중': 'blue', '전사완료': 'blue', '분리중': 'blue',
  '확인필요': 'amber', '완료': 'green', '오류': 'red' };

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function neisBytes(t) {
  let n = 0;
  for (const ch of (t || '').replace(/\r\n/g, '\n')) n += ch === '\n' ? 2 : (ch.charCodeAt(0) < 128 ? 1 : 3);
  return n;
}
function today() { return new Date().toISOString().slice(0, 10); }
function nowLocal() {
  const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}
function fmtDate(s) { return s ? String(s).slice(0, 16).replace('T', ' ') : ''; }

async function api(path, body, opts) {
  opts = opts || {};
  const init = { method: body === undefined ? 'GET' : 'POST', headers: { 'X-Seteuk': '1' } };
  if (body !== undefined) {
    if (body instanceof Blob || body instanceof ArrayBuffer) { init.body = body; init.headers['Content-Type'] = 'application/octet-stream'; }
    else { init.body = JSON.stringify(body); init.headers['Content-Type'] = 'application/json'; }
  }
  let res;
  try { res = await fetch(path, init); }
  catch (e) { throw new Error('프로그램(서버)과 연결이 끊겼습니다. "쓰담 시작"을 다시 실행하세요.'); }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const err = new Error(data.error || ('오류 ' + res.status)); if (!opts.silent) toast(err.message, true); throw err; }
  return data;
}

let toastTimer;
function toast(msg, isErr) {
  const t = $('#toast');
  t.textContent = msg; t.className = 'toast' + (isErr ? ' err' : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.add('hidden'), isErr ? 6000 : 2600);
}

function modal(html, onMount) {
  $('#modal-box').innerHTML = html;
  $('#modal').classList.remove('hidden');
  if (onMount) onMount($('#modal-box'));
}
function closeModal() { $('#modal').classList.add('hidden'); $('#modal-box').innerHTML = ''; }
$('#modal').addEventListener('mousedown', e => { if (e.target.id === 'modal') closeModal(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); });

function confirmBox(msg) { return window.confirm(msg); }

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); }
  catch (e) {
    const ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
    document.execCommand('copy'); ta.remove();
  }
  toast('복사했습니다');
}

async function loadClasses() { state.classes = (await api('/api/classes')).classes; return state.classes; }
function classOptions(selected, allowEmpty) {
  let h = allowEmpty ? `<option value="">${allowEmpty === true ? '학급 미지정' : esc(allowEmpty)}</option>` : '';
  for (const c of state.classes) h += `<option value="${c.id}" ${String(c.id) === String(selected) ? 'selected' : ''}>${esc(c.label)} (${c.year}-${c.semester}학기)</option>`;
  return h;
}
function badge(status) { return `<span class="badge ${STATUS_COLOR[status] || ''}">${esc(status)}</span>`; }
function kindBadge(kind) { return `<span class="badge ${kind === '상담' ? 'violet' : 'blue'}">${esc(kind || '수업')}</span>`; }

// ───────────────────────── AI 실행 (API / 수동) ─────────────────────────

async function runAI(op, params, label, onDone) {
  let res;
  try { res = await api('/api/ai/run', { op, params, label: label || '' }, { silent: true }); }
  catch (e) {
    if (e.message === 'NEED_WHISPER_MODEL') {
      modal(`<h2>받아쓰기 모델이 필요합니다</h2><p>녹음을 이 맥 안에서 글자로 바꾸려면 Whisper 모델(550MB)을 한 번 내려받아야 합니다. 받는 동안 다른 작업을 계속해도 되고, 끝나면 이 녹음이 자동으로 받아써집니다.</p>
        <div class="modal-actions"><button id="m-x">나중에</button><button class="primary" id="m-dl">지금 내려받기</button></div>`, box => {
        $('#m-x', box).onclick = closeModal;
        $('#m-dl', box).onclick = async () => { await api('/api/whisper/download', { id: 'turbo-q5' }); closeModal(); toast('내려받기를 시작했습니다. 진행 상황은 설정 → 받아쓰기 엔진에서 볼 수 있어요.'); };
      });
      return;
    }
    toast(e.message, true); return;
  }
  if (res.manual) return showManual(op, params, res, onDone);
  toast('AI 작업을 시작했습니다. 오른쪽 아래에서 진행 상황을 볼 수 있어요.');
  pollJobs(true);
}

function showManual(op, params, res, onDone) {
  const titles = { transcribe: '전사 (수동)', segment: '학생별 분리 (수동)', draft: '세특 초안 (수동)', shorten: '초안 줄이기 (수동)' };
  const audioStep = op === 'transcribe'
    ? `<li><b>녹음 파일도 함께 첨부</b>하세요. <button class="sm" id="m-reveal">녹음 파일 위치 열기</button> (Finder에서 파일을 Gemini 창으로 끌어다 놓기)</li>` : '';
  modal(`
    <h2>${titles[op] || 'AI 작업'}</h2>
    <div class="info-box"><ol>
      <li>아래 <b>프롬프트 복사</b> → Gemini(gemini.google.com) 또는 ChatGPT 새 대화에 붙여넣기</li>
      ${audioStep}
      <li>AI의 답변 전체를 복사해서 아래 <b>결과 붙여넣기</b> 칸에 넣고 <b>적용</b></li>
    </ol></div>
    <div class="section-title" style="margin-top:14px"><h3>프롬프트</h3><button class="primary sm" id="m-copy">프롬프트 복사</button></div>
    <textarea class="prompt-box" readonly>${esc(res.prompt)}</textarea>
    <h3 style="margin-top:14px">결과 붙여넣기</h3>
    <textarea id="m-result" rows="9" placeholder="AI 답변을 여기에 붙여넣으세요"></textarea>
    <div class="modal-actions">
      <button id="m-cancel">닫기</button>
      <button class="primary" id="m-apply">적용</button>
    </div>`, box => {
    $('#m-copy', box).onclick = () => copyText(res.prompt);
    $('#m-cancel', box).onclick = closeModal;
    if ($('#m-reveal', box)) $('#m-reveal', box).onclick = () => api('/api/recordings/reveal', { id: params.recording_id });
    $('#m-apply', box).onclick = async () => {
      const text = $('#m-result', box).value.trim();
      if (!text) return toast('결과를 붙여넣으세요', true);
      const r = await api('/api/ai/apply', { op, params, text });
      closeModal();
      if (r.matched !== undefined) toast(`학생 배정 ${r.matched}건, 미배정 ${r.unmatched}건`);
      else toast('적용했습니다');
      if (onDone) onDone(r);
    };
  });
}

// ───────────────────────── 작업 진행 표시 ─────────────────────────

let pollTimer;
async function pollJobs(force) {
  clearTimeout(pollTimer);
  try {
    const d = await api('/api/jobs', undefined, { silent: true });
    const prevActive = state.jobsActive;
    state.jobsActive = d.active;
    const fab = $('#jobs-fab');
    const recent = d.jobs.filter(j => j.status !== '완료' || isRecent(j.finished_at));
    if (d.active) {
      fab.innerHTML = `<span class="spinner"></span> AI 작업 ${d.active}개 진행 중`;
      fab.className = 'jobs-fab';
    } else if (d.jobs.length) {
      const failed = d.jobs.filter(j => j.status === '실패' && isRecent(j.finished_at)).length;
      fab.innerHTML = failed ? `⚠︎ 실패한 작업 ${failed}개` : 'AI 작업 기록';
      fab.className = 'jobs-fab idle';
    } else fab.className = 'jobs-fab hidden';
    renderJobsPanel(d.jobs);
    const ids = d.jobs.filter(j => j.status === '완료' || j.status === '실패').map(j => j.id).join(',');
    if (state.lastJobIds && ids !== state.lastJobIds) {
      const newest = d.jobs.find(j => (j.status === '완료' || j.status === '실패') && !state.lastJobIds.split(',').includes(String(j.id)));
      if (newest) toast(newest.status === '완료' ? `완료: ${newest.label}` : `실패: ${newest.label} — ${newest.message}`, newest.status === '실패');
      refreshCurrent();
    }
    state.lastJobIds = ids;
    if (prevActive && !d.active) refreshCurrent();
  } catch (e) { /* 서버 재시작 중 */ }
  pollTimer = setTimeout(pollJobs, state.jobsActive ? 2500 : 8000);
}
function isRecent(ts) { return ts && (Date.now() - new Date(ts.replace(' ', 'T')).getTime()) < 30 * 60 * 1000; }

function renderJobsPanel(jobs) {
  const p = $('#jobs-panel');
  p.innerHTML = `<div class="section-title"><h3>AI 작업</h3><span>
      <button class="sm" id="jp-cancel">대기 작업 취소</button> <button class="sm" id="jp-clear">기록 지우기</button></span></div>` +
    (jobs.length ? jobs.map(j => `<div class="job"><div><span class="badge ${{ '완료': 'green', '실패': 'red', '진행중': 'blue' }[j.status] || ''}">${esc(j.status)}</span> ${esc(j.label)}</div>
      ${j.message ? `<div class="msg">${esc(j.message)}</div>` : ''}<div class="msg">${esc(fmtDate(j.created_at))}</div></div>`).join('')
      : '<p class="muted">작업이 없습니다.</p>');
  $('#jp-clear', p).onclick = async () => { await api('/api/jobs/clear', {}); pollJobs(); };
  $('#jp-cancel', p).onclick = async () => { await api('/api/jobs/cancel', {}); pollJobs(); };
}
$('#jobs-fab').onclick = () => $('#jobs-panel').classList.toggle('hidden');

let refreshPending = false;
function refreshCurrent() {
  // 사용자가 입력 중이면 화면을 새로 그리지 않음
  const ae = document.activeElement;
  if (ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT') && view.contains(ae) && ae.dataset.dirty) { refreshPending = true; return; }
  if (!$('#modal').classList.contains('hidden')) { refreshPending = true; return; }
  router(true);
}

// ───────────────────────── 라우터 ─────────────────────────

async function router(soft) {
  const hash = location.hash.replace(/^#/, '') || '/';
  const parts = hash.split('/').filter(Boolean);
  const nav = { '': 'dashboard', recordings: 'recordings', recording: 'recordings', classes: 'classes', class: 'classes',
    student: 'classes', drafts: 'drafts', settings: 'settings', prompts: 'prompts' }[parts[0] || ''];
  $$('.sidebar nav a').forEach(a => a.classList.toggle('active', a.dataset.nav === nav));
  const scroll = soft ? window.scrollY : 0;
  try {
    await loadClasses();
    switch (parts[0]) {
      case undefined: await viewDashboard(); break;
      case 'recordings': await viewRecordings(parts[1]); break;
      case 'recording': await viewRecording(parts[1]); break;
      case 'classes': await viewClasses(); break;
      case 'class': await viewClass(parts[1]); break;
      case 'student': await viewStudent(parts[1], parts[2]); break;
      case 'drafts': await viewDrafts(parts[1], parts[2]); break;
      case 'settings': await viewSettings(parts[1]); break;
      case 'prompts': await viewPrompts(); break;
      default: await viewDashboard();
    }
  } catch (e) {
    view.innerHTML = `<div class="error-box">${esc(e.message)}</div>`;
  }
  window.scrollTo(0, scroll);
  // 입력 감지: 자동 새로고침이 입력을 지우지 않도록
  $$('textarea, input', view).forEach(el => el.addEventListener('input', () => { el.dataset.dirty = '1'; }));
}
window.addEventListener('hashchange', () => { closeModal(); router(false); });

// ───────────────────────── 대시보드 ─────────────────────────

async function viewDashboard() {
  const d = await api('/api/dashboard');
  const t = d.totals;
  if (!t.classes) {
    view.innerHTML = `<div class="empty card">
      <h2>쓰담에 오신 것을 환영합니다</h2>
      <p>수업 중 녹음한 학생 평가와 상담 기록을 학생별로 모아 세특 초안까지 만들어 주는 도구입니다.</p>
      <div class="steps">
        <div class="card"><b>1</b><h3>설정</h3><p class="muted small">Gemini API 키를 넣거나, 키 없이 '수동 모드'를 선택합니다.</p><a href="#/settings">설정 열기 →</a></div>
        <div class="card"><b>2</b><h3>학급·명단 등록</h3><p class="muted small">학급을 만들고 NEIS 명단의 '번호, 이름'을 복사해 붙여넣습니다.</p><a href="#/classes">학급 만들기 →</a></div>
        <div class="card"><b>3</b><h3>녹음 올리기</h3><p class="muted small">아이폰 음성메모를 iCloud '쓰담 녹음' 폴더에 저장하거나 끌어다 놓습니다.</p><a href="#/recordings">녹음함 →</a></div>
        <div class="card"><b>4</b><h3>세특 초안</h3><p class="muted small">학생별로 쌓인 관찰기록으로 초안을 만들고 구글시트로 보냅니다.</p><a href="#/drafts">세특 초안 →</a></div>
      </div></div>`;
    return;
  }
  const pct = (a, b) => b ? Math.round(a / b * 100) : 0;
  view.innerHTML = `
    <div class="page-head"><div><h1>대시보드</h1><div class="muted">${new Date().toLocaleDateString('ko-KR', { year: 'numeric', month: 'long', day: 'numeric', weekday: 'long' })}</div></div>
      <div class="actions"><button id="dash-xlsx">전체 엑셀로 저장</button><a class="btn" href="#/recordings">+ 녹음 올리기</a></div></div>
    <div id="wh-banner"></div>
    <div class="stats">
      <div class="stat"><div class="label">학생</div><div class="value">${t.students}</div><div class="sub">${t.classes}개 학급</div></div>
      <div class="stat"><div class="label">녹음·기록</div><div class="value">${t.recordings}</div><div class="sub">${t.pending_review ? `<a href="#/recordings">확인 필요 ${t.pending_review}건</a>` : '모두 처리됨'}</div></div>
      <div class="stat"><div class="label">관찰기록</div><div class="value">${t.notes}</div><div class="sub">학생당 평균 ${t.students ? (t.notes / t.students).toFixed(1) : 0}건</div></div>
      <div class="stat"><div class="label">기록 있는 학생</div><div class="value">${pct(t.with_notes, t.students)}%</div><div class="sub">${t.with_notes} / ${t.students}명</div></div>
      <div class="stat"><div class="label">세특 초안</div><div class="value">${pct(t.drafted, t.students)}%</div><div class="sub">확정 ${t.finalized}명</div></div>
    </div>
    <div class="grid grid-2">
      <div class="card">
        <div class="section-title"><h2>학급별 진행</h2><div class="legend"><span><i style="background:var(--accent)"></i>기록 있음</span><span><i style="background:var(--green)"></i>초안 작성</span></div></div>
        <div class="table-wrap" style="border:none"><table>
          <thead><tr><th>학급</th><th class="right">학생</th><th class="right">기록</th><th style="width:38%">진행률</th></tr></thead>
          <tbody>${d.classes.map(c => `<tr class="clickable" data-href="#/drafts/${c.id}">
            <td><b>${esc(c.label)}</b><div class="small muted">${c.year}년 ${c.semester}학기 · 녹음 ${c.recordings}</div></td>
            <td class="num">${c.students}</td><td class="num">${c.notes}</td>
            <td><div class="bar" title="기록 있는 학생 ${c.with_notes}명"><div class="b1" style="width:${pct(c.with_notes, c.students)}%"></div></div>
                <div class="bar" style="margin-top:4px" title="초안 작성 ${c.drafted}명"><div class="b2" style="width:${pct(c.drafted, c.students)}%"></div></div>
                <div class="small muted">기록 ${c.with_notes}/${c.students} · 초안 ${c.drafted}/${c.students} · 확정 ${c.finalized}</div></td></tr>`).join('')}
          </tbody></table></div>
      </div>
      <div class="card chart">
        <div class="section-title"><h2>주간 관찰기록</h2><div class="legend"><span><i style="background:var(--accent)"></i>수업</span><span><i style="background:var(--violet)"></i>상담</span></div></div>
        ${weeklyChart(d.weeks)}
        <h3 style="margin-top:16px">영역 분포</h3>
        <div class="chips">${d.categories.map(c => `<span class="badge blue">${esc(c.category)} ${c.n}</span>`).join('') || '<span class="muted small">아직 기록이 없습니다</span>'}</div>
      </div>
      <div class="card">
        <h2>기록이 부족한 학생</h2>
        <p class="help" style="margin-top:-6px;margin-bottom:10px">다음 수업에서 관찰해 보면 좋은 학생들입니다.</p>
        <table><tbody>${d.needy.map(s => `<tr class="clickable" data-href="#/student/${s.id}">
          <td>${esc(s.label)}</td><td>${s.number}번 <b>${esc(s.name)}</b></td>
          <td class="right"><span class="badge ${s.notes ? 'amber' : 'red'}">기록 ${s.notes}건</span></td>
          <td class="small muted nowrap">${s.last_date ? '최근 ' + esc(s.last_date) : ''}</td></tr>`).join('')}</tbody></table>
      </div>
      <div class="card">
        <div class="section-title"><h2>최근 녹음</h2><a href="#/recordings" class="small">전체 보기</a></div>
        <table><tbody>${d.recent.map(r => `<tr class="clickable" data-href="#/recording/${r.id}">
          <td class="small muted nowrap">${esc(fmtDate(r.recorded_at))}</td><td>${kindBadge(r.kind)} ${esc(r.title)}<div class="small muted">${esc(r.label)}</div></td>
          <td class="right nowrap">${badge(r.status)}<div class="small muted">학생기록 ${r.notes}</div></td></tr>`).join('') || '<tr><td class="muted">아직 녹음이 없습니다</td></tr>'}</tbody></table>
      </div>
    </div>`;
  bindRowLinks();
  $('#dash-xlsx').onclick = () => exportXlsx(null);
  whisperBanner($('#wh-banner'));
}

function weeklyChart(weeks) {
  const W = 560, H = 190, pad = { l: 28, r: 8, t: 10, b: 24 };
  const max = Math.max(4, ...weeks.map(w => w['수업'] + w['상담']));
  const step = Math.ceil(max / 4);
  const top = step * 4;
  const bw = (W - pad.l - pad.r) / weeks.length;
  const y = v => pad.t + (H - pad.t - pad.b) * (1 - v / top);
  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="주간 관찰기록 수">`;
  for (let i = 0; i <= 4; i++) {
    const v = step * i;
    s += `<line x1="${pad.l}" x2="${W - pad.r}" y1="${y(v)}" y2="${y(v)}" stroke="var(--line)" stroke-width="1"/>`;
    s += `<text x="${pad.l - 6}" y="${y(v) + 4}" text-anchor="end">${v}</text>`;
  }
  weeks.forEach((w, i) => {
    const x = pad.l + i * bw + bw * 0.18, bwi = bw * 0.64;
    const a = w['수업'], b = w['상담'];
    if (a) s += `<rect x="${x}" y="${y(a)}" width="${bwi}" height="${y(0) - y(a)}" rx="2" fill="var(--accent)"><title>${w.label} 주 수업 ${a}건</title></rect>`;
    if (b) s += `<rect x="${x}" y="${y(a + b)}" width="${bwi}" height="${y(a) - y(a + b)}" rx="2" fill="var(--violet)"><title>${w.label} 주 상담 ${b}건</title></rect>`;
    if (i % 2 === weeks.length % 2 || i === weeks.length - 1) s += `<text x="${x + bwi / 2}" y="${H - 6}" text-anchor="middle">${w.label}</text>`;
  });
  return s + '</svg>';
}

function bindRowLinks(root) {
  $$('tr[data-href]', root).forEach(tr => tr.addEventListener('click', e => {
    if (e.target.closest('button, a, input, select, textarea')) return;
    location.hash = tr.dataset.href;
  }));
}

// ───────────────────────── 녹음함 ─────────────────────────

async function viewRecordings(classFilter) {
  const [recs, settings] = await Promise.all([
    api('/api/recordings' + (classFilter ? '?class_id=' + classFilter : '')), api('/api/settings')]);
  state.settings = settings;
  const isApi = settings.mode === 'api' && settings.has_key;
  view.innerHTML = `
    <div class="page-head"><div><h1>녹음함</h1><div class="muted">수업 평가·상담 녹음을 보관하고, 전사·학생별 분리를 진행합니다.</div></div>
      <div class="actions"><a class="btn" href="#/settings/import">가져오기 설정</a><button class="primary" id="btn-scan">아이폰 기록 지금 가져오기</button></div></div>
    <div id="src-line" class="help" style="margin:-10px 0 14px"></div>
    <div id="wh-banner"></div>
    <div class="card">
      <div class="tabs"><button class="on" data-tab="audio">녹음 파일 올리기</button><button data-tab="paste">전사문 붙여넣기</button></div>
      <div class="row" style="margin-bottom:12px">
        <label class="field"><span>학급</span><select id="up-class">${classOptions('', '자동 (파일명·내용에서 추정)')}</select></label>
        <label class="field shrink" style="min-width:120px"><span>유형</span><select id="up-kind"><option value="">자동</option><option>수업</option><option>상담</option></select></label>
        <label class="field"><span>녹음 일시 (비우면 파일 시각)</span><input type="datetime-local" id="up-date"></label>
        <label class="field"><span>제목 (선택)</span><input id="up-title" placeholder="예: 3교시 토론 수업"></label>
      </div>
      <div data-pane="audio">
        <div class="dropzone" id="drop"><strong>여기에 녹음 파일을 끌어다 놓거나 클릭해서 선택</strong>m4a, mp3, wav 등 · 여러 개 가능 · 텍스트(.txt) 전사본도 가능</div>
        <input type="file" id="file" multiple accept="audio/*,.m4a,.txt" class="hidden">
        <label class="check" style="margin-top:10px"><input type="checkbox" id="up-auto" ${isApi ? 'checked' : 'disabled'}> 올린 뒤 자동으로 전사 → 학생별 분리 ${isApi ? '' : '<span class="muted small">(API 모드에서만 가능)</span>'}</label>
      </div>
      <div data-pane="paste" class="hidden">
        <textarea id="paste-text" rows="8" placeholder="클로바노트 등 다른 앱에서 받은 전사문, 또는 직접 정리한 메모를 붙여넣으세요.&#10;예) 3번 김민수 오늘 발표에서 근거 자료를 3가지 제시하며 논리적으로 설명함. 5번 이서연은 모둠 토론에서..."></textarea>
        <div class="row" style="margin-top:10px"><label class="check shrink"><input type="checkbox" id="paste-auto" ${isApi ? 'checked' : ''}> 저장 후 바로 학생별 분리</label><span></span>
          <button class="primary shrink" id="paste-save">저장</button></div>
      </div>
    </div>
    <div class="card">
      <div class="section-title"><h2>보관된 녹음 ${recs.recordings.length}건</h2>
        <select id="rec-filter" style="width:auto">${classOptions(classFilter || '', '전체 학급')}</select></div>
      ${recs.recordings.length ? `<div class="table-wrap"><table>
        <thead><tr><th>일시</th><th>유형</th><th>제목</th><th>학급</th><th>상태</th><th class="right">학생기록</th></tr></thead>
        <tbody>${recs.recordings.map(r => `<tr class="clickable" data-href="#/recording/${r.id}">
          <td class="nowrap small">${esc(fmtDate(r.recorded_at))}</td><td>${kindBadge(r.kind)}</td>
          <td>${esc(r.title)}${r.has_audio ? ' <span class="muted small">🎙</span>' : ''}${r.error ? `<div class="small" style="color:var(--red)">${esc(r.error.slice(0, 80))}</div>` : ''}</td>
          <td class="small">${esc(r.label)}</td><td>${badge(r.status)}</td>
          <td class="num">${r.notes}${r.unmatched ? ` <span class="badge amber">미배정 ${r.unmatched}</span>` : ''}</td></tr>`).join('')}</tbody></table></div>`
      : '<p class="muted">아직 보관된 녹음이 없습니다.</p>'}
      <p class="help">수신 폴더: <code>${esc(settings.inbox_dir)}</code> ${settings.inbox_exists ? '' : '<span class="badge amber">폴더 없음 — 설정에서 만들기</span>'} · 20초마다 자동 확인</p>
    </div>`;
  bindRowLinks();
  $$('.tabs button').forEach(b => b.onclick = () => {
    $$('.tabs button').forEach(x => x.classList.toggle('on', x === b));
    $$('[data-pane]').forEach(p => p.classList.toggle('hidden', p.dataset.pane !== b.dataset.tab));
  });
  whisperBanner($('#wh-banner'));
  $('#rec-filter').onchange = e => { location.hash = '#/recordings' + (e.target.value ? '/' + e.target.value : ''); };
  $('#btn-scan').onclick = async () => {
    $('#btn-scan').disabled = true; $('#btn-scan').textContent = '가져오는 중…';
    try { const r = await api('/api/inbox/scan', {}); toast(r.message, r.errors && r.errors.length); }
    finally { router(true); }
  };
  api('/api/sources', undefined, { silent: true }).then(src => {
    const parts = [];
    if (src.voicememo.enabled) parts.push(`음성메모 자동 ${src.voicememo.access === 'ok' ? '<span class="ok-text">켜짐</span>' : '<span class="bad-text">권한 필요</span>'}`);
    if (src.notes.enabled) parts.push(`메모 앱 '${esc(src.notes.folder)}' 폴더 <span class="ok-text">켜짐</span>`);
    parts.push(`iCloud 쓰담 녹음 폴더 ${src.inbox.exists ? '<span class="ok-text">켜짐</span>' : '없음'}`);
    $('#src-line').innerHTML = '자동 가져오기: ' + parts.join(' · ') + (src.voicememo.enabled || src.notes.enabled ? '' : ' — <a href="#/settings/import">음성메모·메모 앱 자동 가져오기 켜기</a>');
  }).catch(() => {});
  const drop = $('#drop'), file = $('#file');
  drop.onclick = () => file.click();
  drop.ondragover = e => { e.preventDefault(); drop.classList.add('over'); };
  drop.ondragleave = () => drop.classList.remove('over');
  drop.ondrop = e => { e.preventDefault(); drop.classList.remove('over'); uploadFiles(e.dataTransfer.files); };
  file.onchange = () => uploadFiles(file.files);
  $('#paste-save').onclick = async () => {
    const text = $('#paste-text').value.trim();
    if (!text) return toast('전사문을 붙여넣으세요', true);
    const r = await api('/api/recordings/paste', {
      transcript: text, class_id: $('#up-class').value || null, kind: $('#up-kind').value || '수업',
      title: $('#up-title').value || '붙여넣은 기록', recorded_at: ($('#up-date').value || nowLocal()).replace('T', ' '),
    });
    if ($('#paste-auto').checked) {
      location.hash = '#/recording/' + r.id;
      setTimeout(() => runAI('segment', { recording_id: r.id }, '#' + r.id, () => router(true)), 300);
    } else location.hash = '#/recording/' + r.id;
  };
}

async function uploadFiles(files) {
  if (!files || !files.length) return;
  const q = new URLSearchParams({
    class_id: $('#up-class').value, kind: $('#up-kind').value, title: files.length === 1 ? $('#up-title').value : '',
    recorded_at: ($('#up-date').value || '').replace('T', ' '), auto: $('#up-auto').checked ? '1' : '0',
  });
  let ok = 0;
  for (const f of files) {
    toast(`올리는 중… ${f.name}`);
    q.set('filename', f.name);
    try { await api('/api/recordings/upload?' + q.toString(), f); ok++; } catch (e) { /* toast 표시됨 */ }
  }
  toast(`${ok}개 파일을 보관했습니다`);
  pollJobs(true);
  router(true);
}

// ───────────────────────── 녹음 상세 ─────────────────────────

async function viewRecording(id) {
  const d = await api('/api/recordings/' + id);
  const r = d.recording;
  const byStudent = {};
  d.notes.forEach(n => { (byStudent[n.student_id] = byStudent[n.student_id] || { name: n.name, number: n.number, items: [] }).items.push(n); });
  const studentOpts = sel => '<option value="">학생 선택…</option>' + d.students.map(s => `<option value="${s.id}" ${s.id === sel ? 'selected' : ''}>${s.number}번 ${esc(s.name)}</option>`).join('');
  const busy = ['대기중', '전사중', '분리중'].includes(r.status);
  view.innerHTML = `
    <div class="page-head"><div><a href="#/recordings" class="small">← 녹음함</a><h1>${esc(r.title || '녹음')}</h1>
      <div>${kindBadge(r.kind)} ${badge(r.status)} <span class="muted small">${esc(fmtDate(r.recorded_at))} · ${esc(r.original_name || '')}</span></div></div>
      <div class="actions">
        ${r.has_audio ? `<button id="b-reveal">Finder에서 보기</button>` : ''}
        <button class="danger" id="b-del">삭제</button></div></div>
    ${r.error ? `<div class="error-box">${esc(r.error)}</div>` : ''}
    <div class="split">
      <div class="stack">
        <div class="card">
          <h2>기본 정보</h2>
          <div class="row">
            <label class="field"><span>학급</span><select id="r-class">${classOptions(r.class_id, true)}</select></label>
            <label class="field shrink" style="min-width:110px"><span>유형</span><select id="r-kind"><option ${r.kind === '수업' ? 'selected' : ''}>수업</option><option ${r.kind === '상담' ? 'selected' : ''}>상담</option></select></label>
          </div>
          <div class="row" style="margin-top:10px">
            <label class="field"><span>제목</span><input id="r-title" value="${esc(r.title)}"></label>
            <label class="field"><span>일시</span><input type="datetime-local" id="r-date" value="${esc((r.recorded_at || '').replace(' ', 'T').slice(0, 16))}"></label>
            <button class="shrink" id="r-save">저장</button>
          </div>
          ${r.has_audio ? `<audio controls preload="none" src="/audio/${r.id}"></audio>` : ''}
        </div>
        <div class="card">
          <div class="section-title"><h2>전사문</h2>
            <span>${r.has_audio ? `<button class="${r.transcript ? '' : 'primary'}" id="b-trans" ${busy ? 'disabled' : ''}>${r.transcript ? '다시 받아쓰기' : '받아쓰기 시작'}</button>` : ''}</span></div>
          <textarea id="r-transcript" rows="16" placeholder="${r.has_audio ? 'AI 전사 결과가 여기에 표시됩니다. 다른 앱의 전사문을 직접 붙여넣어도 됩니다.' : '전사문'}">${esc(r.transcript)}</textarea>
          <div class="row" style="margin-top:8px"><span class="muted small">${(r.transcript || '').length.toLocaleString()}자 · 이름 오인식은 여기서 고친 뒤 다시 분리하면 정확해집니다</span>
            <button class="shrink" id="b-save-trans">전사문 저장</button></div>
        </div>
      </div>
      <div class="stack">
        <div class="card">
          <div class="section-title"><h2>학생별 분리 결과</h2>
            <span><button class="primary" id="b-seg" ${busy || !r.transcript ? 'disabled' : ''}>${d.notes.length ? 'AI로 다시 분리' : 'AI로 학생별 분리'}</button>
            <button id="b-rule" ${!r.transcript ? 'disabled' : ''} title="AI 없이 이름이 언급된 위치로 나눕니다">이름 기준 분리(AI 없이)</button></span></div>
          ${!r.class_id ? '<div class="warn">학급을 지정해야 학생 명단과 대조할 수 있습니다. (AI 분리 시 전사문에서 학급을 찾으면 자동 지정)</div>' : ''}
          ${d.notes.length ? '' : '<p class="muted">아직 분리된 내용이 없습니다.</p>'}
          ${Object.entries(byStudent).map(([sid, g]) => `<div class="student-group">
            <h3><a href="#/student/${sid}">${g.number}번 ${esc(g.name)}</a> <span class="badge">${g.items.length}건</span></h3>
            ${g.items.map(n => `<div class="note" data-note="${n.id}">
              <div class="meta"><span class="badge blue">${esc(n.category || '기타')}</span>
                <span class="tools">${d.areas.length > 1 ? `<select class="n-area" style="width:auto;padding:2px 6px;font-size:12px">${areaOptions(d.areas, n.area_eff)}</select>` : ''}<select class="n-move" style="width:auto;padding:2px 6px;font-size:12px">${studentOpts(n.student_id)}</select>
                <button class="sm n-edit">수정</button><button class="sm danger n-del">삭제</button></span></div>
              <div class="content">${esc(n.content)}</div>
              ${n.evidence ? `<div class="evidence">${esc(n.evidence)}</div>` : ''}</div>`).join('')}
          </div>`).join('')}
        </div>
        ${d.unmatched.length ? `<div class="card">
          <h2>미배정 언급 ${d.unmatched.length}건</h2>
          <p class="help" style="margin-top:-6px">명단과 일치하지 않은 이름입니다. 학생을 골라 배정하거나 삭제하세요. 자주 틀리는 이름은 학생 '별칭'에 추가해 두면 다음부터 자동 배정됩니다.</p>
          ${d.unmatched.map(u => `<div class="note" data-un="${u.id}">
            <div class="meta"><span class="badge amber">들린 이름: ${esc(u.name_heard || '?')}</span>
              <span class="tools"><select class="u-assign" style="width:auto;padding:2px 6px;font-size:12px">${studentOpts(null)}</select>
              <button class="sm danger u-del">삭제</button></span></div>
            <div class="content">${esc(u.content)}</div>${u.evidence ? `<div class="evidence">${esc(u.evidence)}</div>` : ''}</div>`).join('')}
        </div>` : ''}
        ${r.status === '확인필요' && !d.unmatched.length ? `<button class="primary" id="b-done">확인 완료로 표시</button>` : ''}
      </div>
    </div>`;

  const reload = () => router(true);
  if ($('#b-reveal')) $('#b-reveal').onclick = () => api('/api/recordings/reveal', { id: r.id });
  $('#b-del').onclick = async () => {
    if (!confirmBox('이 녹음 기록을 삭제할까요?\n(이 녹음에서 나온 학생 관찰기록은 남겨둡니다)')) return;
    const delAudio = r.has_audio && confirmBox('보관된 녹음 파일도 함께 지울까요?\n[확인] 파일도 삭제  [취소] 파일은 남김');
    await api('/api/recordings/delete', { id: r.id, delete_audio: delAudio });
    location.hash = '#/recordings';
  };
  $('#r-save').onclick = async () => {
    await api('/api/recordings/update', { id: r.id, class_id: $('#r-class').value || null, kind: $('#r-kind').value,
      title: $('#r-title').value, recorded_at: $('#r-date').value.replace('T', ' ') });
    toast('저장했습니다'); reload();
  };
  $('#r-class').onchange = $('#r-save').onclick;
  $('#b-save-trans').onclick = async () => {
    await api('/api/recordings/update', { id: r.id, transcript: $('#r-transcript').value });
    toast('전사문을 저장했습니다'); reload();
  };
  if ($('#b-trans')) $('#b-trans').onclick = () => runAI('transcribe', { recording_id: r.id, chain: false }, '#' + r.id, reload);
  $('#b-seg').onclick = async () => {
    if (d.notes.length && !confirmBox('다시 분리하면 이 녹음에서 나온 기존 학생기록(수정 내용 포함)이 새 결과로 바뀝니다. 계속할까요?')) return;
    if ($('#r-transcript').dataset.dirty) await api('/api/recordings/update', { id: r.id, transcript: $('#r-transcript').value });
    runAI('segment', { recording_id: r.id }, '#' + r.id, reload);
  };
  $('#b-rule').onclick = async () => {
    if (d.notes.length && !confirmBox('기존 분리 결과가 바뀝니다. 계속할까요?')) return;
    if ($('#r-transcript').dataset.dirty) await api('/api/recordings/update', { id: r.id, transcript: $('#r-transcript').value });
    const res = await api('/api/recordings/rule_segment', { id: r.id });
    toast(`${res.matched}개 구간으로 나눴습니다. 내용을 확인·수정하세요.`); reload();
  };
  if ($('#b-done')) $('#b-done').onclick = async () => { await api('/api/recordings/mark_done', { id: r.id }); reload(); };
  $$('[data-note]').forEach(el => {
    const nid = +el.dataset.note, n = d.notes.find(x => x.id === nid);
    $('.n-del', el).onclick = async () => { await api('/api/notes/delete', { id: nid }); reload(); };
    $('.n-move', el).onchange = async e => {
      if (!e.target.value) return;
      await api('/api/notes/save', { ...n, student_id: +e.target.value, use_in_draft: !!n.use_in_draft }); toast('학생을 변경했습니다'); reload();
    };
    $('.n-edit', el).onclick = () => editNoteModal(n, reload, n.student_id, d.areas);
    if ($('.n-area', el)) $('.n-area', el).onchange = async e => { await api('/api/notes/save', { ...n, area: e.target.value, use_in_draft: !!n.use_in_draft }); toast('기재 영역을 바꿨습니다'); };
  });
  $$('[data-un]').forEach(el => {
    const uid = +el.dataset.un;
    $('.u-del', el).onclick = async () => { await api('/api/unmatched/delete', { id: uid }); reload(); };
    $('.u-assign', el).onchange = async e => {
      if (!e.target.value) return;
      await api('/api/unmatched/assign', { id: uid, student_id: +e.target.value }); toast('배정했습니다'); reload();
    };
  });
}

function areaOptions(areas, sel) {
  return areas.map(a => `<option value="${a.id}" ${a.id === sel ? 'selected' : ''}>${esc(a.name)}</option>`).join('');
}

function editNoteModal(n, onSaved, studentId, areas) {
  const isNew = !n;
  areas = areas || [];
  n = n || { date: today(), kind: '수업', category: '', content: '', use_in_draft: 1, student_id: studentId, area: '' };
  const cur = n.area || n.area_eff || (areas[0] && areas[0].id) || '';
  modal(`<h2>${isNew ? '관찰기록 추가' : '관찰기록 수정'}</h2>
    <div class="row">
      <label class="field"><span>날짜</span><input type="date" id="e-date" value="${esc(n.date || today())}"></label>
      <label class="field"><span>유형</span><select id="e-kind"><option ${n.kind === '수업' ? 'selected' : ''}>수업</option><option ${n.kind === '상담' ? 'selected' : ''}>상담</option></select></label>
      ${areas.length > 1 ? `<label class="field"><span>기재 영역</span><select id="e-area">${areaOptions(areas, cur)}</select></label>` : ''}
      <label class="field"><span>분류</span><select id="e-cat">${CATEGORIES.map(c => `<option ${c === n.category ? 'selected' : ''}>${c}</option>`).join('')}</select></label>
    </div>
    <label class="field" style="margin-top:10px"><span>내용</span><textarea id="e-content" rows="6">${esc(n.content)}</textarea></label>
    <label class="check" style="margin-top:8px"><input type="checkbox" id="e-use" ${n.use_in_draft ? 'checked' : ''}> 초안 생성에 사용</label>
    <div class="modal-actions"><button id="e-cancel">취소</button><button class="primary" id="e-save">저장</button></div>`, box => {
    $('#e-content', box).focus();
    $('#e-cancel', box).onclick = closeModal;
    $('#e-save', box).onclick = async () => {
      await api('/api/notes/save', { id: n.id, student_id: n.student_id, recording_id: n.recording_id, date: $('#e-date', box).value,
        kind: $('#e-kind', box).value, category: $('#e-cat', box).value, content: $('#e-content', box).value,
        use_in_draft: $('#e-use', box).checked, area: $('#e-area', box) ? $('#e-area', box).value : (n.area || '') });
      closeModal(); toast('저장했습니다'); onSaved && onSaved();
    };
  });
}

// ───────────────────────── 학급 ─────────────────────────

const KIND_HELP = {
  '교과': '수업하는 반 (과목별). 교과 세특을 씁니다.',
  '담임': '담임 학급. 행동특성 및 종합의견, 자율·자치, 진로활동, 개인별 세특을 씁니다.',
  '동아리': '여러 반 학생이 모인 동아리. 명단은 학번(예: 20315)으로 넣으세요.',
  '기타': '방과후·모둠 등. 모든 영역을 쓸 수 있습니다.',
};

function classFormFields(c) {
  const kind = c.kind || '교과';
  const named = kind === '동아리' || kind === '기타';
  return `
    <label class="field shrink" style="min-width:110px"><span>유형</span><select id="c-kind">${['교과', '담임', '동아리', '기타'].map(k => `<option ${k === kind ? 'selected' : ''}>${k}</option>`).join('')}</select></label>
    <label class="field"><span>연도</span><input id="c-year" type="number" value="${c.year}"></label>
    <label class="field"><span>학기</span><select id="c-sem"><option value="1" ${c.semester == 1 ? 'selected' : ''}>1학기</option><option value="2" ${c.semester == 2 ? 'selected' : ''}>2학기</option></select></label>
    <label class="field ${named ? 'hidden' : ''}" data-f="grade"><span>학년</span><input id="c-grade" type="number" min="1" max="6" value="${c.grade ?? ''}" placeholder="2"></label>
    <label class="field ${named ? 'hidden' : ''}" data-f="no"><span>반</span><input id="c-no" type="number" min="1" value="${c.class_no ?? ''}" placeholder="3"></label>
    <label class="field ${kind === '담임' ? 'hidden' : ''}" data-f="subj"><span id="c-subj-l">${named ? (kind === '동아리' ? '동아리 이름' : '이름') : '과목'}</span><input id="c-subj" value="${esc(c.subject || '')}" placeholder="${named ? '예: 로봇탐구반' : '예: 국어'}"></label>`;
}

function bindClassForm() {
  const upd = () => {
    const k = $('#c-kind').value, named = k === '동아리' || k === '기타';
    $('[data-f=grade]').classList.toggle('hidden', named);
    $('[data-f=no]').classList.toggle('hidden', named);
    $('[data-f=subj]').classList.toggle('hidden', k === '담임');
    $('#c-subj-l').textContent = named ? (k === '동아리' ? '동아리 이름' : '이름') : '과목';
    $('#c-kind-help').textContent = KIND_HELP[k];
  };
  $('#c-kind').onchange = upd; upd();
}

function classFormValues() {
  return { kind: $('#c-kind').value, year: $('#c-year').value, semester: $('#c-sem').value, grade: $('#c-grade').value,
    class_no: $('#c-no').value, subject: $('#c-subj').value };
}

async function viewClasses() {
  const y = new Date().getFullYear(), sem = (new Date().getMonth() + 1) >= 8 ? 2 : 1;
  view.innerHTML = `
    <div class="page-head"><div><h1>학급·학생</h1><div class="muted">수업하는 반, 담임 학급, 동아리를 관리합니다. 과목이 다르면 같은 반도 따로 만드세요.</div></div></div>
    <div class="card">
      <h2>새 학급</h2>
      <div class="row">${classFormFields({ year: y, semester: sem, kind: '교과' })}
        <button class="primary shrink" id="c-add">추가</button>
      </div>
      <p class="help" id="c-kind-help"></p>
    </div>
    <div class="card">
      <h2>학급 목록</h2>
      ${state.classes.length ? `<div class="table-wrap"><table><thead><tr><th>학급</th><th>유형</th><th>학기</th><th class="right">학생 수</th><th></th></tr></thead><tbody>
        ${state.classes.map(c => `<tr class="clickable" data-href="#/class/${c.id}"><td><b>${esc(c.label)}</b></td><td><span class="badge">${esc(c.kind || '교과')}</span></td><td>${c.year}년 ${c.semester}학기</td>
          <td class="num">${c.students}</td><td class="right"><a href="#/drafts/${c.id}" class="small">초안 →</a></td></tr>`).join('')}
      </tbody></table></div>` : '<p class="muted">아직 학급이 없습니다.</p>'}
    </div>`;
  bindRowLinks();
  bindClassForm();
  $('#c-add').onclick = async () => {
    const r = await api('/api/classes/save', classFormValues());
    toast('만들었습니다. 명단을 붙여넣으세요.');
    location.hash = '#/class/' + r.id;
  };
}

async function viewClass(id) {
  const d = await api('/api/classes/' + id);
  const c = d.class;
  const club = c.kind === '동아리';
  view.innerHTML = `
    <div class="page-head"><div><a href="#/classes" class="small">← 학급 목록</a><h1>${esc(c.label)}</h1><div class="muted">${esc(c.kind || '교과')} · ${c.year}년 ${c.semester}학기 · 학생 ${d.students.length}명 · 기재 영역: ${d.areas.map(a => esc(a.name)).join(', ')}</div></div>
      <div class="actions"><a class="btn" href="#/recordings/${c.id}">이 학급 녹음</a><a class="btn" href="#/drafts/${c.id}">초안</a></div></div>
    <div class="split">
      <div class="card">
        <div class="section-title"><h2>학생 명단</h2><button class="sm" id="s-add">+ 학생 추가</button></div>
        ${d.students.length ? `<div class="table-wrap"><table><thead><tr><th>${club ? '학번' : '번호'}</th><th>이름</th><th>별칭 (전사 오인식 대비)</th><th class="right">기록</th><th></th></tr></thead><tbody>
          ${d.students.map(s => `<tr class="clickable" data-href="#/student/${s.id}" data-sid="${s.id}">
            <td class="num">${s.number ?? ''}</td><td><b>${esc(s.name)}</b></td><td class="small muted">${esc(s.aliases)}</td>
            <td class="num">${s.notes}</td>
            <td class="right nowrap"><button class="sm s-edit">수정</button></td></tr>`).join('')}
        </tbody></table></div>` : '<p class="muted">오른쪽에 명단을 붙여넣으세요.</p>'}
      </div>
      <div class="stack">
        <div class="card">
          <h2>명단 일괄 붙여넣기</h2>
          <p class="help" style="margin-top:-6px">NEIS나 엑셀에서 <b>${club ? '학번, 이름' : '번호, 이름'}</b> 두 열을 복사해 붙여넣으세요. 같은 번호가 있으면 이름을 덮어씁니다.</p>
          <textarea id="bulk" rows="10" placeholder="${club ? '20315	김민수&#10;10702	이서연' : '1	김민수&#10;2	이서연&#10;3	박지훈'}"></textarea>
          <div class="row" style="margin-top:8px"><span id="bulk-preview" class="muted small"></span><button class="primary shrink" id="bulk-save">명단 저장</button></div>
        </div>
        <div class="card">
          <h2>학급 정보</h2>
          <div class="row">${classFormFields(c)}</div>
          <p class="help" id="c-kind-help"></p>
          <div class="row" style="margin-top:10px"><span></span><button class="shrink" id="c-save">저장</button><button class="shrink danger" id="c-del">학급 삭제</button></div>
        </div>
      </div>
    </div>`;
  bindRowLinks();
  bindClassForm();
  const reload = () => router(true);
  $('#bulk').oninput = () => {
    const lines = $('#bulk').value.split('\n').filter(l => l.trim()).length;
    $('#bulk-preview').textContent = lines ? `${lines}줄` : '';
  };
  $('#bulk-save').onclick = async () => {
    const r = await api('/api/students/bulk', { class_id: c.id, text: $('#bulk').value });
    toast(`추가 ${r.added}명, 수정 ${r.updated}명`); $('#bulk').value = ''; delete $('#bulk').dataset.dirty; reload();
  };
  $('#s-add').onclick = () => editStudentModal({ class_id: c.id, number: club ? '' : (d.students.at(-1)?.number || 0) + 1 }, reload);
  $$('.s-edit').forEach(b => b.onclick = () => editStudentModal(d.students.find(s => s.id === +b.closest('tr').dataset.sid), reload));
  $('#c-save').onclick = async () => { await api('/api/classes/save', Object.assign({ id: c.id }, classFormValues())); toast('저장했습니다'); reload(); };
  $('#c-del').onclick = async () => {
    if (!confirmBox(`${c.label}와 학생 ${d.students.length}명의 관찰기록·초안을 모두 삭제합니다. 되돌릴 수 없습니다. 계속할까요?`)) return;
    await api('/api/classes/delete', { id: c.id }); location.hash = '#/classes';
  };
}

function editStudentModal(s, onSaved) {
  modal(`<h2>${s.id ? '학생 정보 수정' : '학생 추가'}</h2>
    <div class="row"><label class="field shrink" style="width:90px"><span>번호</span><input id="st-no" type="number" value="${s.number ?? ''}"></label>
      <label class="field"><span>이름</span><input id="st-name" value="${esc(s.name || '')}"></label></div>
    <label class="field" style="margin-top:10px"><span>별칭 (쉼표로 구분)</span><input id="st-al" value="${esc(s.aliases || '')}" placeholder="예: 민수, 김민서, 민쑤"></label>
    <p class="help">음성 인식이 이름을 다르게 적는 경우(예: '김민수'→'김민서')를 적어두면 자동 배정됩니다.</p>
    <label class="field" style="margin-top:10px"><span>교사 메모 (세특 생성 시 참고)</span><textarea id="st-memo" rows="3" placeholder="예: 진로 희망 - 환경공학">${esc(s.memo || '')}</textarea></label>
    <div class="modal-actions">${s.id ? '<button class="danger" id="st-del" style="margin-right:auto">학생 삭제</button>' : ''}<button id="st-cancel">취소</button><button class="primary" id="st-save">저장</button></div>`, box => {
    $('#st-name', box).focus();
    $('#st-cancel', box).onclick = closeModal;
    $('#st-save', box).onclick = async () => {
      await api('/api/students/save', { id: s.id, class_id: s.class_id, number: $('#st-no', box).value, name: $('#st-name', box).value,
        aliases: $('#st-al', box).value, memo: $('#st-memo', box).value });
      closeModal(); toast('저장했습니다'); onSaved && onSaved();
    };
    if ($('#st-del', box)) $('#st-del', box).onclick = async () => {
      if (!confirmBox(`${s.name} 학생의 관찰기록과 초안이 모두 삭제됩니다. 계속할까요?`)) return;
      await api('/api/students/delete', { id: s.id }); closeModal(); onSaved && onSaved();
    };
  });
}

// ───────────────────────── 학생 상세 ─────────────────────────

async function viewStudent(id, areaParam) {
  const d = await api('/api/students/' + id);
  const s = d.student, c = d.class, areas = d.areas;
  const area = areas.find(a => a.id === areaParam) || areas[0];
  const limit = area.limit, multi = areas.length > 1;
  const idx = d.siblings.findIndex(x => x.id === s.id);
  const prev = d.siblings[idx - 1], next = d.siblings[idx + 1];
  const drafts = d.drafts.filter(x => (x.area || 'subject') === area.id);
  const current = drafts.find(x => x.status === '확정') || drafts[0];
  const notesInArea = d.notes.filter(n => n.area_eff === area.id);
  const sib = x => `#/student/${x.id}${multi ? '/' + area.id : ''}`;
  view.innerHTML = `
    <div class="page-head"><div><a href="#/class/${c.id}" class="small">← ${esc(c.label)}</a>
      <h1>${s.number ?? ''}${c.kind === '동아리' ? ' ' : '번 '}${esc(s.name)}</h1><div class="muted small">${s.aliases ? '별칭: ' + esc(s.aliases) + ' · ' : ''}${s.memo ? '메모: ' + esc(s.memo) : ''}</div></div>
      <div class="actions">
        ${prev ? `<a class="btn" href="${sib(prev)}">← ${esc(prev.name)}</a>` : ''}
        ${next ? `<a class="btn" href="${sib(next)}">${esc(next.name)} →</a>` : ''}
        <button id="st-edit">학생 정보</button></div></div>
    ${multi ? `<div class="tabs">${areas.map(a => `<button class="${a.id === area.id ? 'on' : ''}" data-area="${a.id}">${esc(a.name)} <span class="muted small">${d.notes.filter(n => n.area_eff === a.id).length}</span></button>`).join('')}</div>` : ''}
    <div class="split">
      <div class="card">
        <div class="section-title"><h2>${multi ? esc(area.name) + ' ' : ''}관찰기록 ${notesInArea.length}건</h2><span><button class="sm" id="n-copy" title="Gemini·ChatGPT에 붙여넣을 수 있게 복사">관찰기록 복사</button> <button class="sm" id="n-add">+ 직접 추가</button></span></div>
        ${notesInArea.length ? '' : `<p class="muted">이 영역의 기록이 없습니다. 녹음을 올리거나 직접 추가하세요.${multi ? ' 다른 영역 기록은 수정 → 기재 영역에서 옮길 수 있습니다.' : ''}</p>`}
        ${notesInArea.map(n => `<div class="note ${n.use_in_draft ? '' : 'off'}" data-note="${n.id}">
          <div class="meta">${esc(n.date || '')} ${kindBadge(n.kind)} <span class="badge">${esc(n.category || '기타')}</span>
            ${n.recording_id ? `<a href="#/recording/${n.recording_id}" class="small">${n.has_audio ? '🎙 ' : ''}${esc(n.rec_title || '원본')}</a>` : '<span class="small">직접 입력</span>'}
            <span class="tools"><label class="check small" title="초안 생성에 사용"><input type="checkbox" class="n-use" ${n.use_in_draft ? 'checked' : ''}>초안에 사용</label>
            <button class="sm n-edit">수정</button><button class="sm danger n-del">삭제</button></span></div>
          <div class="content">${esc(n.content)}</div>
          ${n.evidence ? `<div class="evidence">${esc(n.evidence)}</div>` : ''}</div>`).join('')}
      </div>
      <div class="stack">
        <div class="card">
          <div class="section-title"><h2>${esc(area.full)}</h2>${current ? `<span class="badge ${current.status === '확정' ? 'green' : 'blue'}">${current.status}</span>` : ''}</div>
          <label class="field"><span>이번 초안에서 강조할 점 (선택)</span><input id="d-extra" placeholder="예: 탐구 보고서의 문제해결 과정, 진로(환경공학) 연계"></label>
          <div class="row" style="margin-top:10px"><button class="primary shrink" id="d-gen" ${notesInArea.length ? '' : 'disabled'}>✨ AI 초안 생성</button><span></span></div>
          <textarea id="d-text" rows="12" style="margin-top:12px" placeholder="AI 초안이 여기에 표시됩니다. 직접 작성·수정해도 됩니다.">${esc(current ? current.content : '')}</textarea>
          <div class="row" style="margin-top:6px;align-items:center"><span class="counter" id="d-count"></span><span></span>
            <button class="shrink sm" id="d-short">AI로 줄이기</button><button class="shrink sm" id="d-copy">복사</button></div>
          <div id="d-warn"></div>
          <div class="row" style="margin-top:12px"><span></span><button class="shrink" id="d-save">새 버전으로 저장</button><button class="shrink primary" id="d-final">확정</button></div>
        </div>
        ${drafts.length ? `<div class="card"><h3>버전 기록 ${drafts.length}개</h3>
          ${drafts.map(v => `<div class="version" data-ver="${v.id}"><div class="section-title" style="margin:0"><span>${esc(fmtDate(v.created_at))} · ${v.bytes}B ${v.status === '확정' ? '<span class="badge green">확정</span>' : ''}</span>
            <button class="link v-del">삭제</button></div><div class="preview">${esc(v.content)}</div></div>`).join('')}</div>` : ''}
      </div>
    </div>`;
  const reload = () => router(true);
  $$('[data-area]').forEach(b => b.onclick = () => { location.hash = `#/student/${s.id}/${b.dataset.area}`; });
  const text = $('#d-text');
  const update = () => {
    const b = neisBytes(text.value);
    $('#d-count').className = 'counter' + (b > limit ? ' over' : '');
    $('#d-count').textContent = `${b.toLocaleString()} / ${limit.toLocaleString()} 바이트 · ${text.value.length}자`;
    const found = FORBIDDEN.filter(w => text.value.toLowerCase().includes(w.toLowerCase()));
    const nameHit = text.value.includes(s.name);
    let warn = '';
    if (found.length) warn += `<div class="warn">기재 금지 가능성이 있는 표현: <b>${found.map(esc).join(', ')}</b> — 학생부 기재요령을 확인하세요.</div>`;
    if (nameHit) warn += `<div class="warn">본문에 학생 이름이 들어 있습니다. 학생부에는 이름을 쓰지 않습니다.</div>`;
    if (b > limit) warn += `<div class="warn">${(b - limit).toLocaleString()}바이트 초과 — 'AI로 줄이기'를 사용하거나 직접 다듬으세요.</div>`;
    $('#d-warn').innerHTML = warn;
  };
  text.addEventListener('input', update); update();
  $('#st-edit').onclick = () => editStudentModal(s, reload);
  $('#n-add').onclick = () => editNoteModal({ date: today(), kind: '수업', category: '', content: '', use_in_draft: 1, student_id: s.id, area: multi ? area.id : '' }, reload, s.id, areas);
  $('#n-copy').onclick = async () => { const t = await api(`/api/students/${s.id}/notes_text?area=${area.id}`); copyText(t.text); };
  $$('[data-note]').forEach(el => {
    const n = d.notes.find(x => x.id === +el.dataset.note);
    $('.n-edit', el).onclick = () => editNoteModal(n, reload, s.id, areas);
    $('.n-del', el).onclick = async () => { if (confirmBox('이 관찰기록을 삭제할까요?')) { await api('/api/notes/delete', { id: n.id }); reload(); } };
    $('.n-use', el).onchange = async e => { await api('/api/notes/save', { ...n, use_in_draft: e.target.checked }); reload(); };
  });
  $('#d-gen').onclick = () => {
    if (text.value.trim() && text.dataset.dirty && !confirmBox('저장하지 않은 수정 내용이 있습니다. 새 초안을 만들까요? (지금 내용은 사라집니다)')) return;
    delete text.dataset.dirty;
    runAI('draft', { student_id: s.id, extra: $('#d-extra').value, area: area.id }, `${area.name} ${s.name}`, reload);
  };
  $('#d-short').onclick = () => {
    if (!text.value.trim()) return toast('줄일 내용이 없습니다', true);
    delete text.dataset.dirty;
    runAI('shorten', { student_id: s.id, text: text.value, area: area.id }, `${area.name} ${s.name}`, reload);
  };
  $('#d-copy').onclick = () => copyText(text.value);
  $('#d-save').onclick = async () => {
    await api('/api/drafts/save', { student_id: s.id, content: text.value, status: '초안', area: area.id });
    delete text.dataset.dirty; toast('저장했습니다'); reload();
  };
  $('#d-final').onclick = async () => {
    const same = current && current.content === text.value.trim();
    await api('/api/drafts/save', { student_id: s.id, content: text.value, status: '확정', id: same ? current.id : null, as_new: !same, area: area.id });
    delete text.dataset.dirty; toast('확정했습니다'); reload();
  };
  $$('[data-ver]').forEach(el => {
    const v = drafts.find(x => x.id === +el.dataset.ver);
    el.onclick = e => {
      if (e.target.classList.contains('v-del')) return;
      text.value = v.content; text.dataset.dirty = '1'; update(); toast('이 버전을 편집기에 불러왔습니다');
    };
    $('.v-del', el).onclick = async () => { if (confirmBox('이 버전을 삭제할까요?')) { await api('/api/drafts/delete', { id: v.id }); reload(); } };
  });
}

const FORBIDDEN = ['토익', 'TOEIC', '토플', 'TOEFL', '텝스', 'TEPS', 'HSK', 'JLPT', 'IELTS', '교외', '올림피아드', '경시대회', '공모전',
  '수상', '입상', '논문', '학회', '특허', '출판', '저서', '해외', '어학연수', '유학', '부모', '아버지', '어머니', '학원', '과외', '인강'];

// ───────────────────────── 세특 초안 (학급) ─────────────────────────

async function viewDrafts(classId, areaParam) {
  if (!classId) {
    if (state.classes.length) { location.replace('#/drafts/' + state.classes[0].id); return; }
    view.innerHTML = `<div class="empty card"><h2>학급이 없습니다</h2><a href="#/classes">학급 만들기 →</a></div>`;
    return;
  }
  const [d, settings] = await Promise.all([api('/api/classes/' + classId + (areaParam ? '?area=' + areaParam : '')), api('/api/settings')]);
  const c = d.class, limit = d.byte_limit, areas = d.areas, area = areas.find(a => a.id === d.area);
  const withNotes = d.students.filter(s => s.area_notes).length;
  const missing = d.students.filter(s => s.area_notes && !s.draft_status).length;
  const done = d.students.filter(s => s.draft_status === '확정').length;
  const isApi = settings.mode === 'api' && settings.has_key;
  view.innerHTML = `
    <div class="page-head"><div><h1>초안</h1><div class="muted">학급 전체의 초안을 만들고 구글시트·엑셀로 내보냅니다.</div></div>
      <div class="actions"><select id="dc" style="width:auto">${classOptions(classId)}</select></div></div>
    ${areas.length > 1 ? `<div class="tabs">${areas.map(a => `<button class="${a.id === area.id ? 'on' : ''}" data-area="${a.id}">${esc(a.name)}</button>`).join('')}</div>` : ''}
    <div class="card">
      <div class="section-title"><h2>${esc(c.label)} · ${esc(area.full)} <span class="muted small">확정 ${done}/${d.students.length}</span></h2>
        <span class="actions" style="display:flex;gap:6px;flex-wrap:wrap">
          <button id="g-missing" ${isApi && missing ? '' : 'disabled'} title="${isApi ? '' : 'API 모드에서만 일괄 생성할 수 있습니다'}">초안 없는 학생 생성 (${missing})</button>
          <button id="g-all" ${isApi && withNotes ? '' : 'disabled'}>기록 있는 학생 전체 생성 (${withNotes})</button>
          <button id="x-copy">표 복사</button>
          <button id="x-csv">CSV</button>
          <button id="x-xlsx">엑셀로 저장</button>
          <button class="primary" id="x-sheet">구글시트 지금 반영</button></span></div>
      ${isApi ? '' : '<p class="help">API 키 없이 쓸 때는 학생 이름을 눌러 한 명씩 만들거나, 왼쪽 <a href="#/prompts">프롬프트 안내</a>대로 Gemini·ChatGPT 웹에서 만드세요.</p>'}
      <div class="table-wrap" style="margin-top:8px"><table>
        <thead><tr><th style="width:60px">${c.kind === '동아리' ? '학번' : '번호'}</th><th style="width:90px">이름</th><th class="right" style="width:60px">기록</th><th>초안</th><th class="right" style="width:90px">바이트</th><th style="width:70px">상태</th></tr></thead>
        <tbody>${d.students.map(s => `<tr class="clickable" data-href="#/student/${s.id}${areas.length > 1 ? '/' + area.id : ''}">
          <td class="num">${s.number ?? ''}</td><td><b>${esc(s.name)}</b></td>
          <td class="num">${s.area_notes ? s.area_notes : '<span class="badge red">0</span>'}</td>
          <td class="small">${s.draft ? esc(s.draft.length > 140 ? s.draft.slice(0, 140) + '…' : s.draft) : '<span class="muted">-</span>'}</td>
          <td class="num ${s.draft_bytes > limit ? 'counter over' : ''}">${s.draft_bytes ? s.draft_bytes.toLocaleString() : ''}</td>
          <td>${s.draft_status ? `<span class="badge ${s.draft_status === '확정' ? 'green' : 'blue'}">${s.draft_status}</span>` : ''}</td></tr>`).join('')}
        </tbody></table></div>
      <p class="help">한도 ${limit.toLocaleString()}바이트 (설정에서 영역별로 바꿀 수 있음). 구글시트를 연결해 두면 자동으로 반영됩니다. 내보낼 때는 확정본이 있으면 확정본을, 없으면 최신 초안을 씁니다.</p>
    </div>`;
  bindRowLinks();
  $$('[data-area]').forEach(b => b.onclick = () => { location.hash = `#/drafts/${c.id}/${b.dataset.area}`; });
  $('#dc').onchange = e => { location.hash = '#/drafts/' + e.target.value; };
  const batch = async onlyMissing => {
    const n = onlyMissing ? missing : withNotes;
    if (!confirmBox(`${n}명의 '${area.name}' 초안을 AI로 생성합니다. 무료 등급은 분당 요청 수 제한이 있어 몇 분 걸릴 수 있습니다. 진행할까요?`)) return;
    const r = await api('/api/drafts/batch', { class_id: c.id, only_missing: onlyMissing, area: area.id });
    toast(`${r.count}명 초안 생성을 대기열에 넣었습니다`); pollJobs(true);
  };
  $('#g-missing').onclick = () => batch(true);
  $('#g-all').onclick = () => batch(false);
  $('#x-copy').onclick = async () => { const t = await api('/api/export/table?class_id=' + c.id); copyText(t.tsv); };
  $('#x-xlsx').onclick = () => exportXlsx(c.id);
  $('#x-csv').onclick = async () => { const r = await api('/api/export/csv', { class_id: c.id }); toast(`다운로드 폴더에 저장했습니다: ${r.name}`); };
  $('#x-sheet').onclick = async () => {
    if (!settings.sheets_url) { toast('설정에서 구글시트 연결을 먼저 해주세요', true); location.hash = '#/settings/google'; return; }
    const r = await api('/api/export/sheets', {});
    toast(`구글시트에 반영했습니다 (시트 ${r.sheets}개)`);
  };
}

// ───────────────────────── 설정 ─────────────────────────

async function viewSettings(section) {
  const s = await api('/api/settings');
  state.settings = s;
  view.innerHTML = `
    <div class="page-head"><div><h1>설정</h1><div class="muted">모든 데이터는 이 맥의 <a href="#" id="open-data">data 폴더</a>에만 저장됩니다.</div></div></div>
    <div class="grid grid-2">
      <div class="card">
        <h2>AI 사용 방식</h2>
        <label class="check"><input type="radio" name="mode" value="api" ${s.mode === 'api' ? 'checked' : ''}> <b>API 모드</b> — 본인 Gemini API 키로 자동 처리 (권장)</label><br>
        <label class="check" style="margin-top:6px"><input type="radio" name="mode" value="manual" ${s.mode === 'manual' ? 'checked' : ''}> <b>수동 모드</b> — 키 없이, 프롬프트를 Gemini·ChatGPT 웹에 복사해서 사용</label>
        <div class="info-box" style="margin-top:14px">
          <b>Gemini API 키 받는 법 (무료, 1분)</b>
          <ol><li><a href="https://aistudio.google.com/apikey" target="_blank">aistudio.google.com/apikey</a> 접속 → 구글 계정 로그인</li>
            <li><b>API 키 만들기</b> 클릭 → 생성된 키 복사</li><li>아래 칸에 붙여넣고 <b>연결 테스트</b></li></ol>
          <p class="small muted" style="margin:8px 0 0">Gemini 구독(Google AI Pro)과 API 키는 별개이며, 키는 무료 등급으로도 사용 가능합니다. 단, 무료 등급은 입력 내용이 구글 서비스 개선에 쓰일 수 있으니 학생 정보 보호를 위해 AI Studio에서 결제 수단을 등록(유료 등급)하는 것을 권장합니다. 사용량이 적으면 비용은 매우 적습니다.</p>
        </div>
        <label class="field" style="margin-top:14px"><span>Gemini API 키</span>
          <input id="key" type="password" placeholder="${s.has_key ? esc(s.gemini_api_key_masked) + ' (저장됨 — 바꿀 때만 입력)' : 'AIza로 시작하는 키'}" autocomplete="off"></label>
        <div class="row" style="margin-top:8px"><button class="shrink" id="test">연결 테스트</button>${s.has_key ? '<button class="shrink danger" id="clear-key">키 삭제</button>' : ''}<span id="test-result" class="small"></span></div>
        <label class="field" style="margin-top:12px"><span>모델</span>
          <div class="row"><input id="model" value="${esc(s.gemini_model)}" list="model-list"><datalist id="model-list"></datalist></div></label>
        <p class="help">기본값 gemini-2.5-flash. '연결 테스트'를 누르면 쓸 수 있는 모델 목록이 채워집니다. 지정 모델이 없어지면 자동으로 다른 flash 모델로 바뀝니다.</p>
      </div>
      <div class="card">
        <h2>작성 기준</h2>
        <div class="row">
          <label class="field"><span>학교급</span><select id="school_level">${['고등학교', '중학교', '초등학교'].map(x => `<option ${x === s.school_level ? 'selected' : ''}>${x}</option>`).join('')}</select></label>
          <label class="field"><span>기본 과목</span><input id="teacher_subject" value="${esc(s.teacher_subject)}" placeholder="학급에 과목이 없을 때 사용"></label>
          <label class="field"><span>선생님 이름 (휴대폰 앱에 표시)</span><input id="teacher_name" value="${esc(s.teacher_name)}" placeholder="예: 김인회"></label>
        </div>
        <h3 style="margin-top:14px">영역별 NEIS 바이트 한도</h3>
        <div class="table-wrap"><table><tbody>${s.areas.map(a => `<tr><td>${esc(a.full)}</td>
          <td style="width:120px"><input type="number" class="area-limit" data-area="${a.id}" value="${a.limit}" style="padding:4px 8px"></td>
          <td class="small muted" style="width:90px">≈ ${Math.round(a.limit / 3)}자</td></tr>`).join('')}</tbody></table></div>
        <p class="help">한글 3바이트, 영문·숫자·공백 1바이트, 줄바꿈 2바이트. 기재요령은 학년도·학교급마다 다를 수 있으니 우리 학교 기준에 맞게 고치세요.</p>
        <label class="field" style="margin-top:12px"><span>추가 작성 지침</span>
          <textarea id="draft_guidance" rows="4" placeholder="예: 성취기준과 연결해서 쓰기, 마지막 문장은 성장 가능성으로 마무리">${esc(s.draft_guidance)}</textarea></label>
        <label class="field" style="margin-top:12px"><span>내 문체 예시 (예전에 쓴 세특 2~3개 붙여넣기)</span>
          <textarea id="style_examples" rows="6" placeholder="AI가 이 문체를 따라 씁니다. 학생 이름은 지우고 넣으세요.">${esc(s.style_examples)}</textarea></label>
      </div>
      <div class="card" id="import" style="grid-column:1 / -1">
        <div class="section-title"><h2>아이폰 기록 가져오기</h2>
          <label class="check"><input type="checkbox" id="auto_process" ${s.auto_process === '1' ? 'checked' : ''}> 들어오면 자동으로 처리 (API 모드: 전사→분리 / 키 없음: 이름 기준 분리)</label></div>
        <p class="help" style="margin-top:-4px">한 수업에 여러 학생을 한 번에 녹음해도 됩니다. 파일을 학생별로 나누거나 이름을 붙일 필요가 없습니다 — 이름이 언급된 곳을 기준으로 자동으로 나눕니다. 학급은 아래 <b>시간표</b>로 녹음 시각에 맞춰 자동 지정됩니다.</p>
        <div id="src-box"><p class="muted">불러오는 중…</p></div>
      </div>
      <div class="card" style="grid-column:1 / -1">
        <div class="section-title"><h2>시간표 (녹음 시각 → 학급 자동 지정)</h2><span class="muted small">수업 시간 중이나 끝난 뒤 15분 안의 녹음·메모는 그 시간 학급으로 들어갑니다</span></div>
        <div class="split" style="grid-template-columns: 180px 1fr">
          <label class="field"><span>교시 시간 (한 줄에 하나)</span><textarea id="period_times" rows="9" style="font-variant-numeric:tabular-nums">${esc(s.period_times)}</textarea></label>
          <div id="tt-box" style="overflow:auto"></div>
        </div>
      </div>
      <div class="card" style="grid-column:1 / -1" id="stt">
        <div class="section-title"><h2>받아쓰기(음성 → 글자) 엔진</h2><span id="stt-active" class="small"></span></div>
        <div class="row" style="gap:18px;align-items:center">
          <label class="check shrink"><input type="radio" name="stt_engine" value="whisper" ${s.stt_engine !== 'gemini' ? 'checked' : ''}> <b>내 맥에서 (Whisper)</b> — 권장 · 녹음이 외부로 나가지 않음 · 무료</label>
          <label class="check shrink"><input type="radio" name="stt_engine" value="gemini" ${s.stt_engine === 'gemini' ? 'checked' : ''}> Gemini — 녹음을 구글로 보내서 받아쓰기</label>
        </div>
        <p class="help"><b>Whisper</b>는 오픈AI가 공개한 음성 인식 모델을 이 맥에서 직접 돌립니다. 인터넷·API 키·비용이 없고 <b>녹음이 맥 밖으로 나가지 않아</b> 학생 개인정보에 가장 안전합니다. 처음 한 번 모델을 내려받으세요.</p>
        <div id="wh-box" style="margin-top:10px"><p class="muted">확인 중…</p></div>
      </div>
      <div class="card" style="grid-column:1 / -1" id="google">
        <div class="section-title"><h2>구글시트 자동 반영 · 구글 드라이브 백업</h2><span id="g-status" class="small"></span></div>
        <p class="help" style="margin-top:-4px">한 번 연결해 두면 <b>기록이 바뀔 때마다 5분 안에 구글시트에 자동 반영</b>되고, <b>하루 한 번 전체 기록이 구글 드라이브에 백업</b>됩니다. 직접 파일을 올리거나 덮어쓸 일이 없습니다. (시트는 보기용 사본 — 수정은 쓰담에서)</p>
        <div class="split">
          <div class="info-box"><b>연결 방법 (5분, 한 번만)</b><ol>
            <li><a href="https://sheets.new" target="_blank">sheets.new</a> 로 새 구글시트 만들기 (이름 예: 쓰담)</li>
            <li>시트 메뉴 <b>확장 프로그램 › Apps Script</b> → 원래 있던 내용 지우기</li>
            <li><button class="sm primary" id="copy-gs">스크립트 복사</button> → 붙여넣기 → 저장(⌘S)</li>
            <li><b>배포 › 새 배포</b> → 톱니바퀴 <b>웹 앱</b> → 실행: <b>나</b> · 액세스: <b>모든 사용자</b> → 배포</li>
            <li>권한 검토 → 내 계정 → (경고가 뜨면 <b>고급 → 이동</b>) → <b>허용</b></li>
            <li>나온 <b>웹 앱 URL</b>을 오른쪽에 붙여넣고 <b>연결 확인</b></li></ol>
            <p class="small muted" style="margin:6px 0 0">'스크립트 복사'에는 이 맥 전용 보안 토큰이 들어 있어서, 주소를 알아도 다른 사람은 기록에 접근할 수 없습니다.</p></div>
          <div>
            <label class="field"><span>웹 앱 URL</span><input id="sheets_url" value="${esc(s.sheets_url)}" placeholder="https://script.google.com/macros/s/…/exec"></label>
            <div class="row" style="margin-top:8px"><button class="shrink" id="g-test">연결 확인</button><span id="g-test-r" class="small"></span></div>
            <label class="check" style="margin-top:12px"><input type="checkbox" id="sheets_auto" ${s.sheets_auto === '1' ? 'checked' : ''}> 구글시트에 자동 반영 (바뀐 내용이 있을 때 5분마다)</label><br>
            <label class="check" style="margin-top:6px"><input type="checkbox" id="drive_backup" ${s.drive_backup === '1' ? 'checked' : ''}> 하루 한 번 구글 드라이브에 전체 백업 (최근 30개 보관)</label>
            <div class="row" style="margin-top:12px"><button class="shrink" id="g-sync">지금 시트에 반영</button><button class="shrink" id="g-backup">지금 드라이브 백업</button></div>
            <p class="help" id="g-last"></p>
          </div>
        </div>
      </div>
      <div class="card" style="grid-column:1 / -1" id="phone">
        <div class="section-title"><h2>📱 휴대폰 '쓰담' 앱 연결</h2><label class="check"><input type="checkbox" id="drive_inbox" ${s.drive_inbox === '1' ? 'checked' : ''}> 휴대폰 녹음 자동으로 가져오기</label></div>
        <div class="split">
          <div class="info-box"><b>아이폰</b> — App Store에서 <b>쓰담</b> 설치 → 녹음하면 <b>iCloud로 자동 연동</b> (같은 Apple ID면 설정 없음)${s.platform === 'win' ? '<br><span class="small muted">윈도우 PC는 iCloud for Windows가 설치돼 있어야 합니다. 없으면 아래 구글 연결을 쓰세요.</span>' : ''}
            <br><br><b>안드로이드(갤럭시) · 아이폰 공통</b> — Play 스토어/App Store에서 <b>쓰담</b> 설치 → 앱의 <b>컴퓨터 연결</b> → 오른쪽 QR 찍기 → 녹음이 <b>내 구글 드라이브</b>를 거쳐 이 컴퓨터로 자동 전송
            <p class="small muted" style="margin:6px 0 0">QR에는 '녹음 올리기'만 가능한 전용 열쇠가 들어 있습니다. 휴대폰을 잃어버려도 기록을 볼 수는 없습니다. 구글 연결(위 카드)이 먼저 되어 있어야 합니다.</p></div>
          <div style="text-align:center"><div id="qr-box" class="muted small">불러오는 중…</div>
            <button class="sm" id="phone-scan" style="margin-top:8px">휴대폰 녹음 지금 가져오기</button></div>
        </div>
      </div>
      <div class="card" style="grid-column:1 / -1" id="backup-card">
        <div class="section-title"><h2>백업 · 복원 · 엑셀</h2>
          <span style="display:flex;gap:6px;flex-wrap:wrap"><button id="backup">지금 백업 (이 맥)</button><button id="xlsx-all" class="primary">전체 엑셀로 저장</button></span></div>
        <p class="help" style="margin-top:-4px">이 맥에는 매일 자동 백업(30일)됩니다. 구글 드라이브 백업까지 켜 두면 맥이 고장 나도 복원할 수 있습니다. 녹음 원본(오디오)은 용량 때문에 이 맥에만 보관되니, 타임머신 백업을 함께 쓰면 가장 안전합니다.</p>
        <div class="split" style="margin-top:8px">
          <div><h3>복원할 백업 고르기</h3><div id="bk-list" class="small"><p class="muted">불러오는 중…</p></div></div>
          <div><h3>파일로 복원</h3><p class="help">받아 둔 백업 파일(.zip 또는 .db)을 고르세요. 복원 전에 지금 상태를 자동 백업합니다.</p>
            <input type="file" id="restore-file" accept=".zip,.db"></div>
        </div>
      </div>
      <div class="card">
        <h2>프로그램 업데이트</h2>
        <p class="muted small" id="upd-info">현재 버전 확인 중…</p>
        <div class="row"><button class="shrink" id="upd-check">업데이트 확인</button>
          <label class="check"><input type="checkbox" id="update_check" ${s.update_check === '1' ? 'checked' : ''}> 실행할 때 자동으로 새 버전 확인</label></div>
        <p class="help">업데이트는 프로그램 코드만 바꾸며 학생 기록은 그대로 유지됩니다. 업데이트 직전에 자동 백업합니다.</p>
      </div>
    </div>
    <div style="position:sticky;bottom:0;padding:14px 0;background:linear-gradient(transparent, var(--bg) 30%);display:flex;justify-content:flex-end">
      <button class="primary" id="save" style="padding:10px 28px">설정 저장</button></div>`;
  $('#open-data').onclick = e => { e.preventDefault(); api('/api/open_data', {}); };
  const collect = () => ({
    mode: ($('input[name=mode]:checked') || {}).value || 'api',
    gemini_api_key: $('#key').value, gemini_model: $('#model').value.trim(),
    area_limits: JSON.stringify(Object.fromEntries($$('.area-limit').map(i => [i.dataset.area, +i.value || 0]))),
    byte_limit: ($('.area-limit[data-area=subject]') || {}).value || s.byte_limit, school_level: $('#school_level').value, teacher_subject: $('#teacher_subject').value,
    draft_guidance: $('#draft_guidance').value, style_examples: $('#style_examples').value,
    auto_process: $('#auto_process').checked ? '1' : '0',
    sheets_url: $('#sheets_url').value.trim(),
    sheets_auto: $('#sheets_auto').checked ? '1' : '0', drive_backup: $('#drive_backup').checked ? '1' : '0',
    stt_engine: ($('input[name=stt_engine]:checked') || {}).value || 'whisper',
    period_times: $('#period_times').value, timetable: JSON.stringify(timetable),
    update_check: $('#update_check').checked ? '1' : '0',
    drive_inbox: $('#drive_inbox').checked ? '1' : '0', teacher_name: $('#teacher_name').value.trim(),
  });
  const save = async () => { await api('/api/settings', collect()); };
  $('#save').onclick = async () => { await save(); toast('설정을 저장했습니다'); updateModeBadge(); router(true); };
  $('#test').onclick = async () => {
    $('#test-result').textContent = '확인 중…';
    try {
      const r = await api('/api/settings/test', { key: $('#key').value }, { silent: true });
      $('#test-result').innerHTML = `<span style="color:var(--green)">✓ 연결 성공 (모델 ${r.models.length}개)</span>`;
      $('#model-list').innerHTML = r.models.map(m => `<option value="${esc(m.name)}">${esc(m.display)}</option>`).join('');
      if ($('#key').value) { await save(); toast('키를 저장했습니다'); updateModeBadge(); }
    } catch (e) { $('#test-result').innerHTML = `<span style="color:var(--red)">${esc(e.message)}</span>`; }
  };
  if ($('#clear-key')) $('#clear-key').onclick = async () => {
    if (!confirmBox('저장된 API 키를 삭제할까요?')) return;
    await api('/api/settings', { clear_key: true }); router(true); updateModeBadge();
  };
  $('#copy-gs').onclick = async () => { const t = await (await fetch('/google_apps_script.gs')).text(); copyText(t); };
  $('#backup').onclick = async () => { await api('/api/backup', {}); toast('백업했습니다'); renderBackups(); };
  $('#xlsx-all').onclick = () => exportXlsx(null);
  $$('input[name=stt_engine]').forEach(r => r.onchange = async () => { await api('/api/settings', { stt_engine: r.value }); renderWhisper(); });
  $('#g-test').onclick = async () => {
    await api('/api/settings', { sheets_url: $('#sheets_url').value.trim() });
    $('#g-test-r').textContent = '확인 중…';
    try { const r = await api('/api/sheets/test', {}, { silent: true }); $('#g-test-r').innerHTML = `<span class="ok-text">✓ 연결됨</span> <a href="${esc(r.url)}" target="_blank">시트 열기</a>`; }
    catch (e) { $('#g-test-r').innerHTML = `<span class="bad-text">${esc(e.message)}</span>`; }
  };
  $('#g-sync').onclick = async () => { await save(); const r = await api('/api/export/sheets', {}); toast(`구글시트에 ${r.sheets}개 시트를 반영했습니다`); renderGoogle(); };
  $('#g-backup').onclick = async () => { await save(); $('#g-backup').disabled = true; try { const r = await api('/api/drive/backup', {}); toast(`드라이브에 백업했습니다 (${Math.round(r.size / 1024)}KB)`); } finally { $('#g-backup').disabled = false; renderGoogle(); renderBackups(); } };
  $('#restore-file').onchange = async e => {
    const f = e.target.files[0]; if (!f) return;
    if (!confirmBox(`'${f.name}' 백업으로 지금 기록을 바꿀까요?\n(지금 상태는 자동으로 따로 백업됩니다)`)) { e.target.value = ''; return; }
    const r = await api('/api/restore/upload', f);
    toast(`복원했습니다 — 학급 ${r.counts.classes}, 학생 ${r.counts.students}, 기록 ${r.counts.notes}`); router(true);
  };
  renderWhisper(); renderGoogle(); renderBackups(); renderPairing();
  $('#phone-scan').onclick = async () => { const r = await api('/api/phone/scan', {}); toast(`휴대폰 녹음 ${r.imported}개를 가져왔습니다`); };
  if (s.platform !== 'mac') $$('[data-maconly]').forEach(e => e.classList.add('hidden'));

  // 시간표
  let timetable = {};
  try { timetable = JSON.parse(s.timetable || '{}'); } catch (e) { timetable = {}; }
  const drawTT = () => {
    const periods = $('#period_times').value.split('\n').filter(l => l.trim());
    const days = ['월', '화', '수', '목', '금'];
    const opts = sel => '<option value="">-</option>' + state.classes.map(c => `<option value="${c.id}" ${String(c.id) === String(sel) ? 'selected' : ''}>${esc(c.grade + '-' + c.class_no + (c.subject ? ' ' + c.subject : ''))}</option>`).join('');
    $('#tt-box').innerHTML = state.classes.length ? `<table class="tt"><thead><tr><th>교시</th>${days.map(d => `<th>${d}</th>`).join('')}</tr></thead><tbody>
      ${periods.map((p, i) => `<tr><th>${i + 1}<div class="muted" style="font-weight:400">${esc(p.trim())}</div></th>
        ${days.map((d, j) => { const k = `${j + 1}-${i + 1}`; return `<td class="${timetable[k] ? 'set' : ''}"><select data-k="${k}">${opts(timetable[k])}</select></td>`; }).join('')}</tr>`).join('')}
      </tbody></table><p class="help">바꾼 뒤 아래 <b>설정 저장</b>을 누르세요.</p>` : '<p class="muted">먼저 학급을 만들어야 시간표를 채울 수 있습니다.</p>';
    $$('#tt-box select').forEach(sel => sel.onchange = () => {
      if (sel.value) timetable[sel.dataset.k] = +sel.value; else delete timetable[sel.dataset.k];
      sel.parentElement.classList.toggle('set', !!sel.value);
    });
  };
  drawTT();
  $('#period_times').addEventListener('change', drawTT);

  // 가져오기 경로
  renderSources().then(() => { if (section && $('#' + section)) $('#' + section).scrollIntoView({ behavior: 'smooth' }); });

  // 업데이트
  const showUpd = async force => {
    const v = await api('/api/version');
    let txt = `현재 버전 <b>${esc(v.version)}</b>`;
    if (!v.repo) { $('#upd-info').innerHTML = txt + ' · 업데이트 저장소가 지정되지 않았습니다.'; return; }
    const u = await api('/api/update/check' + (force ? '?force=1' : ''), undefined, { silent: true }).catch(e => ({ error: e.message }));
    if (u.available) txt += ` · <b class="ok-text">새 버전 ${esc(u.latest)} 있음</b> <button class="sm primary" id="upd-go">지금 업데이트</button>`;
    else if (u.error) txt += ` · <span class="bad-text">${esc(u.error)}</span>`;
    else if (u.message) txt += ` · ${esc(u.message)}`;
    else if (u.latest) txt += ' · 최신 버전입니다';
    $('#upd-info').innerHTML = txt;
    if ($('#upd-go')) $('#upd-go').onclick = () => runUpdate(u);
  };
  showUpd(false);
  $('#upd-check').onclick = () => showUpd(true);
}

async function renderPairing() {
  const box = $('#qr-box'); if (!box) return;
  const p = await api('/api/phone/pairing', undefined, { silent: true }).catch(() => null);
  if (!p || !p.ready) { box.innerHTML = '<div class="warn" style="text-align:left">먼저 위의 <b>구글시트 자동 반영 · 드라이브 백업</b>을 연결하세요. 연결하면 여기에 QR이 나타납니다.</div>'; return; }
  const qr = qrcode(0, 'M'); qr.addData(p.payload); qr.make();
  box.innerHTML = `<div style="background:#fff;display:inline-block;padding:10px;border-radius:10px">${qr.createSvgTag({ cellSize: 5, margin: 2 })}</div>
    <div class="small muted" style="margin-top:6px">휴대폰 '쓰담' 앱 → 컴퓨터 연결 → QR 찍기</div>`;
}

async function renderGoogle() {
  if (!$('#g-last')) return;
  const s = await api('/api/settings', undefined, { silent: true }).catch(() => null);
  if (!s) return;
  const parts = [];
  parts.push(s.sheets_last_sync ? `시트 마지막 반영: ${esc(s.sheets_last_sync)}` : '시트 반영 기록 없음');
  parts.push(s.drive_last_backup ? `드라이브 마지막 백업: ${esc(s.drive_last_backup)}` : '드라이브 백업 기록 없음');
  $('#g-last').innerHTML = parts.join(' · ') + (s.sheets_last_error ? `<br><span class="bad-text">최근 오류: ${esc(s.sheets_last_error)}</span>` : '');
  $('#g-status').innerHTML = s.sheets_url ? (s.sheets_last_error ? '<span class="badge red">오류</span>' : '<span class="badge green">연결됨</span>') : '<span class="badge">연결 안 됨</span>';
}

async function renderBackups() {
  const box = $('#bk-list'); if (!box) return;
  const d = await api('/api/backups', undefined, { silent: true }).catch(e => ({ local: [], drive: [], drive_error: e.message }));
  const kb = n => n > 1048576 ? (n / 1048576).toFixed(1) + 'MB' : Math.round(n / 1024) + 'KB';
  const row = (kind, id, name, time, size) => `<tr><td>${kind === 'drive' ? '<span class="badge blue">드라이브</span>' : '<span class="badge">이 맥</span>'}</td>
    <td>${esc(time)}</td><td class="muted">${esc(name)}</td><td class="num">${kb(size)}</td><td class="right"><button class="sm bk-go" data-kind="${kind}" data-id="${esc(id)}" data-name="${esc(name)}">복원</button></td></tr>`;
  const rows = d.drive.slice(0, 10).map(f => row('drive', f.id, f.name, (f.time || '').replace('T', ' ').slice(0, 16), f.size))
    .concat(d.local.slice(0, 10).map(f => row('local', f.name, f.name, f.time, f.size)));
  box.innerHTML = (rows.length ? `<div class="table-wrap" style="max-height:260px"><table><tbody>${rows.join('')}</tbody></table></div>` : '<p class="muted">아직 백업이 없습니다.</p>')
    + (d.drive_error ? `<p class="bad-text small">드라이브 목록을 못 불러옴: ${esc(d.drive_error)}</p>` : '');
  $$('.bk-go', box).forEach(b => b.onclick = async () => {
    if (!confirmBox(`'${b.dataset.name}' 백업으로 지금 기록을 바꿀까요?\n(지금 상태는 자동으로 따로 백업됩니다)`)) return;
    b.disabled = true; b.textContent = '복원 중…';
    const r = await api('/api/restore', { kind: b.dataset.kind, id: b.dataset.id, name: b.dataset.name });
    toast(`복원했습니다 — 학급 ${r.counts.classes}, 학생 ${r.counts.students}, 기록 ${r.counts.notes}`); router(true);
  });
}

let whTimer;
async function renderWhisper() {
  const box = $('#wh-box'); if (!box) return;
  clearTimeout(whTimer);
  const w = await api('/api/whisper', undefined, { silent: true }).catch(() => null);
  if (!w) return;
  const hasModel = w.models.some(m => m.installed);
  $('#stt-active').innerHTML = w.engine === 'gemini' || !w.supported ? '<span class="badge amber">지금: Gemini로 받아쓰기 (외부 전송)</span>'
    : hasModel ? '<span class="badge green">지금: 내 맥 안에서 받아쓰기 — 외부 전송 없음</span>' : '<span class="badge red">모델을 내려받아야 받아쓰기가 됩니다</span>';
  if (!w.supported) { box.innerHTML = '<div class="warn">이 맥은 Intel 칩이라 Whisper를 쓸 수 없습니다. Gemini 받아쓰기를 사용하세요.</div>'; return; }
  if (!w.binary) { box.innerHTML = '<div class="warn">Whisper 실행 파일이 없습니다. 쓰담을 최신 설치 파일로 다시 설치하세요.</div>'; return; }
  let downloading = false;
  box.innerHTML = '<div class="table-wrap"><table><tbody>' + w.models.map(m => {
    const dl = m.download && m.download.status === 'downloading' ? m.download : null;
    if (dl) downloading = true;
    const pct = dl ? Math.floor(dl.done / dl.total * 100) : 0;
    let action;
    if (m.installed) action = `<span class="badge green">설치됨</span> <button class="sm wh-del" data-id="${m.id}">삭제</button>`;
    else if (dl) action = `<div class="bar" style="width:160px;display:inline-flex"><div class="b1" style="width:${pct}%"></div></div> ${pct}% <button class="sm wh-cancel" data-id="${m.id}">취소</button>`;
    else action = `<button class="sm ${m.id === 'turbo-q5' ? 'primary' : ''} wh-dl" data-id="${m.id}">내려받기</button>`;
    const err = m.download && m.download.status === 'error' ? `<div class="bad-text small">${esc(m.download.error)}</div>` : '';
    return `<tr><td style="width:110px"><b>${esc(m.label)}</b></td><td class="small">${esc(m.desc)}${err}</td><td class="right nowrap">${action}</td></tr>`;
  }).join('') + '</tbody></table></div><p class="help">모델은 한 개만 있으면 됩니다. 와이파이에서 내려받으세요.</p>';
  $$('.wh-dl', box).forEach(b => b.onclick = async () => { await api('/api/whisper/download', { id: b.dataset.id }); renderWhisper(); });
  $$('.wh-cancel', box).forEach(b => b.onclick = async () => { await api('/api/whisper/cancel', { id: b.dataset.id }); setTimeout(renderWhisper, 500); });
  $$('.wh-del', box).forEach(b => b.onclick = async () => { if (confirmBox('이 모델을 삭제할까요?')) { await api('/api/whisper/delete', { id: b.dataset.id }); renderWhisper(); } });
  if (downloading) whTimer = setTimeout(renderWhisper, 1500);
}

async function whisperBanner(el) {
  if (!el) return;
  const w = await api('/api/whisper', undefined, { silent: true }).catch(() => null);
  if (!w || !w.supported || !w.binary || w.engine === 'gemini' || w.models.some(m => m.installed)) { el.innerHTML = ''; return; }
  const m = w.models.find(x => x.id === 'turbo-q5');
  const dl = m.download && m.download.status === 'downloading' ? m.download : null;
  const pct = dl ? Math.floor(dl.done / dl.total * 100) : 0;
  el.innerHTML = `<div class="card" style="border-color:var(--accent);margin-bottom:16px">
    <div class="section-title"><h2>🎙 받아쓰기 모델 설치 (처음 한 번)</h2>
      ${dl ? `<span class="small"><div class="bar" style="width:200px;display:inline-flex"><div class="b1" style="width:${pct}%"></div></div> ${pct}% 내려받는 중</span>`
           : `<button class="primary" id="wb-go">지금 내려받기 (550MB)</button>`}</div>
    <p class="muted small" style="margin:0">녹음을 <b>이 맥 안에서</b> 글자로 바꾸는 Whisper 모델입니다. 인터넷·API 키·비용 없이 동작하고 녹음이 외부로 나가지 않습니다.
    ${m.download && m.download.status === 'error' ? `<br><span class="bad-text">${esc(m.download.error)}</span>` : ''} 설치가 끝나면 기다리던 녹음이 자동으로 받아써집니다.</p></div>`;
  if ($('#wb-go', el)) $('#wb-go', el).onclick = async () => { await api('/api/whisper/download', { id: 'turbo-q5' }); whisperBanner(el); };
  if (dl) setTimeout(() => { if (document.body.contains(el)) whisperBanner(el); }, 1500);
}

async function exportXlsx(classId) {
  toast('엑셀 파일을 만드는 중…');
  const r = await api('/api/export/xlsx', { class_id: classId });
  toast(`다운로드 폴더에 저장했습니다: ${r.name}`);
}

async function renderSources() {
  const box = $('#src-box');
  if (!box) return;
  const src = await api('/api/sources');
  const vm = src.voicememo, nt = src.notes;
  const appName = src.app_name;
  const vmState = !vm.enabled ? '' : vm.access === 'ok' ? '<span class="badge green">작동 중</span>'
    : vm.access === 'no_permission' ? '<span class="badge red">권한 필요</span>' : '<span class="badge amber">음성메모 보관함 없음</span>';
  const mac = (state.settings || {}).platform !== 'win' && (state.settings || {}).platform !== 'other';
  box.innerHTML = (mac ? `
    <div class="source">
      <div class="source-head"><h3>① 음성메모 자동 가져오기 <span class="badge blue">가장 편함</span> ${vmState}</h3>
        <label class="switch"><input type="checkbox" id="vm-on" ${vm.enabled ? 'checked' : ''}> 사용</label></div>
      <p>아이폰 <b>음성메모</b>로 녹음만 하면 끝. 저장·공유·파일 이름 정하기가 필요 없습니다. iCloud로 이 맥에 넘어온 녹음을 자동으로 가져옵니다.
        아이폰이 이미 받아쓴 전사문이 있으면 그대로 써서 AI 전사도 건너뜁니다.</p>
      ${vm.enabled && vm.access === 'no_permission' ? `<div class="warn">맥이 음성메모 보관함을 막고 있습니다. <b>시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한</b>에서 <b>${esc(appName)}</b>을 켜 주세요. 켠 뒤 쓰담을 껐다 켜야 적용됩니다.
        <div style="margin-top:6px"><button class="sm" id="vm-perm">설정 화면 열기</button></div></div>` : ''}
      ${vm.enabled && vm.access === 'not_found' ? `<div class="warn">이 맥에서 음성메모 보관함을 찾지 못했습니다. 맥의 <b>음성 메모</b> 앱을 한 번 열고, 아이폰과 맥 모두 <b>설정 → [내 이름] → iCloud → 음성 메모</b>가 켜져 있는지 확인하세요.</div>` : ''}
      ${vm.enabled ? `<div class="row" style="margin-top:10px">
        <label class="field"><span>이 시각 이후 녹음만</span><input type="datetime-local" id="vm-since" value="${esc((vm.since || '').replace(' ', 'T'))}"></label>
        <label class="field"><span>제목에 이 단어가 있는 것만 (비우면 전부)</span><input id="vm-kw" value="${esc(vm.keyword)}" placeholder="예: 수업"></label>
        <button class="shrink" id="vm-save">적용</button></div>
        <p class="help">지금까지 ${vm.count}개 가져옴 · 개인 녹음이 섞이면 제목 단어 필터를 쓰거나, 녹음함에서 지우면 됩니다.</p>` : ''}
      <details style="margin-top:8px"><summary class="small">처음 설정 방법</summary><ol class="small">
        <li>아이폰: <b>설정 → [내 이름] → iCloud → 모두 보기 → 음성 메모</b> 켜기</li>
        <li>맥: <b>시스템 설정 → [내 이름] → iCloud → 음성 메모</b> 켜기, 맥의 <b>음성 메모</b> 앱을 한 번 열어 동기화 확인</li>
        <li>위 <b>사용</b> 체크 → 안내에 따라 <b>전체 디스크 접근 권한</b> 허용 → 쓰담 다시 실행</li></ol></details>
    </div>
    <div class="source">
      <div class="source-head"><h3>② 메모 앱 받아쓰기 <span class="badge green">AI 키 없이 무료 전사</span> ${nt.enabled ? '<span class="badge green">작동 중</span>' : ''}</h3>
        <label class="switch"><input type="checkbox" id="nt-on" ${nt.enabled ? 'checked' : ''}> 사용</label></div>
      <p>아이폰 <b>메모</b> 앱의 <b>'${esc(nt.folder)}'</b> 폴더에 메모를 만들고 키보드의 <b>🎤 마이크</b>로 말하면 아이폰이 바로 글자로 바꿉니다.
        그 메모를 자동으로 가져와 학생별로 나눕니다. 같은 메모에 이어서 말하면 <b>덧붙인 부분만</b> 새 기록으로 들어옵니다.</p>
      <div class="row" style="margin-top:10px"><label class="field"><span>메모 폴더 이름</span><input id="nt-folder" value="${esc(nt.folder)}"></label>
        <button class="shrink" id="nt-save">적용</button><span class="muted small">지금까지 ${nt.count}개 가져옴 · 마지막 수정 5분 뒤에 가져옴 (받아쓰는 중 보호)</span></div>
      <details style="margin-top:8px"><summary class="small">처음 설정 방법</summary><ol class="small">
        <li>아이폰·맥 모두 <b>iCloud → 메모</b> 켜기 (보통 켜져 있음)</li>
        <li>아이폰 메모 앱에서 <b>새 폴더 '${esc(nt.folder)}'</b> 만들기 (iCloud 계정 아래)</li>
        <li>위 <b>사용</b> 체크 → "메모를 제어하려고 합니다" 창이 뜨면 <b>허용</b></li>
        <li>사용 팁: 메모 제목에 <b>2-3</b> 같은 학급을 쓰거나, 시간표를 채워 두면 학급이 자동 지정됩니다</li></ol></details>
    </div>
` : '<p class="muted small">아이폰 음성메모·메모 앱 자동 가져오기는 맥에서만 됩니다. 윈도우에서는 휴대폰 \'쓰담\' 앱(아래)이나 iCloud 폴더를 쓰세요.</p>') + `
    <div class="source" id="ts-box"></div>
    <div class="source">
      <div class="source-head"><h3>AirDrop · 퀵 셰어로 받기 <span class="badge blue">맥·윈도우</span> ${src.downloads.enabled ? '<span class="badge green">작동 중</span>' : ''}</h3>
        <label class="switch"><input type="checkbox" id="dl-on" ${src.downloads.enabled ? 'checked' : ''}> 사용</label></div>
      <p>휴대폰 쓰담 앱에서 <b>보내기 → AirDrop</b>(맥)이나 <b>퀵 셰어</b>(갤럭시 → 윈도우)로 보내면 <b>다운로드</b> 폴더에 들어온 <b>‘쓰담 …’ 파일</b>을 자동으로 가져옵니다. 맥에서는 AirDrop으로 받은 음성메모도 가져와요.
        다운로드 폴더의 다른 파일은 건드리지 않고, 원본은 그대로 남겨 둡니다. <span class="muted small">(지금까지 ${src.downloads.count}개)</span></p>
    </div>
    <div class="source">
      <div class="source-head"><h3>③ iCloud '쓰담 녹음' 폴더 / 단축어 ${src.inbox.exists ? '<span class="badge green">작동 중</span>' : ''}</h3>
        <button class="sm" id="inbox-open">${src.inbox.exists ? 'Finder에서 열기' : '폴더 만들기'}</button></div>
      <p>이 폴더에 들어온 오디오·텍스트(.txt)를 자동으로 가져옵니다. 아이폰 <b>단축어</b>로 '한 번 눌러 녹음 → 자동 저장' 버튼을 만들 때 사용합니다 (사용설명서 참고).</p>
      <p class="muted small">${esc(src.inbox.dir)}</p>
    </div>`;
  const setVM = async (extra) => {
    const r = await api('/api/sources/voicememo', Object.assign({ enabled: $('#vm-on').checked }, extra || {}));
    if ($('#vm-on').checked && r.access === 'no_permission') toast('전체 디스크 접근 권한이 필요합니다. 안내를 따라 주세요.', true);
    renderSources();
  };
  renderTextSync();
  $('#dl-on').onchange = async e => { await api('/api/settings', { downloads_import: e.target.checked ? '1' : '0', downloads_since: '' }); renderSources(); };
  if (!mac) { $('#inbox-open').onclick = async () => { await api('/api/inbox/create', {}); renderSources(); }; return; }
  $('#vm-on').onchange = () => setVM();
  if ($('#vm-perm')) $('#vm-perm').onclick = () => api('/api/open_privacy', { pane: 'fda' });
  if ($('#vm-save')) $('#vm-save').onclick = () => setVM({ since: $('#vm-since').value, keyword: $('#vm-kw').value }).then(() => toast('적용했습니다'));
  const setNT = async () => {
    try {
      const r = await api('/api/sources/notes', { enabled: $('#nt-on').checked, folder: $('#nt-folder').value }, { silent: true });
      if (r.found !== undefined) toast(`메모 앱 연결됨 — '${$('#nt-folder').value}' 폴더 메모 ${r.found}개`);
    } catch (e) {
      toast(e.message, true);
      if (/권한/.test(e.message)) api('/api/open_privacy', { pane: 'automation' });
    }
    renderSources();
  };
  $('#nt-on').onchange = setNT;
  $('#nt-save').onclick = setNT;
  $('#inbox-open').onclick = async () => { await api('/api/inbox/create', {}); renderSources(); };
}

async function runUpdate(u) {
  if (!confirmBox(`쓰담 ${u.latest} 버전으로 업데이트할까요?\n학생 기록은 그대로 유지되며, 업데이트 전에 자동 백업합니다.`)) return;
  modal(`<h2>업데이트 중…</h2><p>새 버전을 내려받아 설치하고 있습니다. 끝나면 화면이 자동으로 새로고침됩니다.</p>`);
  try { await api('/api/update/apply', {}); }
  catch (e) { closeModal(); return; }
  const target = u.latest;
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 1000));
    try { const v = await api('/api/version', undefined, { silent: true }); if (v.version === target) { location.reload(); return; } } catch (e) { /* 재시작 중 */ }
  }
  modal(`<h2>업데이트 확인 필요</h2><p>새 버전이 시작되지 않았습니다. 쓰담을 종료 후 다시 실행해 주세요.</p><div class="modal-actions"><button onclick="location.reload()">새로고침</button></div>`);
}

async function checkUpdateBanner() {
  try {
    const v = await api('/api/version', undefined, { silent: true });
    $('#ver-badge').textContent = 'v' + v.version;
    const u = await api('/api/update/check', undefined, { silent: true });
    const b = $('#update-banner');
    if (v.shell_outdated && !u.available) {
      b.innerHTML = `<b>쓰담이 '앱 창' 버전으로 바뀌었습니다.</b> 브라우저 대신 자기 창으로 열리고, 녹음을 이 맥 안에서 받아쓰는 기능이 들어 있습니다. 기록은 그대로 유지됩니다.
        <button class="sm primary" id="ub-app">새 앱으로 바꾸기</button> <button class="sm ghost" id="ub-x">나중에</button>`;
      b.classList.remove('hidden');
      $('#ub-x').onclick = () => b.classList.add('hidden');
      $('#ub-app').onclick = async () => {
        modal('<h2>새 앱 설치 중…</h2><p>잠시 후 쓰담이 새 창으로 다시 열립니다. 이 브라우저 창은 닫아도 됩니다.</p>');
        try { await api('/api/update/install_app', {}); } catch (e) { closeModal(); }
      };
      return;
    }
    if (u.available) {
      b.innerHTML = `<b>새 버전 ${esc(u.latest)}이(가) 나왔습니다.</b> <button class="sm primary" id="ub-go">지금 업데이트</button> <button class="sm ghost" id="ub-x">나중에</button>
        ${u.notes ? `<div class="notes">${esc(u.notes)}</div>` : ''}`;
      b.classList.remove('hidden');
      $('#ub-go').onclick = () => runUpdate(u);
      $('#ub-x').onclick = () => b.classList.add('hidden');
    }
  } catch (e) { /* 오프라인 */ }
}

async function viewPrompts() {
  const d = await api('/api/prompts');
  view.innerHTML = `
    <div class="page-head"><div><h1>프롬프트 안내</h1><div class="muted">Gemini·ChatGPT 웹 화면에서 직접 쓸 때 복사해서 붙여넣는 문구입니다. API 키가 없어도 쓸 수 있습니다.</div></div></div>
    <div class="info-box" style="margin-bottom:16px"><b>가장 쉬운 방법</b>
      <ol><li>아래 <b>①</b>로 Gemini 'Gem'(또는 ChatGPT 'GPT')을 한 번만 만들어 둡니다.</li>
        <li>학생 화면에서 <b>관찰기록 복사</b> → Gem에 "세특 써줘"와 함께 붙여넣기 → 결과를 학생 화면 편집창에 붙여넣기.</li>
        <li>쓰담을 <b>수동 모드</b>로 두면, 녹음·학생 화면의 AI 버튼을 누를 때 명단·기록이 이미 채워진 프롬프트가 자동으로 나옵니다.</li></ol>
      <p class="small muted" style="margin:6px 0 0">아래 문구의 <b>[대괄호]</b> 부분만 실제 내용으로 바꾸면 됩니다. 설정의 바이트 한도·추가 지침이 반영되어 있습니다.</p></div>
    ${d.templates.map((t, i) => `<div class="card">
      <div class="section-title"><h2>${esc(t.title)}</h2><button class="primary sm p-copy" data-i="${i}">프롬프트 복사</button></div>
      <p class="muted small" style="margin-top:-4px">${esc(t.when)}</p>
      <ol class="small">${t.steps.map(x => `<li>${esc(x)}</li>`).join('')}</ol>
      <details><summary class="small">프롬프트 내용 보기</summary><textarea class="prompt-box" readonly style="max-height:340px;margin-top:8px">${esc(t.prompt)}</textarea></details>
    </div>`).join('')}`;
  $$('.p-copy').forEach(b => b.onclick = () => copyText(d.templates[+b.dataset.i].prompt));
}

// ───────────────────────── 첫 실행 안내 ─────────────────────────

async function maybeOnboard() {
  const s = await api('/api/settings', undefined, { silent: true }).catch(() => null);
  if (!s || s.onboarded === '1') return;
  await loadClasses();
  if (state.classes.length) { api('/api/settings', { onboarded: '1' }); return; }
  showOnboarding(s);
}

function showOnboarding(s) {
  const y = new Date().getFullYear(), sem = (new Date().getMonth() + 1) >= 8 ? 2 : 1;
  const st = { step: 1 };
  const steps = {
    1: () => `<h2>👋 쓰담에 오신 것을 환영합니다</h2><p style="margin:-4px 0 8px;color:var(--accent);font-weight:600">말로 담고, 글로 씁니다</p>
      <p class="muted">수업·상담 중 말로 남긴 관찰을 학생별로 모아, 학기말 세특·행동특성·창체 초안을 빠르게 만드는 도구입니다. 1분이면 준비됩니다.</p>
      <div class="row" style="margin-top:12px">
        <label class="field"><span>학교급</span><select id="ob-level">${['고등학교', '중학교', '초등학교'].map(x => `<option ${x === s.school_level ? 'selected' : ''}>${x}</option>`).join('')}</select></label>
        <label class="field"><span>선생님 이름 (선택)</span><input id="ob-name" value="${esc(s.teacher_name || '')}" placeholder="예: 김인회"></label>
      </div>`,
    2: () => `<h2>어떤 기록을 쓰시나요?</h2><p class="muted">해당하는 것을 모두 고르세요. 학급이 자동으로 만들어집니다. (나중에 학급·학생 메뉴에서 더 추가 가능)</p>
      <div class="source"><label class="check"><input type="checkbox" id="ob-subj-on" checked> <b>교과 세특</b> — 수업하는 반</label>
        <div class="row" style="margin-top:8px"><label class="field"><span>과목</span><input id="ob-subj" value="${esc(s.teacher_subject || '')}" placeholder="예: 국어"></label>
          <label class="field" style="flex:2"><span>수업하는 반 (쉼표로)</span><input id="ob-classes" placeholder="예: 2-1, 2-3, 2-5"></label></div></div>
      <div class="source"><label class="check"><input type="checkbox" id="ob-home-on"> <b>담임</b> — 행동특성 및 종합의견 · 자율·자치 · 진로 · 개인별 세특</label>
        <div class="row" style="margin-top:8px"><label class="field"><span>담임 학급</span><input id="ob-home" placeholder="예: 2-3"></label><span></span></div></div>
      <div class="source"><label class="check"><input type="checkbox" id="ob-club-on"> <b>동아리</b> — 동아리활동 특기사항</label>
        <div class="row" style="margin-top:8px"><label class="field"><span>동아리 이름</span><input id="ob-club" placeholder="예: 로봇탐구반"></label><span></span></div></div>`,
    3: () => `<h2>🎙 녹음을 글자로 바꾸는 방법</h2>
      <p class="muted">녹음을 <b>이 컴퓨터 안에서</b> 글자로 바꾸는 Whisper 모델(550MB)을 받아 두면, 녹음이 외부로 나가지 않고 비용도 없습니다.</p>
      <div id="ob-wh"></div>`,
    4: () => `<h2>✨ 초안을 만드는 AI</h2>
      <p class="muted">세특 초안 문장은 AI가 써 줍니다. 둘 중 편한 방법을 고르세요. 나중에 설정에서 바꿀 수 있습니다.</p>
      <div class="source"><label class="check"><input type="radio" name="ob-ai" value="manual" checked> <b>지금 쓰는 Gemini·ChatGPT 웹에 복사·붙여넣기</b> (키 필요 없음)</label>
        <p class="small muted">버튼을 누르면 학생 기록이 담긴 문구가 만들어지고, 웹 채팅에 붙여넣은 뒤 답을 다시 붙여넣습니다. '프롬프트 안내' 메뉴에 방법이 있습니다.</p></div>
      <div class="source"><label class="check"><input type="radio" name="ob-ai" value="api"> <b>Gemini API 키로 자동</b> (무료 키, 학급 전체 한 번에 생성 가능)</label>
        <p class="small muted"><a href="https://aistudio.google.com/apikey" target="_blank">aistudio.google.com/apikey</a>에서 '키 만들기' → 복사해서 붙여넣기</p>
        <input id="ob-key" type="password" placeholder="AIza로 시작하는 키 (선택)"></div>`,
  };
  const render = () => {
    modal(`<div class="small muted" style="margin-bottom:6px">${st.step} / 4</div>${steps[st.step]()}
      <div class="modal-actions">${st.step > 1 ? '<button id="ob-back">이전</button>' : '<button id="ob-skip" class="ghost">건너뛰기</button>'}
        <button class="primary" id="ob-next">${st.step === 4 ? '시작하기' : '다음'}</button></div>`, box => {
      if (st.step === 3) whisperBanner($('#ob-wh', box)).then(() => { if (!$('#ob-wh', box).innerHTML) $('#ob-wh', box).innerHTML = '<p class="ok-text">✓ 받아쓰기 준비됨 (또는 이 컴퓨터는 Gemini 받아쓰기를 사용)</p>'; });
      if ($('#ob-skip', box)) $('#ob-skip', box).onclick = async () => { await api('/api/settings', { onboarded: '1' }); closeModal(); };
      if ($('#ob-back', box)) $('#ob-back', box).onclick = () => { st.step--; render(); };
      $('#ob-next', box).onclick = async () => {
        if (st.step === 1) { st.level = $('#ob-level', box).value; st.name = $('#ob-name', box).value.trim(); }
        if (st.step === 2) {
          const mk = [];
          if ($('#ob-subj-on', box).checked) {
            const subj = $('#ob-subj', box).value.trim();
            ($('#ob-classes', box).value.match(/\d+\s*-\s*\d+/g) || []).forEach(x => { const [g, c] = x.split('-').map(v => +v.trim()); mk.push({ kind: '교과', grade: g, class_no: c, subject: subj }); });
            st.subject = subj;
          }
          if ($('#ob-home-on', box).checked) {
            const m = $('#ob-home', box).value.match(/(\d+)\s*-\s*(\d+)/);
            if (m) mk.push({ kind: '담임', grade: +m[1], class_no: +m[2] });
          }
          if ($('#ob-club-on', box).checked && $('#ob-club', box).value.trim()) mk.push({ kind: '동아리', subject: $('#ob-club', box).value.trim() });
          if (!mk.length) return toast('학급을 하나 이상 입력하세요 (예: 2-3)', true);
          st.make = mk;
        }
        if (st.step === 4) {
          const ai = ($('input[name=ob-ai]:checked', box) || {}).value;
          const key = $('#ob-key', box).value.trim();
          const vals = { onboarded: '1', school_level: st.level, teacher_name: st.name || '', teacher_subject: st.subject || '',
            mode: ai === 'api' && key ? 'api' : 'manual' };
          if (key) vals.gemini_api_key = key;
          await api('/api/settings', vals);
          for (const c of st.make) await api('/api/classes/save', Object.assign({ year: y, semester: sem }, c));
          closeModal(); updateModeBadge();
          toast('준비됐습니다! 각 학급에 학생 명단을 붙여넣으세요.');
          await loadClasses();
          location.hash = state.classes.length ? '#/class/' + state.classes[0].id : '#/classes';
          return;
        }
        st.step++; render();
      };
    });
  };
  render();
}

async function updateModeBadge() {
  const s = await api('/api/settings', undefined, { silent: true }).catch(() => null);
  if (!s) return;
  state.settings = s;
  $('#mode-badge').innerHTML = s.mode === 'manual' ? '● 수동 모드' : (s.has_key ? '<span style="color:var(--green)">●</span> API 모드 · ' + esc(s.gemini_model)
    : '<span style="color:var(--amber)">●</span> API 키 없음 — <a href="#/settings">설정</a>');
}

async function updatePending() {
  try {
    const d = await api('/api/dashboard', undefined, { silent: true });
    const p = $('#nav-pending');
    p.textContent = d.totals.pending_review; p.classList.toggle('hidden', !d.totals.pending_review);
  } catch (e) { /* */ }
}

$('#btn-quit').onclick = async () => {
  if (!confirmBox('쓰담을 종료할까요? (진행 중인 AI 작업은 중단됩니다)')) return;
  try { await api('/api/shutdown', {}); } catch (e) { /* */ }
  document.body.innerHTML = '<div class="empty"><h2>종료했습니다</h2><p>이 창을 닫아도 됩니다. 다시 쓰려면 "쓰담 시작"을 실행하세요.</p></div>';
};

document.addEventListener('focusout', () => {
  if (refreshPending && $('#modal').classList.contains('hidden')) {
    setTimeout(() => {
      const ae = document.activeElement;
      if (!ae || !(ae.dataset && ae.dataset.dirty)) { refreshPending = false; router(true); }
    }, 200);
  }
});

if (navigator.userAgent.includes('SeteukApp')) document.documentElement.classList.add('native');
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', e => e.preventDefault());

updateModeBadge();
checkUpdateBanner();
maybeOnboard();
updatePending();
setInterval(updatePending, 30000);
router(false);
pollJobs();


// 휴대폰·다른 기기와 글 기록 맞추기 (녹음은 빼고 학급·학생·관찰기록·초안만)
async function renderTextSync() {
  const box = $('#ts-box'); if (!box) return;
  const st = await api('/api/sync/text');
  const on = st.state !== '꺼짐';
  const last = st.last ? new Date(st.last * 1000).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' }) : '';
  const badge = st.state === '정상' ? '<span class="badge green">작동 중</span>' : st.state === '오류' ? '<span class="badge red">오류</span>' : '';
  box.innerHTML = `<div class="source-head"><h3>휴대폰과 기록 맞추기 <span class="badge blue">글만 · 녹음 제외</span> ${badge}</h3>
      <label class="switch"><input type="checkbox" id="ts-on" ${on ? 'checked' : ''}> 사용</label></div>
    <p>같은 Apple ID의 아이폰·아이패드 쓰담과 <b>학급·학생 명단·학생별 기록·초안</b>을 주고받습니다. 맥에서 정리하면 폰에서도 보이고, 폰에서 고친 것도 맥에 들어와요. 녹음 파일은 오가지 않아요.</p>
    <p class="muted small">${st.state === 'iCloud 쓰담 폴더 없음' ? '아이폰에 쓰담 앱을 설치하고 한 번 열면 iCloud 폴더가 생겨요.' :
      st.state === '정상' ? `마지막으로 맞춘 시각 ${last}${st.devices && st.devices.length ? ' · 함께 쓰는 기기: ' + st.devices.map(esc).join(', ') : ' · 아직 다른 기기 없음'}` :
      st.state === '오류' ? '오류: ' + esc(st.error || '') : esc(st.state || '')}</p>`;
  $('#ts-on').onchange = async e => { await api('/api/sync/text', { enabled: e.target.checked }); renderTextSync(); };
}
