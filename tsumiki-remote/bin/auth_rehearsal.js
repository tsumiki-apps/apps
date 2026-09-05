#!/usr/bin/env node
'use strict';
//
// ログインの期限まわりを、**iPhone の実機で目で見て確かめる**ための稽古場。
//
//   node bin/auth_rehearsal.js            切れている状態で開く（既定）
//   node bin/auth_rehearsal.js soon       「もうすぐ切れます」の状態で開く
//   node bin/auth_rehearsal.js ok         ふだんの状態（帯は出ない）
//   node bin/auth_rehearsal.js expired --iphone   iPhone から開けるようにする
//
// なぜ要るか:
//   本物の帯が出るのは 2026-10-03 01:32 の24時間前から。それまで「出るはず」の
//   見た目を一度も見られない。ここは**画面（public/index.html）はそのまま本物**で、
//   中身だけ架空にした場所＝帯もシートも本物のコードが描く。
//
// ⚠️ 触らないもの: tmux・キーチェーン・ntfy・本番のサーバー（8787）。
//    席は架空、画面の文字も架空。通知は送らず「送るはずだった文面」を画面に出す。
//    別のポートで動くので、iPhone に残る下書きや写し（localStorage）も別扱いになる。
//

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn, execFileSync } = require('child_process');
const AUTH = require('../lib/auth');

const ROOT = path.join(__dirname, '..');
const PUBLIC_DIR = path.join(ROOT, 'public');
const FIX = path.join(__dirname, 'fixtures');
const PORT = Number(process.env.REHEARSAL_PORT || 8790);
const TOKEN = crypto.randomBytes(12).toString('hex');
const SOCK = path.join(process.env.HOME, '.tsumiki-remote', 'tailscaled.sock');
const TS = '/opt/homebrew/bin/tailscale';

const argv = process.argv.slice(2);
const CASE = argv.find((a) => !a.startsWith('-')) || 'expired';
const IPHONE = argv.includes('--iphone');
if (!['expired', 'soon', 'ok'].includes(CASE)) {
  console.error('使える場面: expired / soon / ok');
  process.exit(2);
}

// ------------------------------------------------------------ 架空のログイン状態
//
// 本物のキーチェーンは読まない。**もし** こういう鍵が入っていたら、で作る＝
// 判断そのもの（lib/auth.js）は本番と同じ道を通る
const now = Date.now();
const FAKE_KEYCHAIN = {
  expired: { accessToken: '', refreshToken: '', expiresAt: 0, refreshTokenExpiresAt: 0 },
  soon: { accessToken: 'a', refreshToken: 'r', expiresAt: now + 3 * 3600e3,
    refreshTokenExpiresAt: now + 5 * 3600e3 },
  ok: { accessToken: 'a', refreshToken: 'r', expiresAt: now + 3600e3,
    refreshTokenExpiresAt: now + 28 * 86400e3 },
}[CASE];
const AUTH_STATE = AUTH.stateOf(FAKE_KEYCHAIN, now);

// ---------------------------------------------------------------- 架空の席2つ
const SEATS = [
  { name: 'renshu1', window: '0', status: 'busy', quietMs: 0, kind: 'claude',
    command: 'claude', title: '稽古用の席', label: '', auto: 'renshu1',
    model: 'opus', preview: '' },
  { name: 'renshu2', window: '0', status: 'idle', quietMs: 60000, kind: 'shell',
    command: 'zsh', title: '稽古用のシェル', label: '', auto: 'renshu2',
    model: '', preview: '' },
];

const IDLE_SCREEN = [
  '  これは稽古場です。tmux にも本物のログインにも触っていません。',
  '',
  '  帯（上のオレンジ／赤）を押すか、⋯ →「Claude にログインし直す」で',
  '  ログインのシートが開きます。',
  '',
  '❯ ',
].join('\n');

