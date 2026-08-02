/* ICS解析（ics.js）のテスト。実データにも実画面にも一切触らない純粋関数テスト。
   実行: cd ~/制作物/akima-src && node test-ics.mjs                          */
import { readFileSync } from 'node:fs';
import { parseIcs } from './ics.js';

let ok = 0, ng = 0;
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { ok++; }
  else { ng++; console.log(`  ✗ ${name}\n      期待: ${w}\n      実際: ${g}`); }
};
const yes = (name, cond) => { if (cond) ok++; else { ng++; console.log(`  ✗ ${name}`); } };

/** UTCミリ秒 → 「M/D HH:MM」の日本時間表記（読みやすさ用） */
const jst = ms => new Date(ms + 9 * 3600000).toISOString().replace('T', ' ').slice(5, 16);
const span = r => `${jst(r.startMs)}〜${jst(r.endMs)}${r.allDay ? '(終日)' : ''}`;

const WIN = { fromMs: Date.parse('2026-08-01T00:00:00+09:00'), toMs: Date.parse('2026-11-01T00:00:00+09:00') };

/* ============================================================
   1. 会社シフト想定のカレンダー
   ============================================================ */
console.log('■ work.ics');
const work = parseIcs(readFileSync('./samples/work.ics', 'utf8'), WIN);
const W = new Map();
for (const r of work.rows) {
  if (!W.has(r.uid)) W.set(r.uid, []);
  W.get(r.uid).push(span(r));
}
const g = uid => W.get(uid) || [];

eq('TZID付きの通常シフト', g('shift-normal@example'), ['08-03 09:00〜08-03 18:00']);
eq('遅番', g('shift-late@example'), ['08-04 13:00〜08-04 22:00']);
eq('日をまたぐ夜勤', g('shift-overnight@example'), ['08-05 22:00〜08-06 07:00']);
eq('終日1日（DTENDは翌日＝排他）', g('allday-off@example'), ['08-07 00:00〜08-08 00:00(終日)']);
eq('終日2日連続', g('allday-two@example'), ['08-15 00:00〜08-17 00:00(終日)']);
eq('UTC(Z)表記→JST', g('shift-utc@example'), ['08-10 10:00〜08-10 19:00']);
eq('DURATION指定', g('shift-duration@example'), ['08-11 09:00〜08-11 17:30']);
eq('浮動時刻はJST扱い', g('shift-floating@example'), ['08-12 09:00〜08-12 17:30']);
eq('STATUS:CANCELLED は除外', g('cancelled@example'), []);
eq('TRANSP:TRANSPARENT は除外', g('transparent@example'), []);
eq('折り返し行(TZIDが2行に割れている)', g('folded-line@example'), ['09-18 11:00〜09-18 12:00']);

// 週次×5回、うち 8/17 は EXDATE で消え、8/24 は RECURRENCE-ID で 14:00 に移動
eq('RRULE + EXDATE + RECURRENCE-ID', g('weekly-meeting@example'), [
  '08-03 10:00〜08-03 11:00',
  '08-10 10:00〜08-10 11:00',
  '08-24 14:00〜08-24 15:30',
  '08-31 10:00〜08-31 11:00',
]);
// UNTIL は「UTCの絶対時刻」。20260904T235959Z は JST の 9/5 08:59:59 なので、
// JST 9/5 08:30 の回はまだ範囲内に入る（ここを日付だけで切ると1日ずれる）
eq('RRULE UNTIL は UTC絶対時刻で切る（JSTだと9/5朝まで入る）', g('daily-until@example'), [
  '09-01 08:30〜09-01 08:45', '09-02 08:30〜09-02 08:45',
  '09-03 08:30〜09-03 08:45', '09-04 08:30〜09-04 08:45',
  '09-05 08:30〜09-05 08:45',
]);

// 予定の中身は一切拾っていないこと（rowsのキーを検査）
const keys = [...new Set(work.rows.flatMap(r => Object.keys(r)))].sort();
eq('保持するキーは開始/終了/終日/識別子だけ', keys, ['allDay', 'endMs', 'occ', 'startMs', 'uid']);
yes('SUMMARY等の文字列がどこにも残っていない',
  !JSON.stringify(work.rows).includes('レジ') && !JSON.stringify(work.rows).includes('someone@'));

/* ============================================================
   2. Outlook / 変則TZID
   ============================================================ */
console.log('■ outlook.ics');
const ol = parseIcs(readFileSync('./samples/outlook.ics', 'utf8'), WIN);
const O = new Map();
for (const r of ol.rows) { if (!O.has(r.uid)) O.set(r.uid, []); O.get(r.uid).push(span(r)); }
const o = uid => O.get(uid) || [];

