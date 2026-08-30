#!/usr/bin/env node
'use strict';

// つみきリモート — Mac の tmux セッションをスマホから見て指示するための小さなサーバー。
// 依存パッケージなし（Node 標準ライブラリだけ）。tmux にコマンドを投げているだけ。

const http = require('http');
const fs = require('fs');
const fsp = require('fs/promises');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const PORT = Number(process.env.TSUMIKI_REMOTE_PORT || 8787);
const HOST = process.env.TSUMIKI_REMOTE_HOST || '127.0.0.1';
const CONF_DIR = path.join(os.homedir(), '.tsumiki-remote');
const TOKEN_FILE = path.join(CONF_DIR, 'token');
const PUBLIC_DIR = path.join(__dirname, 'public');

const TMUX = [process.env.TMUX_BIN, '/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']
  .filter(Boolean)
  .find((p) => fs.existsSync(p)) || 'tmux';

// ---------------------------------------------------------------- トークン

fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
if (!fs.existsSync(TOKEN_FILE)) {
  fs.writeFileSync(TOKEN_FILE, crypto.randomBytes(24).toString('hex'), { mode: 0o600 });
}
const TOKEN = fs.readFileSync(TOKEN_FILE, 'utf8').trim();

// つみきリモートから起動する Claude Code のコマンド。
// 環境変数で上書きできる（普通の権限確認つきに戻したいときは
// TSUMIKI_CLAUDE_CMD=claude を LaunchAgent に足す）。
const CLAUDE_CMD = process.env.TSUMIKI_CLAUDE_CMD || 'claude --permission-mode bypassPermissions';

// ＋Claude で選べるモデル。画面から来た文字はそのままシェルの行に混ぜるので、
// ここに書いてあるものだけを通す（自由な文字を許すとコマンドを継ぎ足せてしまう）。
// 'default' ＝ Claude Code のおすすめ（Opus 5・1M 文脈）。
// 起動時の --model はその席だけに効き、Mac 側の既定は書き換えない（2026-08-13 実機確認）
const MODELS = ['default', 'opus', 'fable', 'sonnet', 'haiku'];

// ---------------------------------------------------------------- 版（バージョン）
//
// スマホの「ホーム画面アプリ」は一度開くと開きっぱなしになる。Mac 側でアプリを
// 直しても、開いたままの画面は古いままなので、押したボタンが古い動きをする
// （2026-08-11：削除済みの /api/kill を呼び続けて「押しても何も起きない」になった）。
// 中身のハッシュを「版」として配り、変わったらブラウザ側で読み込み直させる。
//
// ⚠️ 版に server.js を混ぜないこと（2026-08-12）。server.js を保存した瞬間に
// 版が変わるが、動いているサーバーは再起動するまで古いままなので、その読み直しは
// 何も新しくならない＝ムダに画面が切り替わるだけ。サーバー側の変更が実際に効くのは
// 再起動したときなので、そのタイミング＝起動ごとの通し番号（BOOT）を版に混ぜる。
// これで「画面のファイルが変わった」か「サーバーが入れ替わった」ときだけ読み直す。
const BOOT = crypto.randomBytes(3).toString('hex');
const VER_FILES = [path.join(PUBLIC_DIR, 'index.html'), path.join(PUBLIC_DIR, 'sw.js')];
let verCache = { key: null, value: '0' };

function currentVersion() {
  let key = '';
  for (const f of VER_FILES) {
    try { const st = fs.statSync(f); key += `${st.mtimeMs}:${st.size}|`; }
    catch (e) { key += 'x|'; }
  }
  if (key !== verCache.key) {
    const h = crypto.createHash('sha1');
    for (const f of VER_FILES) { try { h.update(fs.readFileSync(f)); } catch (e) {} }
    verCache = { key, value: BOOT + '-' + h.digest('hex').slice(0, 8) };
  }
  return verCache.value;
}

// ------------------------------------------------------------ Claude の残量
//
// Claude Code の `/usage` が使っているのと同じ口に、キーチェーンにある
// ログイン情報で問い合わせて「5時間枠」と「週枠」をどれだけ使ったかを取る。
//
// ⚠️ これは公開仕様ではない（いつ形が変わってもおかしくない）。だから
// 取れなかったら黙って諦める＝スマホ側は残量バーが消えるだけで、他は普通に動く。
//
// スマホは1.5秒ごとに状態を聞きに来る。それをそのまま外へ投げると叩きすぎで
// 弾かれるので、ここで60秒ためておき、/api/state にはその写しを乗せる。
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
// ⚠️ 60秒ごとに取りにいって**叩きすぎで止められた**（2026-08-31）。
// 経緯：キーチェーンのトークンが切れて 401 が数回 → そのまま1分ごとに叩き続けたら
// 429（rate_limit_error）に変わり、以後 2243回連続で429＝**37時間バーが消えたまま**。
// 相手は `retry-after` で「何秒待て」と言ってくるのに、それを無視して叩き直すので
// 待ち時間が延び続け、自力では二度と戻らない状態になっていた。
// 直しかた＝①ふだんの間隔を5分に伸ばす ②429 のときは retry-after を必ず守る
// ③それ以外の失敗も倍々で待つ ④待っているあいだは前の値を長めに出しておく。
const USAGE_TTL = 5 * 60 * 1000;    // これより新しければ取り直さない
const USAGE_KEEP = 60 * 60 * 1000;  // 取れなくなっても、これだけは前の値を出す
let usageCache = { at: 0, value: null };
let usageFetching = null;
let usageRetryAt = 0;               // この時刻までは取りにいかない（相手に言われた待ち時間）
let usageFails = 0;                 // 連続して失敗した回数（倍々で待つのに使う）

