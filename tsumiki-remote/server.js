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
const zlib = require('zlib');
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
let usageLastStatus = 0;            // 直前の失敗の中身（429＝叩きすぎ／401＝期限切れ／0＝通信）

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
      usageLastStatus = r.status;
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
    usageLastStatus = 0;
    return { session, week };
  } catch (e) {
    usageLastStatus = 0;
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

// 残量が「取れていない」ときだけ、なぜ・いつ戻るかを添える。
// これが無いと、棒が消えていること自体に気づけない（2026-08-31：37時間気づけなかった）。
// 画面はこれを受け取って、薄い棒を出す＝押すと理由が読める。
function usageWaitInfo() {
  if (usageCache.value) return null;
  return {
    status: usageLastStatus,
    retryInSec: Math.max(0, Math.round((usageRetryAt - Date.now()) / 1000)),
  };
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

// 1行の本文を tmux の引数として渡すときの下ごしらえ（2026-09-02）。
//
// tmux は argv を「コマンドの並び」として読み直すので、本文をそのまま最後の引数に
// 置くと2つ壊れる。どちらも実測で確認した（tmux 3.7b・display-message -p で検証）。
//
//   ① 末尾のセミコロンをコマンドの区切りとして剥がす。
//      `color: red;` → 届くのは `color: red`。本文が `;` 1文字だけなら引数ごと消えて
//      Enter しか飛ばない。**いままで100%欠けていた。**
//      man tmux:「trailing semicolons ... should be escaped twice」のとおり、
//      末尾だけ `\;` にすると `;` として届く（`abc;`→`abc\;`→`abc;`）。
//      すでに `\;` で終わっている本文も、同じ足し方で `abc\\;`→`abc\;` と正しく届く。
//   ② 先頭が `-` の本文を旗（オプション）と読む。「-y をつけて」は
//      `unknown flag -y` で 500 になり、送信そのものが失敗していた。
//      こちらは引数の終わり印 `--` を `-l` の直後に置いて塞ぐ（呼び出し側）。
//
// 途中のセミコロン（`color: red;x`）は無傷なので触らない。
// 複数行は load-buffer（標準入力）経由なので、どちらも元から影響しない。
function sendKeysArg(text) {
  return text.endsWith(';') ? text.slice(0, -1) + '\\;' : text;
}

// 送れる本文の上限。以前は readBody の既定 64KB のままで、日本語なら約21,800字で
// 黙って切れていた（プレビューの「本文をぜんぶコピー」で制作物HTMLを貼ると普通に超える）。
// 上限そのものは残す（際限なく受けると tmux に丸ごと流し込むことになる）が、
// 現実の貼り付けでは当たらない大きさにする。当たったときは 413 と日本語の理由が返る。
const SEND_LIMIT = 8 * 1024 * 1024;

// tmux の引数として1回に渡せる本文の実測上限（tmux 3.7b・2026-09-02）。
// 16,000B は通り、16,400B から `command too long` で 500 になる。
// これを超える1行は load-buffer（標準入力）へ回す。半分にして余裕を取っている。
const SEND_ARGV_MAX = 8 * 1024;

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

// いつリサイズしたか。judge() が「折り返しが変わっただけの画面」を
// 「動いた」と数えないために要る（→ RESIZE_GRACE_MS のところに理由）
const resizedAt = new Map();

// いま何桁で開いているかを tmux に聞く。取れなければ 0
async function windowWidth(name) {
  const r = await tmux(['display-message', '-p', '-t', '=' + name + ':', '#{window_width}']);
  const n = parseInt((r.out || '').trim(), 10);
  return Number.isFinite(n) ? n : 0;
}

async function resizeWindow(name, cols) {
  if (!NAME_RE.test(name)) return;
  const want = clampCols(cols);
  if (!want) return;
  // ⚠️ 覚えている値（sized）だけで「もう合っている」と判断しない。resize のあと
  // window-size latest に戻しているので、MacBook のターミナルから繋ぐなど、
  // 別のクライアントが来ると幅はそちらに合わせて変わってしまう。そのとき
  // 覚えている値のせいで直しにいかず、スマホでは崩れたまま残っていた
  // （2026-09-01 点検で判明）。実際の幅を見て決める
  if (await windowWidth(name) === want) { sized.set(name, want); return; }
  sized.set(name, want);
  await tmux(['resize-window', '-t', '=' + name + ':', '-x', String(want), '-y', String(ROWS)]);
  // resize-window はその窓を window-size manual に切り替える。そのままだと
  // MacBook のターミナルから繋いだときも 60桁のままになってしまうので、
  // 「最後に繋いだ相手に合わせる」既定に戻す（いまの寸法はそのまま残る）
  await tmux(['set-window-option', '-t', '=' + name + ':', 'window-size', 'latest']);
  resizedAt.set(name, Date.now());   // 折り返しが直るまでの猶予は、ここから数える
  forgetScreen(name);                // 幅が変われば画面も変わる＝撮り置きは捨てる
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
// 同じ1周期のあいだ、同じ席の画面は1回だけ撮る（2026-09-02）。
//
// 画面側は1.5秒ごとに /api/state と /api/pane を投げる。いま見ている席は
// **両方から** capture-pane されていて、1周期に2本ムダに起動していた（実測 1本 3.5ms）。
// しかも2本は撮った時刻が違うので、judge() が同じ周期で違う画面を2回見ることになり、
// 一覧の札と作業画面の状態が食い違う原因にもなっていた。
//
// ・撮っている最中に同じ席を頼まれたら、その結果を待ち合わせる（＝完全に同じ中身）
// ・撮り終えた直後（SCREEN_TTL）も同じ結果を配る。並列に投げても取りこぼさないため
// ⚠️ まとめて片付ける /api/killmany では**使わない**。あれは消す直前に本当に
//    いまの画面を見て「作業中なら残す」と決める場所なので、写しでは意味がない。
const SCREEN_TTL = 300;
const screenCache = new Map();   // name -> { at, text }
const screenFlight = new Map();  // name -> Promise
// ⚠️ 「撮っている最中」に文字を送られたら、その撮影ぶんは捨てる（2026-09-02 レビュー指摘）。
// forgetScreen が写しを消すだけだと、送信前に始まった撮影が**送信後の時刻の写し**として
// 入り込み、120ms後に見に行った judge が送信前の画面で判定する
// （文字は captureHistory で新しいのに、札だけ1回ぶん古い）。世代番号で見分ける。
const screenGen = new Map();     // name -> 世代番号

function captureScreenShared(name) {
  const now = Date.now();
  const hit = screenCache.get(name);
  if (hit && now - hit.at < SCREEN_TTL) return Promise.resolve(hit.text);
  const flying = screenFlight.get(name);
  if (flying) return flying;
  const gen = screenGen.get(name) || 0;
  const p = captureScreen(name).then((text) => {
    // 撮っているあいだに送信などが挟まっていたら、この撮影ぶんは写しにしない。
    // 取れなかった（null）ときも写しにしない＝次は必ず撮り直す
    if (text !== null && (screenGen.get(name) || 0) === gen) {
      screenCache.set(name, { at: Date.now(), text });
    }
    return text;
  }).finally(() => {
    if (screenFlight.get(name) === p) screenFlight.delete(name);
  });
  screenFlight.set(name, p);
  return p;
}

// 1席ぶんの状態を作る。席ごとに同時に走らせるので、この中は直列でよい
// （画面を撮ってからでないと judge が回らない）。
async function seatState(s, deadline) {
  const text = (await captureScreenShared(s.name)) || '';
  const { status, quietMs } = judge(s.name, text);
  // すでに締め切りを過ぎているなら、ここで降りる。待つのをやめた席のために
  // display-message をもう1本起こしても、その結果は誰も使わない
  if (Date.now() > deadline) throw new Error('deadline');
  const info = await paneInfo(s.name);
  const row = {
    name: s.name, window: s.window, status, quietMs,
    kind: kindOf(info.cmd), command: info.cmd,
    title: titleOf(info, s.name),
    // 始めたときに選んだモデル。選ばずに作った席・アプリの外で作った席は空
    model: s.model,
    preview: lastMeaningfulLine(text),
  };
  lastSeat.set(s.name, row);
  return row;
}

// 席1つを待つ上限。
// ⚠️ 巡回（1.5秒）より短くすること。長くすると「1席のつまりで全部が遅くなる」が
// 残り、詰まっていない席の札まで巡回に間に合わなくなる（2026-09-02 レビュー指摘）。
const SEAT_MS = 1200;
// 席の一覧そのものにも締め切りを置く。ここが無いと tmux の天井（5秒）＋席の締め切りで
// 画面側の待ち（5秒）を追い越し、締め切りを置いた意味が消える
const LIST_MS = 1200;
// いま見ている画面の読み取りにも締め切り。ここだけ無制限だと、選んでいる席が
// 詰まったときにいちばん見たいものが返ってこない
const PANE_MS = 2500;
const lastSeat = new Map();   // name -> 最後にうまく読めた1行
const staleSeat = new Set();  // いま「前の値でしのいでいる」席（ログを毎周期出さないため）

function forgetScreen(name) {
  screenCache.delete(name);
  screenGen.set(name, (screenGen.get(name) || 0) + 1);
}

// 席そのものが無くなったときの後始末（前の住人の姿を新しい席に持ち越さない）
function forgetSeat(name) {
  forgetScreen(name);
  lastSeat.delete(name);
  pausedSeat.delete(name);
}

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

// 「中断」= 人が手で止めたところで待っている席（2026-09-03）。
// 止めかたは2通りあり、画面に残る印もそれぞれ違う。
//  ① キー行の `pause`（＝ esc）で止めた → Claude Code が自分で書く
//     「Interrupted · What should Claude do instead?」「[Request interrupted by user]」
//     （2026-09-03 に Claude Code の中身を読んで確かめた文言＝
//       {tone:"dim", text:"Interrupted", detail:"What should Claude do instead?"} と
//       `[Request interrupted by user]` `[Request interrupted by user for tool use]`）
//  ② 番号の質問で `pause` を選んだ → Claude が手を止めて「⏸ 中断しました」と書く
//     （共通ルール ~/.claude/CLAUDE.md の質問のしかたで、そう書くと決めてある）
// ⚠️ 印は**行の頭**で見て、そのうしろも見る。「Interrupted」という字だけを探すと、
//    この仕組みの話をしているだけの地の文（「画面に Interrupted などが出ていたら…」）
//    まで当たる。行頭にあって、そのあとが「 ·」か行末のものだけを中断と見なす。
//    行頭の `⎿` は付いていても付いていなくてもよい（囲みの記号は版で変わりうる）。
// ⚠️ `\s` は改行も食うので、行末は `[ \t]*$` で見る（`\s*$` だと次の行まで越える）。
const PAUSED_RE =
  /^[ \t]*(?:⎿[ \t]*)?Interrupted(?:[ \t]*·|[ \t]*$)|\[Request interrupted by user|^[ \t]*⏸/m;
// 印を探すのは画面の末尾だけ（番号の質問と同じ考えかた）。
const PAUSED_TAIL = 16;

// 中断は**札**として持つ（2026-09-03・2回目）。
//
// 画面の字だけで決めていると、Claude が一言でも書き足したとたん印が上へ押し出されて、
// 何もしていないのに中断が解ける＝`resume` を押す前に札が消えてしまう。
// だから一度立てた札は**こちらから降ろすまで立ったまま**にする。
//
// 降ろすのは2つだけ：
//   ① その席に**文字を送った**とき（`resume` の「続けて」も、手で打った指示も同じ）
//   ② その席が**動き出した**とき（スピナー＝作業中／枠を出して聞いてきた）
//
// ⚠️ 降ろしたあとも印は画面に残っている。そのままだと次の巡回でまた立ってしまうので、
//    降ろすときは「消音」にして、**印が画面から流れて消えるまで数えない**。
//    消えたら札そのものを捨てて、次に出た印はまた数える。
const pausedSeat = new Map();     // name -> 'on'（中断）| 'off'（消音）

function markPaused(name) { pausedSeat.set(name, 'on'); }
// 送った・動き出した＝もう中断ではない。ただし札を持っていた席だけ消音にする
function clearPaused(name) { if (pausedSeat.has(name)) pausedSeat.set(name, 'off'); }

// 「番号で答える質問」＝ 本文に選択肢を書いて、数字だけ返してもらう聞きかた。
// 共通ルール（~/.claude/CLAUDE.md）で、選択パネル（AskUserQuestion）は使わずに
// こう聞くと決めてあるので、返答待ちのほとんどはこの形になる。ところがこれは
// Claude Code 自身が出す選択肢の枠ではないため、上の WAITING_RE には
// ひとつも引っかからず、札も通知も出ていなかった（2026-09-01 実機で確認）。
// 手がかりは2つとも、そのルールで必ず書くと決まっている言い回し。
//
// ⚠️ 後半は2回書き直している（2026-09-02）。前の形
//    `(数字|番号)(だけ|のみ)?[をでは]?(返|送)し` は、**当たりすぎと取りこぼしを同時に**
//    やっていた。
//    ・当たりすぎ：質問かどうかを見ていないので、ただの説明文に当たる。
//      「この関数はエラー番号を返します」「注文番号を返しました」「番号は返しません」
//      「行番号を返してください」（＝こちらが出した頼みごとの文面）が全部当たり、
//      処理が終わって静かになった席がオレンジの「返答待ち」で残っていた。
//    ・取りこぼし：肝心の共通ルールの実文面「番号だけをチャット欄に返してください」は
//      [をでは]? が助詞1字しか許さないため **当たらなかった**。
//    直した形は2つとも要求する＝①「だけ／のみ」で数字だけを求めていること
//    ②「〜してください／してね」と依頼で言い切っていること。これで説明文が落ちる。
//    「チャット欄に数字だけ返してください」の語順違いも拾う。
//    実測：狙いの言い回し10件を全部拾い、誤判定の11件を全部落とす。
//    いま動いている席の実画面（履歴400行×6席）でも、当たっていた12行のうち
//    誤判定の1行だけが落ち、拾いたい行は落ちないことを確かめた。
const ASK_NUM = {
  num: '(数字|番号)',
  only: '(だけ|のみ)',
  // 「だけ」と動詞のあいだに入りうる短い挿入（「を」「で」・チャット欄・（例: 1）など）。
  // ⚠️ 句点と改行は越えない＝別の文とつながって誤判定するのを防ぐ
  gap: '[^。\\n]{0,10}',
  // 「数字だけ」と一緒に使う動詞。ここは広く取ってよい（「だけ／のみ」が門番になる）
  vOnly: '(返して|送って|返信して|送信して|返答して|答えて|教えて|入力して|書いて|打って|お答え|お返事|お知らせ)',
  // 「だけ」が無くても質問と分かる動詞だけを、こちらに置く。
  // ⚠️ 返す・送るは入れない（「行番号を返してください」のような**頼みごと**に当たるため）
  vAsk: '(お答え|お返事|お知らせ|答えて)',
  end: '(ください|下さい|くれ|ね|もらえ|ほしい|欲しい|$)',
};
const ASK_NUM_RE = new RegExp([
  'ほかの案（自由に書いてください）',
  ASK_NUM.num + ASK_NUM.only + ASK_NUM.gap + ASK_NUM.vOnly + '\\s*' + ASK_NUM.end,
  '(チャット欄|この欄|ここ)[にへ]' + ASK_NUM.gap + ASK_NUM.num + ASK_NUM.only + '?' + ASK_NUM.gap + ASK_NUM.vOnly + '\\s*' + ASK_NUM.end,
  ASK_NUM.num + '(を|で|は)?' + ASK_NUM.vAsk + '\\s*' + ASK_NUM.end,
].join('|'), 'm');

// ⚠️ 端末は桁で折り返すので、長い文の途中に**本物の改行**が入る（2026-09-02 実測）。
//   「…あああああ番号\nだけをチャット欄に返してください。」
// このままだと「番号」と「だけ」が離れて当たらない。空白と改行を取り払った文字列でも
// 試して、折り返しで割れたぶんを拾い直す。
function asksNumber(text) {
  return ASK_NUM_RE.test(text) || ASK_NUM_RE.test(text.replace(/[\s　]+/g, ''));
}

// ⚠️ 画面の下のほうに出ているときだけ数える。答えたあとも字はしばらく画面に
// 残るので、画面ぜんぶを見ると「答えたのに返答待ちのまま」になる。新しい
// やり取りが積まれて上へ押し出されたら、もう待っていないと見なす。
// 16行なのは実測から：51桁の画面だと、選択肢4つが折り返された質問でも
// 「ほかの案（…）」から画面の末尾まで10行ほどに収まる（2026-09-01）
const ASK_NUM_TAIL = 16;

function tailLines(text, n) {
  const lines = text.split('\n');
  return lines.slice(-n).join('\n');
}

const prev = new Map(); // name -> { tail, changedAt }

// リサイズした直後は、枠線も折り返しも引き直されて画面の文字が丸ごと変わる。
// これを「動いた」と数えると、幅が変わるたびに「作業中」に戻ってしまう。
// 画面を見ている席にだけ桁数を送る作りなので、**選んでいる席だけ**が巻き添えになる：
//   ・iPhone(51桁) と iPad(101桁) で同じ席を開くと、1.5秒ごとに幅が往復し、
//     その席は永久に「作業中」＝札も戻らず「作業中以外を終わらせる」でも片付かない
//   ・1台でも、絵つきの質問で 120桁に広げて戻すたびに数秒つかまる
// （2026-09-01 実測：幅を1回変えるだけで idle → busy / quietMs 0 になった）
// だからリサイズから RESIZE_GRACE_MS のあいだの変化は、静かさの計算に入れない。
// 本当に動いているものはスピナー（BUSY_RE）が拾うので、見落としにはならない。
const RESIZE_GRACE_MS = 2000;

function judge(name, text) {
  const now = Date.now();
  const tail = text.slice(-4000);
  const before = prev.get(name);
  const afterResize = now - (resizedAt.get(name) || 0) < RESIZE_GRACE_MS;
  // サーバを入れ替えた直後は、どの席も「初めて見る」＝動いているか止まっているかの
  // 手がかりが無い。そこは**わざと作業中に倒す**（changedAt を now にする）。
  // 引き換えに起動から5秒は全席が作業中に見えて片付けが効かないが、逆に倒すと
  // 「動いている席が待機に見え、まとめて片付けで消える」になる。
  // 消せないほうが、消えるより軽い（2026-09-01 両方試して、こちらを採った）
  if (!before) prev.set(name, { tail, changedAt: now });
  // 中身は新しいものに入れ替えるが、「いつ動いたか」は据え置く＝時計を戻さない
  else if (before.tail !== tail) {
    prev.set(name, { tail, changedAt: afterResize ? before.changedAt : now });
  }
  const changedAt = (prev.get(name) || { changedAt: now }).changedAt;
  const quietMs = now - changedAt;

  const screen = text.slice(-3000);
  const marked = PAUSED_RE.test(tailLines(text, PAUSED_TAIL));
  // 消音は、印が画面から流れて消えたところで解く（次に出た印はまた数える）
  if (pausedSeat.get(name) === 'off' && !marked) pausedSeat.delete(name);

  if (WAITING_RE.test(screen)) { clearPaused(name); return { status: 'waiting', quietMs }; }
  // 番号で答える質問より、スピナーのほうが強い。答えた直後は Claude が動き出す
  // のに、質問の字はまだ画面に残っている＝そこは「作業中」と出したい
  if (BUSY_RE.test(screen)) { clearPaused(name); return { status: 'busy', quietMs }; }
  // 印を見つけたら札を立てる。消音のあいだは数えない
  if (marked && pausedSeat.get(name) !== 'off') markPaused(name);
  // 中断は番号の質問より先に見る。質問を出したあとに pause で止めると、質問の字は
  // まだ末尾に残っている＝順番が逆だと「返答待ち」のまま中断の縁が出ない
  if (pausedSeat.get(name) === 'on') return { status: 'paused', quietMs };
  if (asksNumber(tailLines(text, ASK_NUM_TAIL))) return { status: 'waiting', quietMs };
  if (quietMs < 5000) return { status: 'busy', quietMs };
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

// ------------------------------------------ 添えるファイル（画像・PDF）の置き場

const UPLOAD_DIR = path.join(CONF_DIR, 'uploads');
const KEEP_DAYS = 7;
// 1件あたりの上限。PDF は写真より重くなりがちなので 20MB まで見る
// （画面側 index.html の MAX_ATT と揃えること）
const MAX_UPLOAD = 20 * 1024 * 1024;

// 拡張子はファイル名ではなく中身で判定する
function sniffUpload(b) {
  if (b.length < 12) return null;
  if (b.slice(0, 5).toString('ascii') === '%PDF-') return 'pdf';
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
  if (!m) return null;
  // ⚠️ 壊れた値（`%` だけ 等）で decodeURIComponent は例外を投げる。ここは
  // 認証の手前＝この関数が投げるとサーバがプロセスごと落ちる（2026-09-01 実証）
  try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
}

function authed(req, url) {
  let t;
  try { t = url.searchParams.get('t') || req.headers['x-token'] || cookieToken(req); }
  catch (e) { return false; }
  if (typeof t !== 'string' || !t) return false;
  // ⚠️ 長さは「文字数」ではなく「バイト数」で見る。timingSafeEqual はバイト長が
  // 違うと例外を投げるので、48文字ぶんの日本語を ?t= に付けられるだけで
  // サーバが落ちていた（2026-09-01 実証：合言葉を知らなくても落とせた）
  const a = Buffer.from(t, 'utf8');
  const b = Buffer.from(TOKEN, 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// 本文を読み取る。上限を超えたときは **返事を書けるように** 中断する。
// ⚠️ 以前はここで req.destroy() していた（2026-09-02 点検で判明）。返事を書く前に
// ソケットを壊すので、画面側には 413 ではなくネットワーク失敗として届き
// 「MacBook に届きません」＝電波のせいに見える。長文を貼って送ると原因不明のまま
// 本文が消えるので、いちばん当たりにくい壊れ方だった。
// いまは読むのをやめて `tooLarge` の印を付けて返し、呼び出し側が理由を返す。
function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let n = 0;
    let chunks = [];
    req.on('data', (c) => {
      n += c.length;
      if (n > limit) {
        const err = new Error('too large');
        err.tooLarge = true;
        err.limit = limit;
        chunks = [];          // もう使わない分は抱えない
        req.pause();
        reject(err);
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

// ------------------------------------------------ 画面ファイルの配りかた
//
// ⚠️ ここだけ send() を通さない（2026-09-02）。send() は全部の返事に no-store
// （＝毎回取り直せ）を付けるが、それは **/api/ のためのもの**。席の状態を古い写しで
// 見せると嘘になるので /api/ は no-store のままにする。いっぽう画面のファイルまで
// no-store だと、起動のたびに index.html（実測 161,976B）を丸ごと取りに行っていた。
//
//   ・no-cache ＋ ETag にする＝「毎回聞きには行くが、変わっていなければ本文は送らない」
//     2回目からは 304 で本文 0B（実測）。版の仕組み（BOOT混じり）はそのまま効く
//   ・変わっていたときは gzip で送る＝161,976B → 52,711B（実測 3.07倍）
//
// ETag は mtime とサイズから作る弱いもので足りる。版（currentVersion）は中身の SHA1
// だが、**その計算をやり直す合図も mtime とサイズ**（verCache.key）なので、
// 「版は変わったのに ETag は変わらない」＝読み直しが終わらない、にはならない。
// 材料が同じなので、ふたつは必ず一緒に変わる。
// gzip は同じ版のあいだ使い回す（毎回かけると 4.5ms/回）。
const GZIP_TYPE = /^(text\/|application\/(javascript|json|manifest\+json)|image\/svg)/;
const GZIP_MIN = 1024;
const gzCache = new Map();   // ファイル -> { key, buf }

function gzipFor(file, buf, key) {
  const hit = gzCache.get(file);
  if (hit && hit.key === key) return hit.buf;
  const out = zlib.gzipSync(buf, { level: 6 });
  gzCache.set(file, { key, buf: out });
  return out;
}

function serveStatic(req, res, pathname) {
  const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const file = path.join(PUBLIC_DIR, rel);
  if (!file.startsWith(PUBLIC_DIR + path.sep) && file !== path.join(PUBLIC_DIR, 'index.html')) {
    return send(res, 403, 'forbidden', 'text/plain; charset=utf-8');
  }
  fs.stat(file, (e1, st) => {
    if (e1 || !st.isFile()) return send(res, 404, 'not found', 'text/plain; charset=utf-8');
    const key = st.mtimeMs + '-' + st.size;
    const etag = 'W/"' + key + '"';
    const type = MIME[path.extname(file)] || 'application/octet-stream';
    const head = {
      'content-type': type,
      'cache-control': 'no-cache',
      'x-content-type-options': 'nosniff',
      etag,
      'last-modified': new Date(st.mtimeMs).toUTCString(),
      vary: 'accept-encoding',
    };
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, head);
      return res.end();
    }
    fs.readFile(file, (e2, buf) => {
      if (e2) return send(res, 404, 'not found', 'text/plain; charset=utf-8');
      let body = buf;
      if (/\bgzip\b/.test(String(req.headers['accept-encoding'] || ''))
          && GZIP_TYPE.test(type) && buf.length >= GZIP_MIN) {
        body = gzipFor(file, buf, key);
        head['content-encoding'] = 'gzip';
      }
      res.writeHead(200, head);
      res.end(req.method === 'HEAD' ? undefined : body);
    });
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

  // 制作物のプレビュー。最初の1回でクッキーを配り、
  // 以降の CSS・画像・フォントの読み込みはクッキーで通す。
  if (p.startsWith('/preview/')) {
    if (!authed(req, url)) return send(res, 401, '合言葉がありません', 'text/plain; charset=utf-8');

    // 合言葉を渡すためだけの挨拶（2026-09-02）。中身は返さない。
    // ⚠️ プレビューの枠は砂箱に入れてあり、URL に合言葉を付けない。付けると
    // 中の文書が自分の location から読み取って外へ持ち出せてしまう（画像の読み込みは
    // CSP の connect-src では止まらない）。そこで**親がここで1回だけ**合言葉を見せ、
    // 以降はクッキー（HttpOnly・Path=/preview/）で通す。
    if (p === '/preview/') {
      res.writeHead(204, {
        'cache-control': 'no-store',
        'set-cookie': `tsumiki_t=${encodeURIComponent(TOKEN)}; Path=/preview/; Max-Age=2592000; HttpOnly; SameSite=Lax`,
      });
      return res.end();
    }

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
      // ⚠️ ここで配るものは**アプリと同じ出どころ（オリジン）**で開く。つまり
      // 制作物の中の JavaScript から、このサーバの /api/send がそのまま叩ける＝
      // 開いただけで、どれかの席に好きな文字を打てる（2026-09-01 点検で判明）。
      // 自分で作ったものだけを置いているうちは無害だが、外からもらった HTML を
      // つみき出力に置いて開くと成立してしまう。
      // 通信の口を閉じて塞ぐ：connect-src が fetch/XHR/sendBeacon/WebSocket を、
      // form-action がフォーム送信を止める。POST を送る道はこれで全部ふさがる
      // （<img> は GET しか出せず、返事の中身も読めない）。
      // 見た目には触らない＝絵も字も枠も今までどおり出る
      'content-security-policy': "connect-src 'none'; form-action 'none'",
    };
    if (url.searchParams.get('t')) {
      // クッキーの届く先も /preview/ の中だけにする。Path=/ だと、制作物からの
      // 問い合わせにも合言葉が付いていた（上を塞いだうえでの、もう一枚）
      headers['set-cookie'] =
        `tsumiki_t=${encodeURIComponent(TOKEN)}; Path=/preview/; Max-Age=2592000; HttpOnly; SameSite=Lax`;
    }
    res.writeHead(200, headers);
    // ⚠️ 読み出しの失敗をここで受ける（2026-09-02）。iCloud にまだ落ちてきていない
    // ファイルを読むと EDEADLK（`Unknown system error -11`）で失敗することがあり、
    // 受け手が無いと uncaughtException まで飛んでログが汚れる（実際に出た）。
    // 見出しはもう送ってしまっているので、あとは黙って切るしかない
    const rs = fs.createReadStream(real);
    rs.on('error', (e) => {
      console.log('preview 読めません: ' + String(e && e.message).slice(0, 80));
      try { res.destroy(); } catch (e2) {}
    });
    rs.pipe(res);
    return;
  }

  if (!p.startsWith('/api/')) return serveStatic(req, res, p);

  if (!authed(req, url)) return json(res, 401, { error: 'unauthorized' });

  try {
    // 全セッションの状態一覧
    if (p === '/api/state' && req.method === 'GET') {
      // 一覧そのものが返らないときは、前に分かっていた席の名前でしのぐ。
      // ここで空の配列を返すと、画面が「まだ作業場所がありません」に化けてしまう
      const listed = await within(listSessions(), LIST_MS, 'tmux の一覧').catch(() => null);
      const sessions = listed ? listed.sessions
        : Array.from(lastSeat.values()).map((r) => ({ name: r.name, window: r.window, activity: 0, model: r.model }));
      // ⚠️ 席ごとを**同時に**調べる（2026-09-02）。それまでは席の数だけ直列に
      // tmux を起こしていて、1回に 1+2N 本（席5つで11本）。1本の天井は5秒で、
      // 全体の締め切りは無かった。Mac が重いと /api/state だけで3〜20秒かかり、
      // 画面は「つながっています」のまま数十秒止まって見える。
      // 実測（席6つ）：直列 40ms → 同時実行 9ms。重いときの差はもっと開く。
      // さらに席ごとに締め切りを置き、間に合わない席があっても
      // **その席だけ**前回の値に落として、全体は返す（1席のつまりで全部を止めない）。
      const deadline = Date.now() + SEAT_MS;
      const out = await Promise.all(sessions.map((s) => within(seatState(s, deadline), SEAT_MS, '席の読み取り')
        .then((row) => {
          // 読めた＝札は本物。前に「しのいでいた」なら、そこも戻す
          if (staleSeat.delete(s.name)) console.log(`state ${s.name} が読めるようになった`);
          return row;
        })
        .catch(() => {
          // 間に合わなかった席は、前に分かっていた姿を出す。ただし **stale の印を付ける**。
          // 印が無いと、固まった席の札が「待機」のまま自信ありげに出続ける
          // ＝この塊の目的（止まったら止まったと分かる）と逆になる（2026-09-02 レビュー指摘）
          const last = lastSeat.get(s.name);
          // ログは毎周期ではなく、状態が変わったときだけ（1.5秒ごとに1行たまるのを防ぐ）
          if (!staleSeat.has(s.name)) {
            staleSeat.add(s.name);
            console.log(`state ${s.name} が ${SEAT_MS}ms で返らない → 前の値でしのぐ`);
          }
          // 初めて見る席は「作業中」に倒す＝消えるより消せないほうが軽い（README）
          const base = last || { name: s.name, window: s.window, status: 'busy', quietMs: 0,
            kind: 'shell', command: '', title: s.name, model: s.model, preview: '' };
          return Object.assign({}, base, { stale: true });
        })));
      return json(res, 200, {
        sessions: out, usage: usageSnapshot(), usageWait: usageWaitInfo(),
        battery: batterySnapshot(),
        version: currentVersion(), now: Date.now(),
      });
    }

    // 1セッションの画面
    if (p === '/api/pane' && req.method === 'GET') {
      const name = url.searchParams.get('name') || '';
      const lines = Number(url.searchParams.get('lines') || 400);
      // ⚠️ ここにも締め切りを置く（2026-09-02）。resize + capture 2本で最悪15秒かかり、
      // いちばん見たい画面だけが守られていなかった。間に合わなければ理由を返して、
      // 画面側は残してある写しでしのぐ（黙って固まるより、理由が出るほうがよい）
      const body = (async () => {
        // 見ている端末に入る桁数。画面側が実測して送ってくる（送ってこなければ触らない）
        if (url.searchParams.has('cols')) await resizeWindow(name, url.searchParams.get('cols'));
        const text = await captureHistory(name, lines);
        if (text === null) return null;
        const { status, quietMs } = judge(name, (await captureScreenShared(name)) || '');
        return { name, text, status, quietMs };
      })();
      let got;
      try { got = await within(body, PANE_MS, '画面の読み取り'); }
      catch (e) { return json(res, 503, { error: 'Mac が画面を返しません（' + Math.round(PANE_MS / 1000) + '秒待ちました）' }); }
      if (got === null) return json(res, 404, { error: 'no such session' });
      return json(res, 200, got);
    }

    // 文字を送る（末尾で Enter を打つかは enter フラグ）
    if (p === '/api/send' && req.method === 'POST') {
      const body = await readBody(req, SEND_LIMIT);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const text = String(body.text || '').replace(/\r\n?/g, '\n');
      const lines = text ? text.split('\n').length : 0;
      // 「押したのに効かない」を後から追えるようにする。ただし本文は残さない。
      // ⚠️ 以前は8文字以下なら中身を丸ごと出していた（数字ボタンの調査のため）。
      // それだと短い合言葉のようなものまでログに残る（2026-09-01 点検で判明）。
      // 中身を出すのは、調べたい対象そのものである「番号」だけにする
      const shown = /^[0-9]{1,2}$/.test(text) ? JSON.stringify(text) : text.length + '文字';
      console.log(`send ${name} ${shown}${lines > 1 ? '/' + lines + '行' : ''}${body.enter ? ' +Enter' : ''}`);
      // 長い1行も控え経由にする（2026-09-02）。tmux は引数をサーバーへ渡すときの
      // 電文に上限があり、**改行を含まない本文は約16.3KBで `command too long` になって
      // 500 になる**（実測：16,000B は通る／16,400B から落ちる）。上限を 8MB に上げても
      // ここは通らないので、大きい1行は標準入力で渡す load-buffer に寄せる。
      // ⚠️ 短い1行は今までどおり send-keys のまま（貼り付け方式が変わると見え方が
      // 変わりうるため。数字キーの「1」もここを通る）。境目は上限の半分で余裕を取る。
      const bigLine = Buffer.byteLength(text, 'utf8') > SEND_ARGV_MAX;
      if (lines > 1 || bigLine) {
        // 複数行は「角括弧ペースト」で入れる（-p）。素直に送ると、改行のたびに
        // Enter を押したのと同じ＝1行ごとに実行されてしまう（2026-08-13 実測）。
        // 名前つきの控えに置いて、貼ったら消す（-d）＝tmux の貼り付け履歴を汚さない
        const r = await tmuxStdin(['load-buffer', '-b', PASTE_BUF, '-'], text);
        if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
        const p = await tmux(['paste-buffer', '-b', PASTE_BUF, '-d', '-p', '-t', '=' + name + ':']);
        if (!p.ok) return json(res, 500, { error: p.err.slice(0, 200) });
      } else if (text) {
        // ⚠️ 引数の終わり印（--）と末尾セミコロンの二重エスケープが要る。
        // 詳しくは sendKeysArg のコメント（2026-09-02 点検で判明した2件）
        const r = await tmux(['send-keys', '-t', '=' + name + ':', '-l', '--', sendKeysArg(text)]);
        if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
      }
      if (body.enter) await tmux(['send-keys', '-t', '=' + name + ':', 'Enter']);
      // 文字を送った＝もう「止めたまま置いてある」ではない。中断の札を降ろす
      // （`resume` の「続けて」も、手で打った指示も、ここを通る）
      clearPaused(name);
      forgetScreen(name);   // 送った直後に見に行くので、撮り置きは捨てる
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
      // キー名にも引数の終わり印を入れる。`-` 始まりの12字は上の正規表現を通ってしまい、
      // tmux が旗として読んで 500 になる（/api/send と同じ穴。2026-09-02）。
      // Up / C-u / Escape / Enter が `--` 付きでも効くことは実測ずみ
      const r = await tmux(['send-keys', '-t', '=' + name + ':', '--', key]);
      forgetScreen(name);
      return json(res, r.ok ? 200 : 500, r.ok ? { ok: true } : { error: r.err.slice(0, 200) });
    }

    // 中断の札を立てる／降ろす。画面の字だけに頼らず、**押した事実**で決める。
    // esc で枠を閉じただけのときのように、画面に印が残らない止めかたもあるため。
    // ⚠️ tmux には何も送らない。ここは札だけを動かす口
    if (p === '/api/pause' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const on = body.on !== false;
      if (on) markPaused(name); else clearPaused(name);
      console.log(`pause ${name} ${on ? 'on' : 'off'}`);
      forgetScreen(name);   // すぐ見に行くので撮り置きは捨てる
      return json(res, 200, { ok: true });
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
      forgetSeat(name);     // 同じ名前の前の住人の姿・画面を持ち越さない
      prev.delete(name);
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

    // 画像やPDFを Mac に置く。Claude Code はファイルそのものを受け取れないが、
    // 「ファイルの場所」を渡せば読める。置いた場所を返して、入力欄に差し込む。
    // ⚠️ 中身は base64（元の約1.34倍）で届く。読み取りの上限はそのぶん多く要る
    if (p === '/api/upload' && req.method === 'POST') {
      const body = await readBody(req, 32 * 1024 * 1024);
      const data = String(body.data || '');
      const buf = Buffer.from(data, 'base64');
      if (!buf.length) return json(res, 400, { error: 'empty' });
      if (buf.length > MAX_UPLOAD) return json(res, 413, { error: '20MBまでです' });

      // 拡張子は中身（マジックバイト）で決める。名前は信用しない
      const ext = sniffUpload(buf);
      if (!ext) return json(res, 415, { error: '画像かPDFとして読めません' });

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
      forgetSeat(name);
      resizedAt.delete(name);
      prev.delete(name);    // 前の住人の画面を、新しい席の「動いた／動いていない」に持ち越さない
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
        if (r.ok) {
          killed.push(name); sized.delete(name); resizedAt.delete(name); prev.delete(name); forgetSeat(name);
          console.log(`kill ${name} (まとめて)`);
        }
        else skipped.push({ name, why: '失敗' });
      }
      return json(res, 200, { ok: true, killed, skipped });
    }

    return json(res, 404, { error: 'not found' });
  } catch (e) {
    // 大きすぎて読むのをやめたときは、日本語の理由を返す（電波のせいに見せない）。
    // 返事を書き終えてから残りの受信を切る（先に切ると返事が届かない）
    if (e && e.tooLarge) {
      res.on('finish', () => { try { req.destroy(); } catch (e2) {} });
      // 64KB の口で「上限 0.1MB」と出ると、実際より大きい数字を言うことになる。
      // 1MB 未満は KB で言う
      const lim = e.limit >= 1024 * 1024
        ? Math.round((e.limit / (1024 * 1024)) * 10) / 10 + 'MB'
        : Math.round(e.limit / 1024) + 'KB';
      return json(res, 413, { error: `大きすぎます（上限 ${lim}）。分けて送ってください` });
    }
    return json(res, 500, { error: String(e && e.message || e) });
  }
});

// 出先では Mac に手が届かない＝落ちたら復旧できない（LaunchAgent が起こし直しても、
// 起動ごとの通し番号が変わるので、開いている端末は全部「新しい版」で読み込み直す）。
// 想定していない失敗は、落とさずにログへ残して動き続ける
process.on('uncaughtException', (e) => {
  console.log('!! 例外: ' + String((e && e.stack) || e).slice(0, 500));
});
process.on('unhandledRejection', (e) => {
  console.log('!! 未処理の失敗: ' + String((e && e.stack) || e).slice(0, 500));
});

server.listen(PORT, HOST, () => {
  console.log(`つみきリモート: http://${HOST}:${PORT}/?t=${TOKEN}`);
  console.log(`tmux: ${TMUX}`);
});
