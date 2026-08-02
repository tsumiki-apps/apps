/* ============================================================
   ics.js — ICS(iCalendar) を「埋まっている時間帯」だけに潰す純粋関数
   ------------------------------------------------------------
   ・Edge Function(Deno) と Node(テスト) の両方でそのまま動く素の JS。
   ・予定の中身は「読まない」。パースの時点でホワイトリスト方式にしてあり、
     SUMMARY / LOCATION / DESCRIPTION / ATTENDEE / ORGANIZER / URL は
     メモリにすら載らない（＝あとで捨て忘れる事故が起きない）。
   ・戻り値は { uid, occ, startMs, endMs, allDay } だけ。uid は呼び出し側で
     ハッシュ化してから保存する（生の UID にメールアドレスを埋める実装が
     あるため、DB には残さない）。
   ============================================================ */

export const DEFAULT_ZONE = 'Asia/Tokyo';   // TZID も Z も無い「浮動時刻」の解釈先

/* ------------------------------------------------------------
   1. 行の組み立て（アンフォールド）とプロパティ解析
   ------------------------------------------------------------ */

/** RFC5545 の折り返し（次行が空白/タブ始まり＝前行の続き）を戻す */
function unfold(text) {
  const src = text.replace(/^﻿/, '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const out = [];
  for (const raw of src.split('\n')) {
    if (raw === '') continue;
    if ((raw[0] === ' ' || raw[0] === '\t') && out.length) out[out.length - 1] += raw.slice(1);
    else out.push(raw);
  }
  return out;
}

/** `NAME;PARAM=x;P2="a:b":VALUE` を {name, params, value} に割る */
function parseProp(line) {
  let i = 0, inQ = false;
  for (; i < line.length; i++) {
    const c = line[i];
    if (c === '"') inQ = !inQ;
    else if (c === ':' && !inQ) break;
  }
  if (i >= line.length) return null;
  const head = line.slice(0, i);
  const value = line.slice(i + 1);

  const segs = [];
  let cur = '';
  inQ = false;
  for (const c of head) {
    if (c === '"') { inQ = !inQ; cur += c; }
    else if (c === ';' && !inQ) { segs.push(cur); cur = ''; }
    else cur += c;
  }
  segs.push(cur);

  const params = {};
  for (let k = 1; k < segs.length; k++) {
    const eq = segs[k].indexOf('=');
    if (eq < 0) continue;
    const pn = segs[k].slice(0, eq).toUpperCase();
    let pv = segs[k].slice(eq + 1);
    if (pv.length > 1 && pv[0] === '"' && pv[pv.length - 1] === '"') pv = pv.slice(1, -1);
    params[pn] = pv;
  }
  return { name: segs[0].toUpperCase().trim(), params, value };
}

/** 読み取るプロパティの許可リスト。ここに無いものは一切保持しない */
const KEEP = {
  VCALENDAR: ['METHOD'],
  VEVENT: ['UID', 'DTSTART', 'DTEND', 'DURATION', 'RRULE', 'RDATE', 'EXDATE',
           'RECURRENCE-ID', 'STATUS', 'TRANSP'],
  VTIMEZONE: ['TZID'],
  STANDARD: ['DTSTART', 'TZOFFSETFROM', 'TZOFFSETTO', 'RRULE'],
  DAYLIGHT: ['DTSTART', 'TZOFFSETFROM', 'TZOFFSETTO', 'RRULE'],
};

/** ICS 全文 → コンポーネント木（許可リストのプロパティだけを持つ） */
function parseComponents(text) {
  const root = { type: 'ROOT', props: [], children: [] };
  const stack = [root];
  for (const line of unfold(text)) {
    const p = parseProp(line);
    if (!p) continue;
    if (p.name === 'BEGIN') {
      const node = { type: p.value.toUpperCase().trim(), props: [], children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
      continue;
    }
    if (p.name === 'END') {
      if (stack.length > 1) stack.pop();
      continue;
    }
    const cur = stack[stack.length - 1];
    const allow = KEEP[cur.type];
    if (allow && allow.indexOf(p.name) >= 0) cur.props.push(p);
  }
  return root;
}

const propAll = (node, name) => node.props.filter(p => p.name === name);
const prop = (node, name) => node.props.find(p => p.name === name) || null;

/* ------------------------------------------------------------
   2. タイムゾーン
   ------------------------------------------------------------
   「素の年月日時分秒（＝壁の時計が指す時刻）」を naive ミリ秒
   （Date.UTC で作った値）で持ち回り、最後に実際の UTC 時刻へ直す。
   ------------------------------------------------------------ */

const naive = (y, mo, d, h, mi, s) => Date.UTC(y, mo - 1, d, h, mi, s);
function fieldsOf(ms) {
  const dt = new Date(ms);
  return {
    y: dt.getUTCFullYear(), mo: dt.getUTCMonth() + 1, d: dt.getUTCDate(),
    h: dt.getUTCHours(), mi: dt.getUTCMinutes(), s: dt.getUTCSeconds(),
    wd: dt.getUTCDay(),
  };
}

const _dtf = new Map();
function dtfFor(tz) {
  let f = _dtf.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23',
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    _dtf.set(tz, f);
  }
  return f;
}

/** その瞬間における tz の UTC からのずれ（ミリ秒） */
function ianaOffsetMs(utcMs, tz) {
  const g = {};
  for (const part of dtfFor(tz).formatToParts(new Date(utcMs))) {
    if (part.type !== 'literal') g[part.type] = Number(part.value);
  }
  return Date.UTC(g.year, g.month - 1, g.day, g.hour % 24, g.minute, g.second) - utcMs;
}

/** Windows 形式の TZID を IANA 名に寄せる（Outlook 配信のカレンダー対策） */
const WIN_TZ = {
  'TOKYO STANDARD TIME': 'Asia/Tokyo',
  'KOREA STANDARD TIME': 'Asia/Seoul',
  'CHINA STANDARD TIME': 'Asia/Shanghai',
  'SINGAPORE STANDARD TIME': 'Asia/Singapore',
  'W. EUROPE STANDARD TIME': 'Europe/Berlin',
  'ROMANCE STANDARD TIME': 'Europe/Paris',
  'GMT STANDARD TIME': 'Europe/London',
  'PACIFIC STANDARD TIME': 'America/Los_Angeles',
  'MOUNTAIN STANDARD TIME': 'America/Denver',
  'CENTRAL STANDARD TIME': 'America/Chicago',
  'EASTERN STANDARD TIME': 'America/New_York',
  'UTC': 'UTC',
};

function ianaUsable(tz) {
  try { dtfFor(tz).format(new Date(0)); return true; } catch (_) { return false; }
}

function parseUtcOffset(v) {
  const m = /^([+-])(\d{2})(\d{2})(\d{2})?$/.exec((v || '').trim());
  if (!m) return null;
  const sign = m[1] === '-' ? -1 : 1;
  return sign * ((+m[2]) * 3600 + (+m[3]) * 60 + (+(m[4] || 0))) * 1000;
}

const ZONE_UTC = { kind: 'fixed', offsetMs: 0, id: 'UTC' };

/**
 * TZID → ゾーン記述子を返す関数を作る。
 *  ① Intl が知っている名前ならそれを使う（IANA / Windows 名の読み替え込み）
 *  ② 知らない名前でも ICS 内の VTIMEZONE があれば固定オフセットとして使う
 *  ③ どちらも駄目なら JST 扱いにして warning を出す
 */
function makeZoneResolver(root, warnings) {
  const vtz = new Map();
  for (const node of root.children) {
    for (const c of (node.type === 'VCALENDAR' ? node.children : [])) {
      if (c.type !== 'VTIMEZONE') continue;
      const idp = prop(c, 'TZID');
      if (!idp) continue;
      const offs = [];
      for (const sub of c.children) {
        const to = prop(sub, 'TZOFFSETTO');
        if (to) offs.push({ type: sub.type, offsetMs: parseUtcOffset(to.value) });
      }
      vtz.set(idp.value.trim(), offs.filter(o => o.offsetMs !== null));
    }
  }

  const cache = new Map();
  return function resolve(tzid) {
    if (!tzid) return { kind: 'iana', tz: DEFAULT_ZONE, id: DEFAULT_ZONE };
    const key = tzid.trim();
    if (cache.has(key)) return cache.get(key);

    let zone = null;
    const direct = key.replace(/^\//, '');                 // 「/Asia/Tokyo」形式も来る
    if (ianaUsable(direct)) zone = { kind: 'iana', tz: direct, id: direct };
    if (!zone) {
      const mapped = WIN_TZ[key.toUpperCase()];
      if (mapped && ianaUsable(mapped)) zone = { kind: 'iana', tz: mapped, id: mapped };
    }
    if (!zone && vtz.has(key)) {
      const offs = vtz.get(key);
      if (offs.length) {
        const uniq = new Set(offs.map(o => o.offsetMs));
        const std = offs.find(o => o.type === 'STANDARD') || offs[0];
        if (uniq.size > 1) {
          warnings.push(`TZID "${key}" は夏時間つきだが Intl が知らないため、標準時のオフセット固定として扱った`);
        }
        zone = { kind: 'fixed', offsetMs: std.offsetMs, id: key };
      }
    }
    if (!zone) {
      warnings.push(`TZID "${key}" を解決できないため ${DEFAULT_ZONE} として扱った`);
      zone = { kind: 'iana', tz: DEFAULT_ZONE, id: DEFAULT_ZONE };
    }
    cache.set(key, zone);
    return zone;
  };
}

/** 壁時計の時刻（naive ms）→ 実際の UTC ミリ秒 */
export function naiveToUtc(naiveMs, zone) {
  if (zone.kind === 'fixed') return naiveMs - zone.offsetMs;
  const tz = zone.tz;
  let t = naiveMs - ianaOffsetMs(naiveMs, tz);
  t = naiveMs - ianaOffsetMs(t, tz);           // 1回戻して再計算すれば通常は収束する
  return t;
}

/* ------------------------------------------------------------
   3. 日時プロパティ
   ------------------------------------------------------------ */

/** DTSTART / DTEND / RECURRENCE-ID などの値を読む */
function readDateValue(p, resolve) {
  const v = (p.value || '').trim();
  const isDate = p.params.VALUE === 'DATE' || /^\d{8}$/.test(v);
  if (isDate) {
    const m = /^(\d{4})(\d{2})(\d{2})$/.exec(v);
    if (!m) return null;
    // 終日は「その日の 0:00（既定ゾーン）」を基準にする
    const zone = p.params.TZID ? resolve(p.params.TZID) : { kind: 'iana', tz: DEFAULT_ZONE, id: DEFAULT_ZONE };
    return { allDay: true, naiveMs: naive(+m[1], +m[2], +m[3], 0, 0, 0), zone };
  }
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$/.exec(v);
  if (!m) return null;
  const zone = m[7] ? ZONE_UTC : resolve(p.params.TZID);
  return {
    allDay: false,
    naiveMs: naive(+m[1], +m[2], +m[3], +m[4], +m[5], +m[6]),
    zone,
  };
}

/** ISO8601 期間 → ミリ秒 */
export function parseDuration(v) {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec((v || '').trim());
  if (!m) return null;
  const sign = m[1] === '-' ? -1 : 1;
  const w = +(m[2] || 0), d = +(m[3] || 0), h = +(m[4] || 0), mi = +(m[5] || 0), s = +(m[6] || 0);
  return sign * ((((w * 7 + d) * 24 + h) * 3600) + mi * 60 + s) * 1000;
}

/** カンマ区切りの複数値プロパティ（EXDATE / RDATE）を全部読む */
function readDateList(p, resolve) {
  const out = [];
  for (const one of (p.value || '').split(',')) {
    const t = one.trim();
    if (!t) continue;
    if (t.indexOf('/') >= 0) { out.push({ period: t }); continue; }  // RDATE の期間形式（後述で無視）
    const r = readDateValue({ name: p.name, params: p.params, value: t }, resolve);
    if (r) out.push(r);
  }
  return out;
}

/* ------------------------------------------------------------
   4. 繰り返し（RRULE）の展開
   ------------------------------------------------------------
   壁時計フィールドの上で回すので、DST のある地域でも「毎週9時」が
   9時のままになる。BYSETPOS / BYHOUR / BYMINUTE は未対応（警告を出す）。
   ------------------------------------------------------------ */

const WD = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
const MAX_PERIODS = 4000;      // 暴走よけ
const MAX_INSTANCES = 2000;

function parseRRule(value) {
  const r = {};
  for (const part of (value || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    r[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1);
  }
  const byday = (r.BYDAY || '').split(',').filter(Boolean).map(t => {
    const m = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(t.trim().toUpperCase());
    return m ? { ord: m[1] ? +m[1] : 0, wd: WD[m[2]] } : null;
  }).filter(Boolean);
  return {
    freq: (r.FREQ || '').toUpperCase(),
    interval: Math.max(1, +(r.INTERVAL || 1) || 1),
    count: r.COUNT ? +r.COUNT : null,
    untilRaw: r.UNTIL || null,
    byday,
    bymonthday: (r.BYMONTHDAY || '').split(',').filter(Boolean).map(Number),
    bymonth: (r.BYMONTH || '').split(',').filter(Boolean).map(Number),
    wkst: WD[(r.WKST || 'MO').toUpperCase()] ?? 1,
    unsupported: ['BYSETPOS', 'BYYEARDAY', 'BYWEEKNO', 'BYHOUR', 'BYMINUTE'].filter(k => k in r),
  };
}

const daysInMonth = (y, mo) => new Date(Date.UTC(y, mo, 0)).getUTCDate();

/** 月 mo の中で条件に合う「日」を列挙 */
function monthDays(y, mo, rule, startD) {
  const dim = daysInMonth(y, mo);
  const out = new Set();
  if (rule.bymonthday.length) {
    for (const md of rule.bymonthday) {
      const d = md > 0 ? md : dim + md + 1;
      if (d >= 1 && d <= dim) out.add(d);
    }
  } else if (rule.byday.length) {
    for (const bd of rule.byday) {
      const hits = [];
      for (let d = 1; d <= dim; d++) {
        if (new Date(Date.UTC(y, mo - 1, d)).getUTCDay() === bd.wd) hits.push(d);
      }
      if (!bd.ord) hits.forEach(d => out.add(d));
      else {
        const pick = bd.ord > 0 ? hits[bd.ord - 1] : hits[hits.length + bd.ord];
        if (pick) out.add(pick);
      }
    }
  } else if (startD <= dim) {
    out.add(startD);                                    // 既定は DTSTART と同じ日
  }
  return [...out].sort((a, b) => a - b);
}

/**
 * RRULE を展開して、instance の壁時計ミリ秒（naive）の配列を返す。
 * winEndNaive を超えたら打ち切る（COUNT/UNTIL とは別の実務上の上限）。
 */
function expandRRule(rule, startNaive, winEndNaive, warnings) {
  const st = fieldsOf(startNaive);
  const timeMs = ((st.h * 60 + st.mi) * 60 + st.s) * 1000;
  const out = [];
  let emitted = 0;

  const push = (y, mo, d) => {
    const ms = naive(y, mo, d, 0, 0, 0) + timeMs;
    if (ms < startNaive) return true;
    emitted++;
    if (rule.count !== null && emitted > rule.count) return false;
    if (ms <= winEndNaive) out.push(ms);
    return out.length < MAX_INSTANCES;
  };

  const monthOk = mo => !rule.bymonth.length || rule.bymonth.indexOf(mo) >= 0;
  const dayOk = (y, mo, d) => {
    if (rule.bymonthday.length && rule.bymonthday.indexOf(d) < 0 &&
        rule.bymonthday.indexOf(d - daysInMonth(y, mo) - 1) < 0) return false;
    if (rule.byday.length) {
      const wd = new Date(Date.UTC(y, mo - 1, d)).getUTCDay();
      if (!rule.byday.some(b => b.wd === wd)) return false;
    }
    return true;
  };

  if (rule.freq === 'DAILY') {
    for (let n = 0; n < MAX_PERIODS; n++) {
      const base = naive(st.y, st.mo, st.d, 0, 0, 0) + n * rule.interval * 86400000;
      if (base > winEndNaive) break;
      const f = fieldsOf(base);
      if (monthOk(f.mo) && dayOk(f.y, f.mo, f.d)) { if (!push(f.y, f.mo, f.d)) break; }
    }
  } else if (rule.freq === 'WEEKLY') {
    const wds = rule.byday.length ? rule.byday.map(b => b.wd) : [st.wd];
    const shift = (st.wd - rule.wkst + 7) % 7;
    const weekTop = naive(st.y, st.mo, st.d, 0, 0, 0) - shift * 86400000;
    let stop = false;
    for (let n = 0; n < MAX_PERIODS && !stop; n++) {
      const top = weekTop + n * rule.interval * 7 * 86400000;
      if (top > winEndNaive + 7 * 86400000) break;
      for (let k = 0; k < 7; k++) {
        const cur = top + k * 86400000;
        const f = fieldsOf(cur);
        if (wds.indexOf(f.wd) < 0 || !monthOk(f.mo)) continue;
        if (!push(f.y, f.mo, f.d)) { stop = true; break; }
      }
    }
  } else if (rule.freq === 'MONTHLY' || rule.freq === 'YEARLY') {
    const stepMonths = rule.freq === 'MONTHLY' ? rule.interval : rule.interval * 12;
    let stop = false;
    for (let n = 0; n < MAX_PERIODS && !stop; n++) {
      const y = st.y + Math.floor((st.mo - 1 + n * stepMonths) / 12);
      const mo = ((st.mo - 1 + n * stepMonths) % 12) + 1;
      if (naive(y, mo, 1, 0, 0, 0) > winEndNaive) break;
      const months = rule.freq === 'YEARLY' && rule.bymonth.length ? rule.bymonth : [mo];
      for (const m2 of months) {
        if (rule.freq === 'MONTHLY' && !monthOk(m2)) continue;
        for (const d of monthDays(y, m2, rule, st.d)) {
          if (!push(y, m2, d)) { stop = true; break; }
        }
        if (stop) break;
      }
    }
  } else {
    warnings.push(`FREQ=${rule.freq || '(なし)'} は未対応のため、この繰り返しは初回のみとして扱った`);
    out.push(startNaive);
  }

  return out.filter(ms => ms <= winEndNaive).sort((a, b) => a - b);
}

/* ------------------------------------------------------------
   5. 本体
   ------------------------------------------------------------ */

/**
 * ICS 全文 → 埋まり時間の配列。
 * @param {string} text          ICS 全文
 * @param {object} opt           { fromMs, toMs }  展開する期間（UTC ミリ秒）
 * @returns {{rows:Array, warnings:string[], skipped:object}}
 *          rows: { uid, occ, startMs, endMs, allDay }（startMs 昇順）
 */
export function parseIcs(text, opt) {
  const fromMs = opt && opt.fromMs != null ? opt.fromMs : Date.parse('1970-01-01T00:00:00Z');
  const toMs = opt && opt.toMs != null ? opt.toMs : Date.parse('2100-01-01T00:00:00Z');
  const warnings = [];
  const skipped = { cancelled: 0, transparent: 0, noStart: 0, outOfWindow: 0 };

  const root = parseComponents(text);
  const resolve = makeZoneResolver(root, warnings);

  const cals = root.children.filter(c => c.type === 'VCALENDAR');
  const events = [];
  for (const cal of cals) {
    const method = prop(cal, 'METHOD');
    if (method && method.value.trim().toUpperCase() === 'CANCEL') {
      warnings.push('METHOD:CANCEL のカレンダーのため、この取り込みは0件にした');
      return { rows: [], warnings, skipped };
    }
    for (const ev of cal.children) if (ev.type === 'VEVENT') events.push(ev);
  }
  // BEGIN:VCALENDAR が無い壊れかけの ICS も一応拾う
  if (!cals.length) for (const ev of root.children) if (ev.type === 'VEVENT') events.push(ev);

  // UID ごとに「本体」と「個別変更（RECURRENCE-ID つき）」に仕分ける
  const byUid = new Map();
  for (const ev of events) {
    const uidP = prop(ev, 'UID');
    const uid = uidP ? uidP.value.trim() : '';
    if (!byUid.has(uid)) byUid.set(uid, { masters: [], overrides: [] });
    (prop(ev, 'RECURRENCE-ID') ? byUid.get(uid).overrides : byUid.get(uid).masters).push(ev);
  }

  const out = [];
  const addRow = (uid, startMs, endMs, allDay, occLabel) => {
    if (endMs <= fromMs || startMs >= toMs) { skipped.outOfWindow++; return; }
    out.push({ uid, occ: occLabel, startMs, endMs, allDay });
  };

  /** 1件の VEVENT から「開始・終了・終日か」を取り出す共通部分 */
  function readCore(ev) {
    const dsP = prop(ev, 'DTSTART');
    if (!dsP) { skipped.noStart++; return null; }
    const ds = readDateValue(dsP, resolve);
    if (!ds) { skipped.noStart++; return null; }

    let durMs = null;
    const deP = prop(ev, 'DTEND');
    if (deP) {
      const de = readDateValue(deP, resolve);
      if (de) durMs = naiveToUtc(de.naiveMs, de.zone) - naiveToUtc(ds.naiveMs, ds.zone);
    } else {
      const duP = prop(ev, 'DURATION');
      if (duP) durMs = parseDuration(duP.value);
    }
    if (durMs === null || durMs < 0) {
      // DTEND も DURATION も無い場合：終日なら1日、時刻ありなら長さ0（RFC5545 準拠）
      durMs = ds.allDay ? 86400000 : 0;
    }
    if (ds.allDay && durMs === 0) durMs = 86400000;
    return { ds, durMs };
  }

  for (const [uid, group] of byUid) {
    // --- 個別変更を先に処理し、本体側から差し引く時刻を集める ---
    const overrideAt = new Set();
    const overrideRows = [];
    for (const ev of group.overrides) {
      const ridP = prop(ev, 'RECURRENCE-ID');
      const rid = readDateValue(ridP, resolve);
      if (rid) overrideAt.add(naiveToUtc(rid.naiveMs, rid.zone));
      if ((ridP.params.RANGE || '').toUpperCase() === 'THISANDFUTURE') {
        warnings.push('RECURRENCE-ID;RANGE=THISANDFUTURE は未対応（その1回だけの変更として扱った）');
      }
      const status = prop(ev, 'STATUS');
      if (status && status.value.trim().toUpperCase() === 'CANCELLED') { skipped.cancelled++; continue; }
      const transp = prop(ev, 'TRANSP');
      if (transp && transp.value.trim().toUpperCase() === 'TRANSPARENT') { skipped.transparent++; continue; }
      const core = readCore(ev);
      if (!core) continue;
      const s = naiveToUtc(core.ds.naiveMs, core.ds.zone);
      overrideRows.push({ s, e: s + core.durMs, allDay: core.ds.allDay,
                          occ: rid ? new Date(naiveToUtc(rid.naiveMs, rid.zone)).toISOString() : new Date(s).toISOString() });
    }

    // --- 本体（繰り返しの元）を展開 ---
    for (const ev of group.masters) {
      const status = prop(ev, 'STATUS');
      if (status && status.value.trim().toUpperCase() === 'CANCELLED') { skipped.cancelled++; continue; }
      const transp = prop(ev, 'TRANSP');
      if (transp && transp.value.trim().toUpperCase() === 'TRANSPARENT') { skipped.transparent++; continue; }
      const core = readCore(ev);
      if (!core) continue;
      const { ds, durMs } = core;

      // 除外日（EXDATE）と追加日（RDATE）
      const exSet = new Set();
      for (const p of propAll(ev, 'EXDATE')) {
        for (const d of readDateList(p, resolve)) {
          if (d.period) continue;
          exSet.add(naiveToUtc(d.naiveMs, d.zone));
        }
      }
      const extra = [];
      for (const p of propAll(ev, 'RDATE')) {
        for (const d of readDateList(p, resolve)) {
          if (d.period) { warnings.push('RDATE の期間形式（開始/終了）は未対応のため無視した'); continue; }
          extra.push(naiveToUtc(d.naiveMs, d.zone));
        }
      }

      let startsUtc;
      const rrP = prop(ev, 'RRULE');
      if (rrP) {
        const rule = parseRRule(rrP.value);
        if (rule.unsupported.length) {
          warnings.push(`RRULE の ${rule.unsupported.join('/')} は未対応（無視して展開した）`);
        }
        // UNTIL は絶対時刻なので、壁時計→UTC に直したあとで切る
        //（COUNT と UNTIL は RFC 上どちらか片方しか出てこないので順序を気にしなくてよい）
        let untilUtc = null;
        if (rule.untilRaw) {
          const u = readDateValue({ name: 'UNTIL', params: {}, value: rule.untilRaw }, resolve);
          if (u) untilUtc = naiveToUtc(u.naiveMs, u.allDay ? ds.zone : u.zone) + (u.allDay ? 86400000 - 1 : 0);
        }
        const winEndNaive = toMs + 2 * 86400000;   // 壁時計の窓は少し広めに取り、あとで実時刻で切る
        startsUtc = expandRRule(rule, ds.naiveMs, winEndNaive, warnings)
          .map(n => naiveToUtc(n, ds.zone));
        if (untilUtc !== null) startsUtc = startsUtc.filter(s => s <= untilUtc);
      } else {
        startsUtc = [naiveToUtc(ds.naiveMs, ds.zone)];
      }

      for (const s of startsUtc.concat(extra)) {
        if (exSet.has(s) || overrideAt.has(s)) continue;
        addRow(uid, s, s + durMs, ds.allDay, new Date(s).toISOString());
      }
    }

    for (const r of overrideRows) addRow(uid, r.s, r.e, r.allDay, r.occ);
  }

  // 同じ UID×開始時刻が重複したら1つに畳む
  const seen = new Set();
  const rows = [];
  for (const r of out.sort((a, b) => a.startMs - b.startMs || a.endMs - b.endMs)) {
    const k = r.uid + '|' + r.occ;
    if (seen.has(k)) continue;
    seen.add(k);
    rows.push(r);
  }
  return { rows, warnings: [...new Set(warnings)], skipped };
}