// 失敗したときの待ち時間を決めて記録する。ms を返す（ログ用）
function usageBackoff(status, retryAfter) {
  let wait;
  if (status === 429) {
    // 相手が秒数をくれたらそれに従う（+5秒の余裕）。くれなければ15分
    const ra = parseInt(retryAfter || '', 10);
    wait = ((Number.isFinite(ra) && ra > 0 ? Math.min(ra, 6 * 3600) : 900) + 5) * 1000;
  } else {
    // 401（トークン切れ）や通信の失敗。5分 → 10 → 20 …最大60分。
    // ここを1分で叩き続けたのが、そもそも429を招いた原因
    usageFails++;
    wait = Math.min(60 * 60 * 1000, USAGE_TTL * Math.pow(2, Math.min(4, usageFails - 1)));
  }
  usageRetryAt = Date.now() + wait;
  return wait;
}

// キーチェーンからアクセストークンを読むだけ。書き戻しはしない
// （自前で更新すると Claude Code 側のログインを壊しかねない）。
function keychainToken() {
  return new Promise((resolve) => {
    execFile('/usr/bin/security',
      ['find-generic-password', '-s', 'Claude Code-credentials', '-w'],
      { timeout: 5000 },
      (err, stdout) => {
        if (err) return resolve(null);
        try {
          const o = JSON.parse(stdout);
          const t = o && o.claudeAiOauth && o.claudeAiOauth.accessToken;
          resolve(typeof t === 'string' && t ? t : null);
        } catch (e) { resolve(null); }
      });
  });
}

// {utilization, resets_at} → {used, resetsAt}。数字が入っていなければ null。
function usageBucket(b) {
  if (!b || typeof b.utilization !== 'number' || !isFinite(b.utilization)) return null;
  return {
    used: Math.max(0, Math.min(100, Math.round(b.utilization))),
    resetsAt: typeof b.resets_at === 'string' ? b.resets_at : null,
  };
}

async function fetchUsage() {
  const token = await keychainToken();
  if (!token) return null;
  const ctl = new AbortController();
  const to = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch(USAGE_URL, {
      headers: {
        authorization: 'Bearer ' + token,
        'anthropic-beta': 'oauth-2025-04-20',
        'user-agent': 'tsumiki-remote',
      },
      signal: ctl.signal,
    });
    if (!r.ok) {
      const wait = usageBackoff(r.status, r.headers.get('retry-after'));
      console.log(`usage ${r.status} → ${Math.round(wait / 1000)}秒待つ`);
      return null;
    }
    const d = await r.json();
    const session = usageBucket(d.five_hour);
    const week = usageBucket(d.seven_day);
    if (!session && !week) return null;
    usageFails = 0;
    usageRetryAt = 0;
    return { session, week };
  } catch (e) {
    const wait = usageBackoff(0, null);
    console.log('usage ' + String(e && e.message).slice(0, 80)
      + ` → ${Math.round(wait / 1000)}秒待つ`);
    return null;
  } finally {
    clearTimeout(to);
  }
}

// 待たせない。古ければ裏で取り直しにいって、いま持っている写しを返す
// （状態の一覧が残量の取得を待って遅くなると、画面全体がもたつく）。
function usageSnapshot() {
  const age = Date.now() - usageCache.at;
  // usageRetryAt ＝ 相手に「まだ来るな」と言われている時刻。ここを見ないと、
  // 止められているあいだも1分ごとに叩き続けて、待ち時間が延び続ける
  if (age > USAGE_TTL && !usageFetching && Date.now() >= usageRetryAt) {
    usageFetching = fetchUsage()
      .then((v) => {
        // 取れなかったときは、少しの間だけ前の値を出し続ける（一瞬の失敗で
        // バーが消えたり出たりするのを防ぐ）。それも古くなったら消す。
        if (v) usageCache = { at: Date.now(), value: v };
        else if (Date.now() - usageCache.at > USAGE_KEEP) usageCache = { at: Date.now(), value: null };
      })
      .finally(() => { usageFetching = null; });
  }
  return usageCache.value;
}

// ---------------------------------------------------------- MacBook の電池
//
// 出先から見ているとき、いちばん困るのは Mac の電池が切れること。切れた瞬間に
// 全部のセッションが消えて、こちらからは何が起きたのかも分からなくなる。
//
// pmset は速い（10ms 前後）が、スマホは1.5秒ごとに聞きに来る。そのたびに
// プロセスを起こしていたら、残量を見るために電池を削ることになる。30秒ためる。
const BATT_TTL = 30 * 1000;
let battCache = { at: 0, value: null };
let battFetching = null;