const MENU_SCREEN = [
  '  Login', '',
  '  Select login method:', '',
  '  ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise',
  '    2. Anthropic Console account · API usage billing', '',
  '  Esc to cancel',
].join('\n');

const URL_SCREEN = fs.readFileSync(path.join(FIX, 'login画面_51桁.txt'), 'utf8');

let phase = 'idle';        // idle → menu → url
function screen() {
  return phase === 'url' ? URL_SCREEN : phase === 'menu' ? MENU_SCREEN : IDLE_SCREEN;
}

function say(s) { console.log('  ' + s); }

// ------------------------------------------------------------------- 返しかた
function json(res, code, body) {
  const b = Buffer.from(JSON.stringify(body), 'utf8');
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store', 'content-length': b.length });
  res.end(b);
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };

function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => { b += c; if (b.length > 200000) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(b || '{}')); } catch (e) { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;

  if (!p.startsWith('/api/')) {
    // ⚠️ sw.js は配らない。稽古場の画面を iPhone に住み着かせない
    if (p === '/sw.js') { res.writeHead(404); return res.end('稽古場では使いません'); }
    const rel = p === '/' ? 'index.html' : p.replace(/^\/+/, '');
    const file = path.join(PUBLIC_DIR, rel);
    if (!file.startsWith(PUBLIC_DIR + path.sep)) { res.writeHead(403); return res.end(); }
    let buf;
    try { buf = fs.readFileSync(file); } catch (e) { res.writeHead(404); return res.end('ありません'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream',
      'cache-control': 'no-store' });
    return res.end(buf);
  }

  const tok = req.headers['x-token'] || url.searchParams.get('t');
  if (tok !== TOKEN) return json(res, 401, { error: 'unauthorized' });

  if (p === '/api/state') {
    return json(res, 200, {
      sessions: SEATS,
      usage: { session: { used: 34, resetsAt: new Date(now + 2 * 3600e3).toISOString() },
        week: { used: 61, resetsAt: new Date(now + 3 * 86400e3).toISOString() },
        ageMs: 30000, stale: false },
      usageWait: null,
      battery: { pct: 78, ac: true, charging: false, remainMin: 0 },
      auth: AUTH_STATE,
      version: 'rehearsal-' + CASE, now: Date.now(),
    });
  }

  if (p === '/api/pane') {
    return json(res, 200, { name: url.searchParams.get('name') || 'renshu1',
      text: screen(), status: phase === 'idle' ? 'busy' : 'waiting', quietMs: 0 });
  }

  if (p === '/api/login' && req.method === 'POST') {
    phase = 'menu';
    say('→ /login を打った（架空）。ログイン方法の画面を出しました');
    // 押さなくても進むようにしておく＝iPhone の指1本でも最後まで見られる
    setTimeout(() => { if (phase === 'menu') { phase = 'url'; say('→ URLの画面に進みました（自動）'); } }, 8000);
    return json(res, 200, { ok: true });
  }

  if (p === '/api/loginurl') {
    const u = AUTH.findLoginUrl(screen());
    if (u) say('→ URLを1本に戻して返しました（' + u.length + '文字）');
    return json(res, 200, { url: u });
  }

  if (p === '/api/send' && req.method === 'POST') {
    const b = await readBody(req);
    const t = String(b.text || '');
    if (phase === 'menu' && t.trim() === '1') { phase = 'url'; say('→ 1 が押されたので URL の画面へ'); }
    else say('→ 送られてきました（' + t.length + '文字）。架空なのでどこにも届きません');
    return json(res, 200, { ok: true });
  }

  // 残りは黙って「はい」と言うだけ（押しても何も起きないのが正しい）
  if (p === '/api/key' || p === '/api/pause' || p === '/api/rename'
      || p === '/api/kill' || p === '/api/killmany' || p === '/api/displaysleep') {
    return json(res, 200, { ok: true });
  }
  if (p === '/api/files') return json(res, 200, { items: [], dirs: [], dir: '' });
  return json(res, 404, { error: 'not found' });
});

