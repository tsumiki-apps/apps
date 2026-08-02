/* ============================================================
   akima-sync — 照会カレンダー(ICS)を取りに行って「埋まり時間」だけDBに入れる
   ------------------------------------------------------------
   ・照会URLはサーバー側にだけ置く。ブラウザにもHTMLにも一切出さないし、
     エラーメッセージにも混ぜない。置き場は次の順に見る：
       ① public.akima_feed テーブル（アプリから差し替えられる。読み出しはここだけ）
       ② 環境変数 AKIMA_WORK_ICS_URL / AKIMA_PRIVATE_ICS_URL（予備）
   ・予定の中身は ics.js の時点で読んでいない。ここが扱うのは時刻だけ。
   ・UID はハッシュ化してから保存する（生UIDにメールアドレスを入れる実装があるため）。
   ============================================================ */
import { parseIcs } from './ics.js';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FEEDS: Record<string, { envKey: string; kind: string }> = {
  work:    { envKey: 'AKIMA_WORK_ICS_URL',    kind: 'work' },
  private: { envKey: 'AKIMA_PRIVATE_ICS_URL', kind: 'private' },
};

const PAST_DAYS = 7;      // 過去はこれだけ残す
const FUTURE_DAYS = 90;   // 未来はここまで展開する
const MAX_BYTES = 8 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 25000;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

/** service_role で akima_feed から URL を読む（ここだけがURLを見る） */
async function feedUrls(): Promise<Record<string, string>> {
  const r = await fetch(`${SB_URL}/rest/v1/akima_feed?select=source,url`, {
    headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}` },
  });
  if (!r.ok) return {};
  const rows = await r.json().catch(() => []);
  const out: Record<string, string> = {};
  for (const row of rows as Array<{ source: string; url: string }>) out[row.source] = row.url;
  return out;
}

/** service_role で RPC を呼ぶ */
async function rpc(fn: string, body: unknown) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SB_SERVICE,
      Authorization: `Bearer ${SB_SERVICE}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`rpc ${fn} ${r.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

/** sha256(uid|occ) の先頭32文字。生のUIDはDBに残さない */
async function occKey(uid: string, occ: string) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${uid}|${occ}`));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

/**
 * ICS を取りに行く。
 * 失敗しても URL は絶対に外へ出さないので、例外は自前の短い文言に作り替える。
 */
async function fetchIcs(rawUrl: string): Promise<string> {
  const url = rawUrl.trim().replace(/^webcal:\/\//i, 'https://');
  if (!/^https:\/\//i.test(url)) throw new Error('照会URLが https:// でも webcal:// でもない');

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetch(url, {
      signal: ctl.signal,
      redirect: 'follow',
      headers: { 'Accept': 'text/calendar, text/plain, */*', 'User-Agent': 'akima/1.0' },
    });
  } catch (_e) {
    throw new Error('照会カレンダーに接続できなかった（ネットワークかURLの形式）');
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) throw new Error(`照会カレンダーが HTTP ${res.status} を返した`);

  const len = Number(res.headers.get('content-length') || 0);
  if (len > MAX_BYTES) throw new Error('照会カレンダーが大きすぎる（8MB超）');
  const text = await res.text();
  if (text.length > MAX_BYTES) throw new Error('照会カレンダーが大きすぎる（8MB超）');
  if (!/BEGIN:VCALENDAR/i.test(text)) {
    throw new Error('取得できた中身がICSではない（ログイン画面などが返っている可能性）');
  }
  return text;
}

/** ICS本文 → DBへ取り込み */
async function ingest(source: string, kind: string, ics: string, fromMs: number, toMs: number) {
  const { rows, warnings, skipped } = parseIcs(ics, { fromMs, toMs });

  const seen = new Set<string>();
  const payload: Array<Record<string, unknown>> = [];
  for (const r of rows) {
    const k = await occKey(r.uid, r.occ);
    if (seen.has(k)) continue;
    seen.add(k);
    payload.push({
      occ_key: k,
      start_at: new Date(r.startMs).toISOString(),
      end_at: new Date(r.endMs).toISOString(),
      all_day: r.allDay,
    });
  }

  const n = await rpc('akima_ingest', {
    p_source: source,
    p_kind: kind,
    p_from: new Date(fromMs).toISOString(),
    p_to: new Date(toMs).toISOString(),
    p_rows: payload,
    p_warnings: warnings,
  });
  return { count: payload.length, saved: n, warnings, skipped };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  let body: any = {};
  try { body = await req.json(); } catch (_e) { /* 空ボディも許す */ }

  // アプリのアクセスキーで認可（照会URLとは別物。DBの akima_config が正）
  let allowed = false;
  try { allowed = await rpc('akima_ok', { p_key: String(body.key ?? '') }); }
  catch (e) { return json({ error: 'auth check failed', detail: String(e).slice(0, 200) }, 500); }
  if (!allowed) return json({ error: 'bad key' }, 401);

  const now = Date.now();
  const fromMs = now - PAST_DAYS * 86400000;
  const toMs = now + FUTURE_DAYS * 86400000;

  // ---- 手動アップロード（.ics を書き出して投げる経路）----
  if (typeof body.ics === 'string' && body.ics.length) {
    const source = FEEDS[body.source] ? String(body.source) : 'work';
    try {
      const r = await ingest(source, FEEDS[source].kind, body.ics, fromMs, toMs);
      return json({ ok: true, mode: 'upload', results: [{ source, ...r }] });
    } catch (e) {
      await rpc('akima_sync_fail', { p_source: source, p_detail: String(e).slice(0, 200) }).catch(() => {});
      return json({ ok: false, mode: 'upload', error: String(e).slice(0, 200) }, 500);
    }
  }

  // ---- URL から取得 ----
  const want: string[] = body.source && FEEDS[body.source] ? [String(body.source)] : Object.keys(FEEDS);
  const results: Array<Record<string, unknown>> = [];
  let anyOk = false;
  const fromDb = await feedUrls().catch(() => ({} as Record<string, string>));

  for (const source of want) {
    const { envKey, kind } = FEEDS[source];
    const url = fromDb[source] || Deno.env.get(envKey);
    if (!url) { results.push({ source, skipped: '照会カレンダーのURLが未登録' }); continue; }
    try {
      const ics = await fetchIcs(url);
      const r = await ingest(source, kind, ics, fromMs, toMs);
      results.push({ source, ok: true, ...r });
      anyOk = true;
    } catch (e) {
      // e には URL を混ぜていない（fetchIcs が自前の文言に作り替えている）
      const detail = (e instanceof Error ? e.message : String(e)).slice(0, 200);
      await rpc('akima_sync_fail', { p_source: source, p_detail: detail }).catch(() => {});
      results.push({ source, ok: false, error: detail });
    }
  }

  return json({ ok: anyOk, mode: 'fetch', at: new Date(now).toISOString(), results }, anyOk ? 200 : 502);
});