// 例) -InternalBattery-0 (id=...)  64%; discharging; 3:21 remaining present: true
// 電池のない Mac（mini 等）はこの行が出ない → null＝スマホ側は何も出さない。
// 残り時間は「(no estimate)」になることがあるので、無くても諦めない
function parseBatt(out) {
  const m = /(\d+)%;\s*([A-Za-z ]+);/.exec(out);
  if (!m) return null;
  const state = m[2].trim().toLowerCase();
  const t = /(\d+):(\d+)\s+remaining/.exec(out);
  const min = t ? Number(t[1]) * 60 + Number(t[2]) : 0;
  return {
    pct: Math.max(0, Math.min(100, Number(m[1]))),
    ac: /'AC Power'/.test(out),
    charging: state === 'charging' || state === 'finishing charge',
    // 0:00 は「計算中」か「満充電」。時間として見せると嘘になる
    remainMin: min > 0 ? min : null,
  };
}

function batterySnapshot() {
  if (Date.now() - battCache.at > BATT_TTL && !battFetching) {
    battFetching = new Promise((resolve) => {
      execFile('/usr/bin/pmset', ['-g', 'batt'], { timeout: 4000 }, (err, stdout) => {
        // 取れなければ黙って消す。電池表示が出ないだけで他は普通に動く
        battCache = { at: Date.now(), value: err ? null : parseBatt(stdout || '') };
        resolve();
      });
    }).finally(() => { battFetching = null; });
  }
  return battCache.value;
}

// ---------------------------------------------------------------- tmux

const NAME_RE = /^[A-Za-z0-9_.-]{1,32}$/;

// 複数行の指示を貼り付けるときに使う、名前つきの控え置き場
const PASTE_BUF = 'tsumiki-remote';

// LaunchAgent から起動すると LANG が空になり、tmux が UTF-8 モードにならない。
// そのままだと日本語の指示を送ったときに1バイトずつ化ける。-u と合わせて明示する。
const TMUX_ENV = Object.assign({}, process.env, {
  LANG: process.env.LANG || 'ja_JP.UTF-8',
  LC_CTYPE: process.env.LC_CTYPE || 'ja_JP.UTF-8',
});

function tmux(args, { timeout = 5000 } = {}) {
  return new Promise((resolve) => {
    execFile(TMUX, ['-u'].concat(args), { timeout, env: TMUX_ENV, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: stdout || '', err: (stderr || '') + (err ? String(err.message) : '') });
    });
  });
}

// 本文を標準入力から渡す版（load-buffer 用）。指示の本文を引数に混ぜると、
// 長文で「引数が長すぎる」に当たるうえ、記号の扱いも面倒になる
function tmuxStdin(args, input) {
  return new Promise((resolve) => {
    const cp = execFile(TMUX, ['-u'].concat(args), { timeout: 5000, env: TMUX_ENV },
      (err, stdout, stderr) => {
        resolve({ ok: !err, out: stdout || '', err: (stderr || '') + (err ? String(err.message) : '') });
      });
    cp.stdin.on('error', () => {});   // 先に閉じられても落とさない
    cp.stdin.end(input);
  });
}

// ------------------------------------------------------- 端末の寸法（幅と高さ）
//
// tmux は誰も繋いでいないと 80x24 で作られる（default-size）。Claude Code は
// 「80桁ある前提」で枠を描くので、スマホ（実測 約47〜55桁）では必ず折り返し、
// 罫線が散らばって読めなくなる（2026-08-13）。
// なので「スマホに入る桁数」を画面側で測って送ってもらい、その幅に合わせる。
// 高さは画面に合わせない。Claude Code は端末が短いと自分で中身を畳んで
// 「✂ 7 lines hidden」にしてしまう＝スマホにそもそも届かなくなるため、
// 畳まれない程度に高く固定する。
const ROWS = 45;
const COLS_MIN = 40;
const COLS_MAX = 120;
const COLS_DEFAULT = 60;

function clampCols(v) {
  const n = Math.round(Number(v));
  if (!isFinite(n)) return null;
  return Math.max(COLS_MIN, Math.min(COLS_MAX, n));
}

// いま何桁にしてあるか。毎回 tmux を叩くと2秒おきの取得のたびに resize が走るので、
// 変わったときだけ動かす（同じ幅で resize しても実害はないが、無駄に SIGWINCH が飛ぶ）
const sized = new Map();

async function resizeWindow(name, cols) {
  if (!NAME_RE.test(name)) return;
  const want = clampCols(cols);
  if (!want) return;
  if (sized.get(name) === want) return;
  sized.set(name, want);
  await tmux(['resize-window', '-t', '=' + name + ':', '-x', String(want), '-y', String(ROWS)]);
  // resize-window はその窓を window-size manual に切り替える。そのままだと
  // MacBook のターミナルから繋いだときも 60桁のままになってしまうので、
  // 「最後に繋いだ相手に合わせる」既定に戻す（いまの寸法はそのまま残る）
  await tmux(['set-window-option', '-t', '=' + name + ':', 'window-size', 'latest']);
}

