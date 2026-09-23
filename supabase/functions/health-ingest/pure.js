// からだ帳 health-ingest の純粋な関数（node でも Deno でも動く・外に何も書かない）
// @ts-nocheck

/* ショートカットから届く一覧。配列でも、改行で区切った文字でも受ける */
export function toList(v) {
  if (Array.isArray(v)) return v.map((x) => String(x ?? "").trim());
  if (v == null) return [];
  return String(v).split(/\r?\n/).map((x) => x.trim()).filter((x) => x !== "");
}

/* 数字を 9・英字を a に伏せる（形だけ見る。値は残さない） */
export function mask(s) {
  return String(s ?? "").replace(/[0-9]/g, "9").replace(/[A-Za-z]/g, "a").slice(0, 40);
}

/* "2026-09-23 04:45:00+0900" / "2026-09-23 04:45:00 +0900" / "2026-09-23T04:45:00+09:00" → {day, t(ms)} */
export function parseStamp(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?\s*([+-])(\d{2}):?(\d{2})$/.exec(String(s).trim());
  if (!m) return null;
  const off = (m[7] === "-" ? -1 : 1) * (+m[8] * 60 + +m[9]);
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)) - off * 60000;
  return { day: `${m[1]}-${m[2]}-${m[3]}`, t };
}

/* "46.3" / "46,3" / "46.3 ms" → 46.3 */
export function num(s) {
  const m = /-?\d+(?:[.,]\d+)?/.exec(String(s));
  return m ? parseFloat(m[0].replace(",", ".")) : NaN;
}

export const METRICS = {
  hrv:      { how: "mean", lo: 5,   hi: 300 },
  rhr:      { how: "mean", lo: 30,  hi: 130 },
  exercise: { how: "sum",  lo: 0,   hi: 1440 },
  weight:   { how: "last", lo: 20,  hi: 300 },
  walk:     { how: "mean", lo: 0.5, hi: 12 },
};

/* 数量の指標を日ごとにまとめる。limit 件ちょうど届いたら、いちばん古い日は途中までかもしれないので捨てる */
export function aggregate(metric, dates, values, limit) {
  const def = METRICS[metric];
  if (!def) throw new Error("unknown metric");
  const byDay = new Map();
  const n = Math.min(dates.length, values.length);
  for (let i = 0; i < n; i++) {
    const p = parseStamp(dates[i]), v = num(values[i]);
    if (!p || !isFinite(v) || v < def.lo || v > def.hi) continue;
    if (!byDay.has(p.day)) byDay.set(p.day, []);
    byDay.get(p.day).push([p.t, v]);
  }
  let days = [...byDay.keys()].sort();
  if (limit && dates.length >= limit && days.length) days = days.slice(1);
  return days.map((d) => {
    const a = byDay.get(d).sort((x, y) => x[0] - y[0]);
    const v = def.how === "sum" ? a.reduce((s, x) => s + x[1], 0)
            : def.how === "last" ? a[a.length - 1][1]
            : a.reduce((s, x) => s + x[1], 0) / a.length;
    return { day: d, metric, value: Math.round(v * 10) / 10 };
  });
}

/* 睡眠の段階の文字（英語・日本語のどちらでも） */
export function stageOf(s) {
  const x = String(s).trim().toLowerCase();
  if (/(awake|覚醒|起きて)/.test(x)) return "awake";
  if (/(in ?bed|ベッド|就床)/.test(x)) return "inbed";
  if (/(core|コア|deep|深い|rem|レム)/.test(x)) return "staged";
  if (/(asleep|unspecified|睡眠|眠)/.test(x)) return "asleep";
  return "unknown";
}

/* 睡眠：すき間3時間以内をひと続きにし、終わった日にいちばん長い眠りの分を付ける（health_import.py と同じ考え方） */
export function aggregateSleep(starts, ends, values, limit) {
  const spans = [];
  const n = Math.min(starts.length, ends.length, values.length);
  for (let i = 0; i < n; i++) {
    const st = stageOf(values[i]);
    if (st !== "staged" && st !== "asleep") continue;
    const a = parseStamp(starts[i]), b = parseStamp(ends[i]);
    if (!a || !b || b.t <= a.t) continue;
    spans.push({ s: a.t, e: b.t, eday: b.day, staged: st === "staged" });
  }
  spans.sort((x, y) => x.s - y.s);
  const GAP = 3 * 3600e3, groups = [];
  let cur = [], curEnd = -Infinity;
  for (const sp of spans) {
    if (cur.length && sp.s - curEnd > GAP) { groups.push(cur); cur = []; curEnd = -Infinity; }
    cur.push(sp); curEnd = Math.max(curEnd, sp.e);
  }
  if (cur.length) groups.push(cur);
  const best = new Map();
  groups.forEach((g, gi) => {
    if (limit && starts.length >= limit && gi === 0) return;   // いちばん古いまとまりは途中までかもしれない
    let use = g.some((x) => x.staged) ? g.filter((x) => x.staged) : g;
    use = use.slice().sort((x, y) => x.s - y.s);
    let total = 0, cs = null, ce = null, eday = use[0].eday, maxE = -Infinity;
    for (const x of use) {
      if (x.e > maxE) { maxE = x.e; eday = x.eday; }
      if (ce === null || x.s > ce) { if (ce !== null) total += ce - cs; cs = x.s; ce = x.e; }
      else if (x.e > ce) ce = x.e;
    }
    if (ce !== null) total += ce - cs;
    const mins = Math.round(total / 60000);
    if (mins >= 30 && mins > (best.get(eday) || 0)) best.set(eday, mins);
  });
  return [...best.entries()].sort().map(([day, value]) => ({ day, metric: "sleep", value }));
}

/* 送信テスト版：形だけを返す（数字は伏せる。睡眠の段階の文字だけはそのまま＝健康の値ではない） */
export function probeInfo(metric, dates, ends, values) {
  const kinds = [...new Set(values.map((v) => (metric === "sleep" ? String(v).slice(0, 20) : mask(v))))].slice(0, 12);
  return {
    n_dates: dates.length, n_ends: ends.length, n_values: values.length,
    date_shape: mask(dates[0] ?? ""), end_shape: mask(ends[0] ?? ""),
    parsed: dates.length ? !!parseStamp(dates[0]) : null,
    value_kinds: kinds,
  };
}