// ------------------------------------------------------------------ iPhone用
let tsChild = null;
function serveStatusHas8787() {
  try {
    const out = execFileSync(TS, ['--socket=' + SOCK, 'serve', 'status'], { encoding: 'utf8' });
    return out.includes('127.0.0.1:8787');
  } catch (e) { return null; }   // 分からなかった
}

function stopIphone() {
  if (!tsChild) return;
  tsChild.kill('SIGINT');
  tsChild = null;
  // ⚠️ 本番の通り道（/ → 8787）を巻き添えにしていないか、必ず見て帰る
  setTimeout(() => {
    const ok = serveStatusHas8787();
    if (ok === false) {
      console.log('\n⚠️ 本番の通り道が消えています。戻してください:');
      console.log(`   ${TS} --socket=${SOCK} serve --bg --http=80 http://127.0.0.1:8787`);
    } else if (ok) {
      console.log('\n本番の通り道（/ → 8787）は無事です');
    }
    process.exit(0);
  }, 600);
}

// 前の稽古場が残っていると、素の node は英語の山を吐いて止まる。
// 出先で読むものではないが、次に開く人（自分）が困るので一言で言う
server.on('error', (e) => {
  if (e && e.code === 'EADDRINUSE') {
    console.error(`\nポート ${PORT} は、まだ前の稽古場が使っています。`);
    console.error(`止めかた: kill $(lsof -ti tcp:${PORT})`);
    console.error(`別のポートで開くなら: REHEARSAL_PORT=8791 node bin/auth_rehearsal.js ${CASE}`);
    process.exit(2);
  }
  throw e;
});

server.listen(PORT, '127.0.0.1', () => {
  const local = `http://127.0.0.1:${PORT}/?t=${TOKEN}`;
  console.log(`\n■ ログインの稽古場（${CASE}）`);
  say('帯の状態: ' + AUTH_STATE.state
    + (AUTH_STATE.deadline ? '／切れる時刻: ' + AUTH.whenText(AUTH_STATE.deadline) : ''));
  const t = AUTH.notifyText(AUTH_STATE.state, AUTH_STATE.deadline);
  if (t) {
    say('この状態で iPhone に出るはずの通知（ここでは送りません）:');
    say('  ' + t.title + ' / ' + t.body);
    say('  いまの時刻だと ' + (AUTH.quiet() ? '鳴らさない時間帯（22〜8時）です' : '鳴らす時間帯です'));
  }
  console.log('\n  Mac で見る: ' + local);
  if (IPHONE) {
    const before = serveStatusHas8787();
    tsChild = spawn(TS, ['--socket=' + SOCK, 'serve', '--http=' + PORT, 'http://127.0.0.1:' + PORT],
      { stdio: 'ignore' });
    tsChild.on('error', () => { console.log('  （tailscale serve を動かせませんでした）'); tsChild = null; });
    setTimeout(() => {
      let host = '';
      try {
        host = execFileSync(TS, ['--socket=' + SOCK, 'status', '--json'], { encoding: 'utf8' });
        host = JSON.parse(host).Self.DNSName.replace(/\.$/, '');
      } catch (e) { host = ''; }
      if (host) console.log('  iPhone で見る: http://' + host + ':' + PORT + '/?t=' + TOKEN);
      if (before && serveStatusHas8787() === false) {
        console.log('  ⚠️ 本番の通り道が消えました。Ctrl-C で止めれば戻ります');
      }
      console.log('\n  Ctrl-C で片付けます（iPhone への通り道も一緒に閉じます）');
    }, 1200);
  } else {
    console.log('\n  iPhone からも見たいときは --iphone を付けて動かしてください');
    console.log('  Ctrl-C で終わります');
  }
});

process.on('SIGINT', stopIphone);
process.on('SIGTERM', stopIphone);