// tmux は書式出力中のタブを "_" に潰すので、区切りには使えない
const SEP = '|::|';

// 「本当に0件」と「tmux が答えなかった」は区別する。混ぜると、一時的な失敗を
// 「セッションが1つも無い」と誤読して、間違った案内や判定をしてしまう。
const NO_SERVER_RE = /no server running|error connecting to|no such file or directory/i;

// 「どのモデルで始めたか」の覚え場所。tmux のセッションに付ける自前の印
// （@ で始まる名前はユーザー用の置き場として tmux が用意している）。
// 席と一緒に消えるので後始末が要らず、サーバーを入れ替えても残る。
// ⚠️ 覚えているのは「始めたときに選んだもの」だけ。あとから中で /model を
//    打って変えた場合は追いかけられない（外から見る手がかりが無い）。
const MODEL_OPT = '@tsumiki_model';

async function listSessions() {
  const r = await tmux(['list-sessions', '-F',
    `#{session_name}${SEP}#{window_name}${SEP}#{session_activity}${SEP}#{${MODEL_OPT}}`]);
  if (!r.ok) return { ok: NO_SERVER_RE.test(r.err), sessions: [] };
  const sessions = r.out
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [name, window, activity, model] = line.split(SEP);
      return { name, window, activity: Number(activity) || 0, model: (model || '').trim() };
    });
  return { ok: true, sessions };
}

// そのセッションについて「何が動いているか」「題名」「どこ」を1回で取る。
// ここが見えないと「AIに話しかけたつもりがシェルに打っていた」が起きる。
async function paneInfo(name) {
  const empty = { cmd: '', title: '', cwd: '' };
  if (!NAME_RE.test(name)) return empty;
  const r = await tmux(['display-message', '-p', '-t', '=' + name + ':',
    `#{pane_current_command}${SEP}#{pane_title}${SEP}#{pane_current_path}`]);
  if (!r.ok) return empty;
  const [cmd, title, cwd] = r.out.trim().split(SEP);
  return { cmd: (cmd || '').trim(), title: (title || '').trim(), cwd: (cwd || '').trim() };
}

// 一覧に出す題名。work1 のような機械の名前ではどれがどれか分からないので、
// Claude Code がターミナルの題名に書いている「いま何をしているか」を使う
//   例: ⠐ つみきリモートの閉じるボタン機能を修正
// 何も書かれていなければ（素のシェル等）ホスト名やパスが入っているだけなので、
// それらは題名とみなさずフォルダ名に落とし、最後はセッション名に戻す。
const MACHINE = os.hostname();
const SPINNER_RE = /^[⠀-⣿✻✽✶✳✢◐◑◒◓*·•\s]+/; // 先頭の点字スピナー等（◐◑◒◓＝回る半円）

function titleOf(info, name) {
  let t = String(info.title || '').replace(SPINNER_RE, '').trim();
  if (t === MACHINE || t === MACHINE.replace(/\.local$/, '') || /^\S+@\S+$/.test(t)) t = '';
  if (/^[~/]/.test(t)) t = path.basename(t);
  if (t === '~' || t === '/' || t === '.') t = '';
  if (!t && info.cwd) t = path.basename(info.cwd);
  return (t || name).slice(0, 60);
}

function kindOf(cmd) {
  if (/^claude/i.test(cmd)) return 'claude';
  if (/^(codex|gemini|aider)/i.test(cmd)) return 'agent';
  if (/^(zsh|bash|sh|fish)$/i.test(cmd)) return 'shell';
  return 'other';
}

// いま見えている画面だけ（状態判定はこちらを使う。履歴を混ぜると
// 一度出た「Do you want…」がいつまでも残って返答待ちに見えてしまう）
async function captureScreen(name) {
  if (!NAME_RE.test(name)) return null;
  const r = await tmux(['capture-pane', '-p', '-t', '=' + name + ':']);
  return r.ok ? r.out.replace(/\s+$/, '') : null;
}

// 履歴込み（画面表示はこちら）
async function captureHistory(name, lines) {
  if (!NAME_RE.test(name)) return null;
  const r = await tmux(['capture-pane', '-p', '-t', '=' + name + ':', '-S', '-' + Math.max(1, Math.min(2000, lines))]);
  return r.ok ? r.out.replace(/\s+$/, '') : null;
}

// ------------------------------------------------------- 状態の判定ロジック

// 「返答待ち」= エージェントが許可や選択を求めて止まっている画面の特徴
const WAITING_RE = new RegExp(
  [
    'Do you want',
    'Do you trust',
    '❯\\s*1\\.',
    '\\(y/n\\)',
    '\\[y/N\\]',
    '\\[Y/n\\]',
    '1\\. Yes',
    'Yes, and',
    'Allow this',
    'Approve\\?',
    'Press Enter to continue',
    'Waiting for your input',
  ].join('|'),
  'i'
);

