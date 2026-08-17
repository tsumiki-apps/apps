/* ============================================================
   career.js — つみき Work活動の足跡を残す共通ライブラリ
   ------------------------------------------------------------
   ・各Workアプリに <script src="career.js"></script> を1行入れるだけ。
   ・ページを開くと「visit（足跡）」を自動記録。
   ・保存などの節目では各アプリが Career.log(...) を呼んで「実績」を記録。
   ・記録はまず localStorage に必ず残り（即時・オフラインOK）、
     Supabaseの career_log テーブルがあればそこにも同期（端末をまたいで永続）。
   ・career.html がこのログを読み、年表・統計・レジュメ素材に変換する。
   ============================================================ */
(function () {
  "use strict";

  const SUPABASE_URL  = "https://okbjqtdirrathscctyvx.supabase.co";
  const SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rYmpxdGRpcnJhdGhzY2N0eXZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjI4NTIsImV4cCI6MjA5NTg5ODg1Mn0.T-1AOK6vCD6uGdqrVGXjPui3L6WPSNrnygS-IHyfZ6Y";
  /* career_log への読み書きは合言葉つきのRPC経由（直接テーブルは触れない） */
  const LOCAL_KEY     = "tsumikiCareerLog";       // 配列：ローカルキャッシュ兼・未同期キュー
  const SESSION_VISIT = "tsumikiCareerVisited";   // セッション中の重複visit防止

  /* ---- 合言葉（Workアプリ共通の鍵） ----------------------------------
     ・同僚の氏名・写真・面談記録が入るテーブルは anon から閉じてあり、
       読み書きは合言葉つきのRPC経由でしか通らない。
     ・合言葉そのものは保存せず、PBKDF2で伸ばした鍵だけを localStorage に置く。
       同一オリジンなので Work アプリ全部でこの1つを共有＝端末ごとに1回で済む。
     ・鍵は DB 側でも sha256 でしか保持しないので、DBを覗いても合言葉は割れない。
  ------------------------------------------------------------------- */
  const KEY_STORE = "tsumikiAppKey";
  const KDF_SALT  = "tsumiki-app-lock-v1";
  const KDF_ITER  = 150000;

  async function deriveToken(pass) {
    const enc = new TextEncoder();
    const base = await crypto.subtle.importKey("raw", enc.encode(pass), "PBKDF2", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits(
      { name: "PBKDF2", salt: enc.encode(KDF_SALT), iterations: KDF_ITER, hash: "SHA-256" }, base, 256);
    return Array.from(new Uint8Array(bits)).map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  let cachedTok = null, declined = false, pendingTok = null;

  /* silent=true なら聞かない（未設定なら null を返してローカル保存に留める） */
  async function getToken(silent) {
    if (cachedTok) return cachedTok;
    try { cachedTok = localStorage.getItem(KEY_STORE) || null; } catch (e) {}
    if (cachedTok) return cachedTok;
    if (silent || declined) return null;
    if (pendingTok) return pendingTok;

    pendingTok = (async () => {
      if (!(window.crypto && window.crypto.subtle)) { declined = true; return null; }
      const pass = window.prompt(
        "つみき（Work）の合言葉\n\nこの端末では初回だけ入力します。\n入力しない場合、記録はこの端末の中だけに残ります。");
      if (!pass) { declined = true; return null; }
      let t = null;
      try { t = await deriveToken(pass); } catch (e) { declined = true; return null; }
      try { localStorage.setItem(KEY_STORE, t); } catch (e) {}
      cachedTok = t;
      return t;
    })();

    const r = await pendingTok;
    pendingTok = null;
    return r;
  }

  function forgetToken() {
    cachedTok = null; declined = false;
    try { localStorage.removeItem(KEY_STORE); } catch (e) {}
  }

  /* どのファイルがどのツールか（index.html のメニューと対応） */
  const APPS = {
    nps:        { label: "NPS 目標達成 計算ツール", emoji: "📊", genre: "work" },
    recap:      { label: "Weekly Recap",          emoji: "📈", genre: "work" },
    recognition:{ label: "Recognition",           emoji: "🌟", genre: "work" },
    grownote:   { label: "GROW ノート",            emoji: "🌳", genre: "work" },
    team5whys:  { label: "5Whys ノート",           emoji: "🔍", genre: "work" },
    reflection: { label: "STARS 振り返り",          emoji: "🪞", genre: "work" },
    vault:      { label: "Password manager",      emoji: "🔐", genre: "work" },
    osusowake:  { label: "おすそわけ",              emoji: "🎁", genre: "work" },
    schedule:   { label: "スケジュール→カレンダー",  emoji: "🗓️", genre: "work" },
  };

  function currentApp() {
    const meta = document.querySelector('meta[name="career-app"]');
    if (meta && meta.content) return meta.content;
    const stem = (location.pathname.split("/").pop() || "").replace(/\.html$/i, "");
    return stem || "";
  }

  /* ---- Supabaseクライアント（CDNを遅延ロード） ---- */
  let sbPromise = null;
  function getSB() {
    if (sbPromise) return sbPromise;
    sbPromise = new Promise((resolve) => {
      if (window.supabase && window.supabase.createClient) {
        resolve(window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON));
        return;
      }
      const s = document.createElement("script");
      s.src = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2";
      s.onload  = () => resolve(window.supabase ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON) : null);
      s.onerror = () => resolve(null);
      document.head.appendChild(s);
    });
    return sbPromise;
  }

  /* ---- ローカルストレージ ---- */
  function readLocal() {
    try { return JSON.parse(localStorage.getItem(LOCAL_KEY) || "[]"); } catch (e) { return []; }
  }
  function writeLocal(arr) {
    try { localStorage.setItem(LOCAL_KEY, JSON.stringify(arr.slice(-3000))); } catch (e) {}
  }
  function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }

  /* 同一 app+action+summary が短時間に連続したら畳む（autosave対策） */
  function isDup(list, ev, windowMs) {
    for (let i = list.length - 1; i >= 0 && i >= list.length - 50; i--) {
      const x = list[i];
      if (x.app === ev.app && x.action === ev.action &&
          (x.summary || "") === (ev.summary || "") &&
          Math.abs((x.ts || 0) - ev.ts) < windowMs) return true;
    }
    return false;
  }

  function rowFor(ev) {
    return {
      id: ev.id, app: ev.app, app_label: ev.app_label, action: ev.action,
      summary: ev.summary, meta: ev.meta, genre: ev.genre, created_at: ev.created_at
    };
  }

  /* 足跡の自動記録で合言葉を聞かれると鬱陶しいので、push は silent。
     鍵が無いあいだはローカルのキューに溜まり、鍵が入った後の flushQueue で送られる。 */
  async function pushRemote(row) {
    try {
      const sb = await getSB();
      if (!sb) return false;
      const tok = await getToken(true);
      if (!tok) return false;
      const { error } = await sb.rpc("career_log_add", { p_token: tok, p_row: row });
      return !error;
    } catch (e) { return false; }
  }

  let flushing = false;
  async function flushQueue() {
    if (flushing) return;
    flushing = true;
    try {
      const list = readLocal();
      const pending = list.filter((x) => !x.synced);
      if (!pending.length) return;
      const sb = await getSB();
      if (!sb) return;
      for (const ev of pending) {
        const ok = await pushRemote(rowFor(ev));
        if (ok) ev.synced = true;
      }
      writeLocal(list);
    } finally { flushing = false; }
  }

  /* ---- 公開API：実績を1件記録 ---- */
  function log(opts) {
    opts = opts || {};
    const app = opts.app || currentApp();
    const meta = APPS[app];
    // opts.at（ISO文字列）が指定されればその日時を採用（手動の過去実績など）
    const when = opts.at ? new Date(opts.at) : new Date();
    const ev = {
      id: uid(),
      app: app,
      app_label: (meta && meta.label) || app,
      action: opts.action || "event",
      summary: opts.summary || "",
      meta: opts.meta || null,
      genre: opts.genre || (meta && meta.genre) || "other",
      ts: when.getTime(),
      created_at: when.toISOString(),
      synced: false,
    };
    const list = readLocal();
    const win = (opts.dedupeMs != null) ? opts.dedupeMs : 60000;
    if (win > 0 && isDup(list, ev, win)) return null;   // 重複は畳む
    list.push(ev);
    writeLocal(list);
    pushRemote(rowFor(ev)).then((ok) => {
      if (ok) { const l = readLocal(); const e = l.find((x) => x.id === ev.id); if (e) { e.synced = true; writeLocal(l); } }
    });
    return ev;
  }

  /* ---- 足跡（visit）：Workアプリを開いたら1セッション1回だけ ---- */
  function visit() {
    const app = currentApp();
    const meta = APPS[app];
    if (!meta || meta.genre !== "work") return;
    let seen = {};
    try { seen = JSON.parse(sessionStorage.getItem(SESSION_VISIT) || "{}"); } catch (e) {}
    if (seen[app]) { flushQueue(); return; }
    seen[app] = 1;
    try { sessionStorage.setItem(SESSION_VISIT, JSON.stringify(seen)); } catch (e) {}
    log({ app, action: "visit", summary: meta.label + " を開いた", dedupeMs: 6 * 3600 * 1000 });
  }

  /* ---- ログ全件取得（remote優先・localとマージ） ---- */
  async function getAll() {
    const local = readLocal();
    let remote = [];
    let connected = false;
    try {
      const sb = await getSB();
      if (sb) {
        /* 年表を見にきた場面なので、ここは必要なら合言葉を聞く */
        const tok = await getToken(false);
        if (tok) {
          const { data, error } = await sb.rpc("career_log_list", { p_token: tok });
          if (!error) { remote = data || []; connected = true; }
        }
      }
    } catch (e) {}
    const byId = {};
    remote.forEach((r) => { byId[r.id] = Object.assign({}, r, { ts: Date.parse(r.created_at) || 0 }); });
    local.forEach((l) => { if (!byId[l.id]) byId[l.id] = l; });
    const merged = Object.values(byId).sort((a, b) => (b.ts || 0) - (a.ts || 0));
    return { items: merged, connected };
  }

  /* ---- 1件削除（remote+local両方） ---- */
  async function remove(id) {
    const l = readLocal().filter((x) => x.id !== id);
    writeLocal(l);
    try {
      const sb = await getSB();
      const tok = await getToken(false);
      if (sb && tok) await sb.rpc("career_log_remove", { p_token: tok, p_id: id });
    } catch (e) {}
  }

  window.Career = { log, visit, getAll, remove, flushQueue, APPS, _getSB: getSB, _readLocal: readLocal };

  /* Workアプリ共通の鍵。recognition / grownote / reflection / team5whys が使う */
  window.Tsumiki = { getToken: getToken, forgetToken: forgetToken, deriveToken: deriveToken, KEY_STORE: KEY_STORE };

  /* 読み込み時に自動で足跡＋未同期分の再送 */
  function boot() { visit(); flushQueue(); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