eq('Windows形式 TZID="Tokyo Standard Time"', o('win-tz@example'), ['09-01 10:00〜09-01 11:30']);
eq('VTIMEZONEにしか無いTZID(+0800)→JSTで11時', o('custom-tz@example'), ['09-02 11:00〜09-02 12:00']);
eq('毎月第2火曜×3', o('monthly-2tu@example'), [
  '08-11 19:00〜08-11 20:00', '09-08 19:00〜09-08 20:00', '10-13 19:00〜10-13 20:00',
]);
eq('DTEND/DURATION無しは長さ0', o('no-dtend@example'), ['09-03 12:00〜09-03 12:00']);

/* ============================================================
   3. 端のケース
   ============================================================ */
console.log('■ 端のケース');
const mk = body => `BEGIN:VCALENDAR\nVERSION:2.0\n${body}\nEND:VCALENDAR\n`;
const one = (body, win) => parseIcs(mk(body), win || WIN).rows.map(span);

eq('予定ゼロのICS', parseIcs(mk(''), WIN).rows, []);
eq('METHOD:CANCEL のカレンダーは丸ごと0件',
  parseIcs(mk('METHOD:CANCEL\nBEGIN:VEVENT\nUID:x\nDTSTART:20260901T010000Z\nDTEND:20260901T020000Z\nEND:VEVENT'), WIN).rows, []);

eq('0時ちょうど始まり', one('BEGIN:VEVENT\nUID:a\nDTSTART;TZID=Asia/Tokyo:20260901T000000\nDTEND;TZID=Asia/Tokyo:20260901T060000\nEND:VEVENT'),
  ['09-01 00:00〜09-01 06:00']);
eq('24時＝翌0時ちょうど終わり', one('BEGIN:VEVENT\nUID:b\nDTSTART;TZID=Asia/Tokyo:20260901T200000\nDTEND;TZID=Asia/Tokyo:20260902T000000\nEND:VEVENT'),
  ['09-01 20:00〜09-02 00:00']);
eq('窓の外（前）は落とす',
  one('BEGIN:VEVENT\nUID:c\nDTSTART;TZID=Asia/Tokyo:20260701T090000\nDTEND;TZID=Asia/Tokyo:20260701T100000\nEND:VEVENT'), []);
eq('窓の外（後）は落とす',
  one('BEGIN:VEVENT\nUID:d\nDTSTART;TZID=Asia/Tokyo:20261201T090000\nDTEND;TZID=Asia/Tokyo:20261201T100000\nEND:VEVENT'), []);
eq('窓にまたがる長い予定は残す',
  one('BEGIN:VEVENT\nUID:e\nDTSTART;TZID=Asia/Tokyo:20260731T200000\nDTEND;TZID=Asia/Tokyo:20260801T060000\nEND:VEVENT'),
  ['07-31 20:00〜08-01 06:00']);
eq('同一UID・同一開始の重複は畳む',
  one('BEGIN:VEVENT\nUID:f\nDTSTART;TZID=Asia/Tokyo:20260901T090000\nDTEND;TZID=Asia/Tokyo:20260901T100000\nEND:VEVENT\n' +
      'BEGIN:VEVENT\nUID:f\nDTSTART;TZID=Asia/Tokyo:20260901T090000\nDTEND;TZID=Asia/Tokyo:20260901T100000\nEND:VEVENT'),
  ['09-01 09:00〜09-01 10:00']);
eq('DTSTARTが無い壊れイベントは飛ばす',
  parseIcs(mk('BEGIN:VEVENT\nUID:g\nSUMMARY:壊れ\nEND:VEVENT'), WIN).rows, []);
eq('CRLF改行も読める',
  parseIcs('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:h\r\nDTSTART;TZID=Asia/Tokyo:20260901T090000\r\n' +
           'DTEND;TZID=Asia/Tokyo:20260901T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n', WIN).rows.map(span),
  ['09-01 09:00〜09-01 10:00']);
eq('RDATE で回数外の日を足せる',
  one('BEGIN:VEVENT\nUID:i\nDTSTART;TZID=Asia/Tokyo:20260901T090000\nDTEND;TZID=Asia/Tokyo:20260901T100000\n' +
      'RDATE;TZID=Asia/Tokyo:20260905T090000,20260907T090000\nEND:VEVENT'),
  ['09-01 09:00〜09-01 10:00', '09-05 09:00〜09-05 10:00', '09-07 09:00〜09-07 10:00']);
eq('米国TZのイベントもJSTに正規化（PDT 09-01 10:00 = JST 09-02 02:00）',
  one('BEGIN:VEVENT\nUID:j\nDTSTART;TZID=America/Los_Angeles:20260901T100000\nDTEND;TZID=America/Los_Angeles:20260901T110000\nEND:VEVENT'),
  ['09-02 02:00〜09-02 03:00']);

console.log(`\n合計 ${ok + ng} 件 / 成功 ${ok} / 失敗 ${ng}`);
if (work.warnings.length) console.log('warnings(work):', work.warnings);
if (ol.warnings.length) console.log('warnings(outlook):', ol.warnings);
process.exit(ng ? 1 : 0);