// 「作業中」= 実行中スピナー等の特徴
const BUSY_RE = /esc to interrupt|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏/;

const prev = new Map(); // name -> { tail, changedAt }

function judge(name, text) {
  const now = Date.now();
  const tail = text.slice(-4000);
  const before = prev.get(name);
  if (!before || before.tail !== tail) prev.set(name, { tail, changedAt: now });
  const changedAt = (prev.get(name) || { changedAt: now }).changedAt;
  const quietMs = now - changedAt;

  const screen = text.slice(-3000);
  if (WAITING_RE.test(screen)) return { status: 'waiting', quietMs };
  if (BUSY_RE.test(screen) || quietMs < 5000) return { status: 'busy', quietMs };
  return { status: 'idle', quietMs };
}

function lastMeaningfulLine(text) {
  const lines = text.split('\n').map((l) => l.replace(/\s+$/, ''));
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i].trim();
    if (l && !/^[│─╭╮╰╯>❯$%#\s]*$/.test(l)) return l.slice(0, 60);
  }
  return '';
}

// ------------------------------------------------------------ 画像の置き場

const UPLOAD_DIR = path.join(CONF_DIR, 'uploads');
const KEEP_DAYS = 7;

// 拡張子はファイル名ではなく中身で判定する
function sniffImage(b) {
  if (b.length < 12) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpg';
  if (b.slice(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  if (b.slice(0, 6).toString('ascii') === 'GIF87a' || b.slice(0, 6).toString('ascii') === 'GIF89a') return 'gif';
  if (b.slice(0, 4).toString('ascii') === 'RIFF' && b.slice(8, 12).toString('ascii') === 'WEBP') return 'webp';
  if (b.slice(4, 8).toString('ascii') === 'ftyp') {
    const brand = b.slice(8, 12).toString('ascii');
    if (/^(heic|heix|hevc|mif1|msf1|avif)$/.test(brand)) return 'heic';
  }
  return null;
}

// 置きっぱなしを溜めない。古いものは消す
function pruneUploads() {
  try {
    const limit = Date.now() - KEEP_DAYS * 24 * 3600 * 1000;
    for (const f of fs.readdirSync(UPLOAD_DIR)) {
      const full = path.join(UPLOAD_DIR, f);
      if (fs.statSync(full).mtimeMs < limit) fs.unlinkSync(full);
    }
  } catch (e) { /* 無ければ何もしない */ }
}

// -------------------------------------------------------------- プレビュー

// つみきの持ちもの一式（ロゴ・名刺・書類ひな形・やり取りの出力）の置き場。
// 実体は iCloud Drive なので、アプリで見るのと iPhone のファイルアプリで
// 見るのが同じ1か所になる。ここから外は絶対に出さない。
//
// ⚠️ iCloud のフォルダは、同期系の fs 呼び出し（readdirSync など）が
// 数分単位で返ってこないことがある。Node は1本のループで動いているので、
// そこで固まるとターミナル表示もキー送信も全部止まる（実際に止めた）。
// このフォルダを触るときは必ず非同期＋制限時間つきで扱うこと。
const PREVIEW_ROOT = path.join(
  os.homedir(), 'Library', 'Mobile Documents', 'com~apple~CloudDocs',
  'Kodai', '00_Tsumiki');
// やり取りの中で作ったものは、屋号の資産（ロゴ・名刺・書類）と混ざらないよう
// この中の `11_やりとり出力` に入れる。Mac からは `~/つみき出力/` がその近道。
const PREVIEW_OUT = path.join(PREVIEW_ROOT, '11_やりとり出力');
fsp.mkdir(PREVIEW_OUT, { recursive: true }).catch(() => {});

// 制限時間つきで待つ。返ってこない相手を切り離すための保険。
function within(promise, ms, label) {
  let timer;
  return Promise.race([
    promise.finally(() => clearTimeout(timer)),
    new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(label + 'が時間内に返りません')), ms); }),
  ]);
}
const SKIP_DIR = /^(\.git|node_modules|\.next|dist|build|\.venv|__pycache__)$/;
const PREVIEW_EXT = /\.(html?|svg|pdf|png|jpe?g|gif|webp|md|txt|csv|json)$/i;

// 見せられるファイルを新しい順に集める（非同期・深さ2まで）
async function listPreviewables(limit = 200) {
  const out = [];
  async function walk(dir, depth) {
    if (depth > 2 || out.length > 2000) return;
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch (e) { return; }
    for (const e of entries) {
      if (e.name.startsWith('.')) continue;
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (!SKIP_DIR.test(e.name)) await walk(full, depth + 1);
      } else if (PREVIEW_EXT.test(e.name)) {
        try {
          const st = await fsp.stat(full);
          out.push({ rel: path.relative(PREVIEW_ROOT, full), mtime: st.mtimeMs, size: st.size });
        } catch (e2) { /* 読めないものは飛ばす */ }
      }
    }
  }
  await walk(PREVIEW_ROOT, 0);
  out.sort((a, b) => b.mtime - a.mtime);
  return out.slice(0, limit);
}

const PREVIEW_MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.pdf': 'application/pdf',
  '.md': 'text/plain; charset=utf-8', '.txt': 'text/plain; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
};

// ---------------------------------------------------------------- HTTP

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/manifest+json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function send(res, code, body, type = 'application/json; charset=utf-8') {
  res.writeHead(code, {
    'content-type': type,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  res.end(body);
}

function json(res, code, obj) {
  send(res, code, JSON.stringify(obj));
}

function cookieToken(req) {
  const raw = req.headers.cookie || '';
  const m = /(?:^|;\s*)tsumiki_t=([^;]+)/.exec(raw);
  return m ? decodeURIComponent(m[1]) : null;
}

function authed(req, url) {
  const t = url.searchParams.get('t') || req.headers['x-token'] || cookieToken(req);
  if (typeof t !== 'string' || t.length !== TOKEN.length) return false;
  return crypto.timingSafeEqual(Buffer.from(t), Buffer.from(TOKEN));
}

function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const chunks = [];
    req.on('data', (c) => {
      n += c.length;
      if (n > limit) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

async function serveStatic(res, pathname) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const file = path.join(PUBLIC_DIR, rel);
  if (!file.startsWith(PUBLIC_DIR + path.sep) && file !== path.join(PUBLIC_DIR, 'index.html')) {
    return send(res, 403, 'forbidden', 'text/plain; charset=utf-8');
  }
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, 'not found', 'text/plain; charset=utf-8');
    send(res, 200, buf, MIME[path.extname(file)] || 'application/octet-stream');
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  // manifest は動的に返す。iOS はホーム画面から起動するとき manifest の start_url を使うので、
  // ここにトークンを入れておかないと「ホーム画面に追加」した途端に合言葉を聞かれる
  // （ホーム画面アプリと Safari は localStorage が別領域のため、保存済みの値も引き継がれない）。
  if (p === '/manifest.json') {
    if (!authed(req, url)) return json(res, 401, { error: 'unauthorized' });
    const manifest = {
      name: 'つみきリモート',
      short_name: 'つみきリモート',
      description: 'Mac の tmux セッションをスマホから見て指示する',
      start_url: './?t=' + TOKEN,
      scope: './',
      display: 'standalone',
      // 向きは固定しない。portrait にすると、ホーム画面から起動した iPad が
      // 横向きでも縦のまま表示され、画面の左右が黒く余る（2026-08-31）。
      // 画面は幅で組み替わる（600/900）ので、どちらの向きでも成立する。
      orientation: 'any',
      background_color: '#0e0f12',
      theme_color: '#0e0f12',
      icons: [
        { src: 'icon-180.png', sizes: '180x180', type: 'image/png' },
        { src: 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
      ],
    };
    return send(res, 200, JSON.stringify(manifest), 'application/manifest+json; charset=utf-8');
  }

  // 制作物のプレビュー。別タブ（Safari）で開くため、最初の1回でクッキーを配り、
  // 以降の CSS・画像・フォントの読み込みはクッキーで通す。
  if (p.startsWith('/preview/')) {
    if (!authed(req, url)) return send(res, 401, '合言葉がありません', 'text/plain; charset=utf-8');

    let rel;
    try { rel = decodeURIComponent(p.slice('/preview/'.length)); }
    catch (e) { return send(res, 400, 'bad path', 'text/plain; charset=utf-8'); }

    const full = path.resolve(PREVIEW_ROOT, rel);
    let real, rootReal, st;
    try {
      rootReal = await within(fsp.realpath(PREVIEW_ROOT), 4000, 'iCloud');
      real = await within(fsp.realpath(full), 4000, 'iCloud');
    } catch (e) {
      return send(res, 404, 'ありません', 'text/plain; charset=utf-8');
    }
    // シンボリックリンクを辿った先が外なら拒否する
    if (real !== rootReal && !real.startsWith(rootReal + path.sep)) {
      return send(res, 403, '置き場の外は開けません', 'text/plain; charset=utf-8');
    }
    try { st = await within(fsp.stat(real), 4000, 'iCloud'); } catch (e) {
      return send(res, 404, 'ありません', 'text/plain; charset=utf-8');
    }
    if (st.isDirectory()) return send(res, 404, 'フォルダは開けません', 'text/plain; charset=utf-8');

    const type = PREVIEW_MIME[path.extname(real).toLowerCase()] || 'application/octet-stream';
    const headers = {
      'content-type': type,
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    };
    if (url.searchParams.get('t')) {
      headers['set-cookie'] =
        `tsumiki_t=${encodeURIComponent(TOKEN)}; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax`;
    }
    res.writeHead(200, headers);
    fs.createReadStream(real).pipe(res);
    return;
  }

  if (!p.startsWith('/api/')) return serveStatic(res, p);

  if (!authed(req, url)) return json(res, 401, { error: 'unauthorized' });

  try {
    // 全セッションの状態一覧
    if (p === '/api/state' && req.method === 'GET') {
      const listed = await listSessions();
      const sessions = listed.sessions;
      const out = [];
      for (const s of sessions) {
        const text = (await captureScreen(s.name)) || '';
        const { status, quietMs } = judge(s.name, text);
        const info = await paneInfo(s.name);
        out.push({
          name: s.name, window: s.window, status, quietMs,
          kind: kindOf(info.cmd), command: info.cmd,
          title: titleOf(info, s.name),
          // 始めたときに選んだモデル。選ばずに作った席・アプリの外で作った席は空
          model: s.model,
          preview: lastMeaningfulLine(text),
        });
      }
      return json(res, 200, {
        sessions: out, usage: usageSnapshot(), battery: batterySnapshot(),
        version: currentVersion(), now: Date.now(),
      });
    }

    // 1セッションの画面
    if (p === '/api/pane' && req.method === 'GET') {
      const name = url.searchParams.get('name') || '';
      const lines = Number(url.searchParams.get('lines') || 400);
      // 見ている端末に入る桁数。画面側が実測して送ってくる（送ってこなければ触らない）
      if (url.searchParams.has('cols')) await resizeWindow(name, url.searchParams.get('cols'));
      const text = await captureHistory(name, lines);
      if (text === null) return json(res, 404, { error: 'no such session' });
      const { status, quietMs } = judge(name, (await captureScreen(name)) || '');
      return json(res, 200, { name, text, status, quietMs });
    }

    // 文字を送る（末尾で Enter を打つかは enter フラグ）
    if (p === '/api/send' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const text = String(body.text || '').replace(/\r\n?/g, '\n');
      const lines = text ? text.split('\n').length : 0;
      // 「押したのに効かない」を後から追えるようにする。指示の本文まで丸ごと
      // 残すと server.log が日誌になってしまうので、短いものだけ中身を出し、
      // 長いものは字数だけにする（数字ボタンの調査にはこれで足りる）
      console.log(`send ${name} ${text.length <= 8 ? JSON.stringify(text) : text.length + '文字'}${lines > 1 ? '/' + lines + '行' : ''}${body.enter ? ' +Enter' : ''}`);
      if (lines > 1) {
        // 複数行は「角括弧ペースト」で入れる（-p）。素直に送ると、改行のたびに
        // Enter を押したのと同じ＝1行ごとに実行されてしまう（2026-08-13 実測）。
        // 名前つきの控えに置いて、貼ったら消す（-d）＝tmux の貼り付け履歴を汚さない
        const r = await tmuxStdin(['load-buffer', '-b', PASTE_BUF, '-'], text);
        if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
        const p = await tmux(['paste-buffer', '-b', PASTE_BUF, '-d', '-p', '-t', '=' + name + ':']);
        if (!p.ok) return json(res, 500, { error: p.err.slice(0, 200) });
      } else if (text) {
        const r = await tmux(['send-keys', '-t', '=' + name + ':', '-l', text]);
        if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
      }
      if (body.enter) await tmux(['send-keys', '-t', '=' + name + ':', 'Enter']);
      return json(res, 200, { ok: true });
    }

    // 特殊キーを送る（Escape / C-c / Up など tmux のキー名）
    if (p === '/api/key' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      const key = String(body.key || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      if (!/^[A-Za-z0-9_-]{1,12}$/.test(key)) return json(res, 400, { error: 'bad key' });
      console.log(`key ${name} ${key}`);
      const r = await tmux(['send-keys', '-t', '=' + name + ':', key]);
      return json(res, r.ok ? 200 : 500, r.ok ? { ok: true } : { error: r.err.slice(0, 200) });
    }

    // セッションを作る。run:'claude' なら作った直後に Claude Code を起動する
    // （素のシェルを作るだけだと、AI に話しかけたつもりでシェルに打ってしまう）
    if (p === '/api/new' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const cwd = body.dir === 'home' ? os.homedir() : path.join(os.homedir(), '制作物');
      // 同じ名前で作りにくると tmux が duplicate session で落ちる。
      // 画面には「失敗: http 500」しか出ないので、その一件だけは日本語で返す。
      const listed = await listSessions();
      if (listed.ok && listed.sessions.some((s) => s.name === name)) {
        return json(res, 409, { error: name + ' は既にあります' });
      }
      // 作るときから寸法を指定する。あとで resize しても、それまでに流れた行は
      // 80桁で折り返された形のまま履歴に残ってしまうため（tmux は組み直さない）
      const cols = clampCols(body.cols) || COLS_DEFAULT;
      sized.set(name, cols);
      const r = await tmux(['new-session', '-d', '-s', name, '-x', String(cols), '-y', String(ROWS),
        '-c', fs.existsSync(cwd) ? cwd : os.homedir()]);
      if (!r.ok) { sized.delete(name); return json(res, 500, { error: r.err.slice(0, 200) }); }
      if (body.run === 'claude') {
        // スマホからは「これ実行していい？」に毎回答えるのが現実的でないので、
        // このアプリから作るセッションは最初から編集をバイパスで起動する。
        // 許可を求めて止まらなくなる＝返答待ちの通知もほぼ飛ばなくなる。
        // モデルは選ばれていれば足す。知らない名前は黙って無視して、
        // 素の設定で起動する（起動できないより、いつも通り起動するほうがまし）
        const model = String(body.model || '');
        const known = MODELS.indexOf(model) >= 0;
        const cmd = known ? CLAUDE_CMD + ' --model ' + model : CLAUDE_CMD;
        // どのモデルで始めたかを席に書いておく（一覧の札に出すため）。
        // ここだけ `=名前` の指定が使えないので素の名前で指す。名前は NAME_RE を
        // 通っていて、tmux は完全一致を先に見るので、別の席に付くことはない。
        if (known) await tmux(['set-option', '-t', name, MODEL_OPT, model]);
        await tmux(['send-keys', '-t', '=' + name + ':', '-l', cmd]);
        await tmux(['send-keys', '-t', '=' + name + ':', 'Enter']);
      }
      return json(res, 200, { ok: true });
    }

    // 制作物の一覧（新しい順）
    if (p === '/api/files' && req.method === 'GET') {
      let files;
      try {
        files = await within(listPreviewables(400), 4000, 'iCloud の読み込み');
      } catch (e) {
        return json(res, 504, { error: String(e.message) });
      }
      return json(res, 200, { root: PREVIEW_ROOT, files: files.slice(0, 120) });
    }

    // 画像を Mac に置く。Claude Code は画像そのものを受け取れないが、
    // 「ファイルの場所」を渡せば読める。置いた場所を返して、入力欄に差し込む。
    if (p === '/api/upload' && req.method === 'POST') {
      const body = await readBody(req, 16 * 1024 * 1024);
      const data = String(body.data || '');
      const buf = Buffer.from(data, 'base64');
      if (!buf.length) return json(res, 400, { error: 'empty' });
      if (buf.length > 10 * 1024 * 1024) return json(res, 413, { error: '10MBまでです' });

      // 拡張子は中身（マジックバイト）で決める。名前は信用しない
      const ext = sniffImage(buf);
      if (!ext) return json(res, 415, { error: '画像として読めません' });

      fs.mkdirSync(UPLOAD_DIR, { recursive: true, mode: 0o700 });
      pruneUploads();
      const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14); // YYYYMMDDhhmmss
      const file = path.join(UPLOAD_DIR, `${stamp}-${crypto.randomBytes(3).toString('hex')}.${ext}`);
      fs.writeFileSync(file, buf, { mode: 0o600 });
      return json(res, 200, { path: file, bytes: buf.length });
    }

    // Mac の画面だけ消す（スリープはしない）。出先で消し忘れに気づいたとき用。
    if (p === '/api/displaysleep' && req.method === 'POST') {
      const r = await new Promise((resolve) => {
        execFile('/usr/bin/pmset', ['displaysleepnow'], { timeout: 5000 },
          (err) => resolve(!err));
      });
      return json(res, r ? 200 : 500, r ? { ok: true } : { error: '消せませんでした' });
    }

    // 終わらせる（tmux ごと消す）。作業場所の後始末はこれ1つだけにする。
    // 一時は「片付ける＝隠すだけ」も持っていたが、隠したものが work1〜9 の名前を
    // 占有し続けて満席になった（2026-08-12 実発生）。閉じる＝消す、で単純化する。
    if (p === '/api/kill' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const r = await tmux(['kill-session', '-t', '=' + name + ':']);
      if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
      sized.delete(name);   // 同じ名前で作り直したとき、寸法を指定し直せるように
      console.log(`kill ${name}`);
      return json(res, 200, { ok: true });
    }

    // 作業中以外をまとめて終わらせる。名前は画面から受け取るが、消す直前に
    // もう一度いまの状態を見て、作業中になっていたものは残す（押してから
    // ここに届くまでの数秒で動き出すことがある）。何を残したかは返す。
    if (p === '/api/killmany' && req.method === 'POST') {
      const body = await readBody(req);
      const names = (Array.isArray(body.names) ? body.names : [])
        .map(String).filter((n) => NAME_RE.test(n));
      if (!names.length) return json(res, 400, { error: 'bad names' });

      const killed = [];
      const skipped = [];
      for (const name of names) {
        const text = await captureScreen(name);
        if (text === null) { skipped.push({ name, why: 'ありません' }); continue; }
        if (judge(name, text).status === 'busy') { skipped.push({ name, why: '作業中' }); continue; }
        const r = await tmux(['kill-session', '-t', '=' + name + ':']);
        if (r.ok) { killed.push(name); sized.delete(name); console.log(`kill ${name} (まとめて)`); }
        else skipped.push({ name, why: '失敗' });
      }
      return json(res, 200, { ok: true, killed, skipped });
    }

    return json(res, 404, { error: 'not found' });
  } catch (e) {
    return json(res, 500, { error: String(e && e.message || e) });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`つみきリモート: http://${HOST}:${PORT}/?t=${TOKEN}`);
  console.log(`tmux: ${TMUX}`);
});
