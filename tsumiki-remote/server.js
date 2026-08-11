#!/usr/bin/env node
'use strict';

// つみきリモート — Mac の tmux セッションをスマホから見て指示するための小さなサーバー。
// 依存パッケージなし（Node 標準ライブラリだけ）。tmux にコマンドを投げているだけ。

const http = require('http');
const fs = require('fs');
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

// ---------------------------------------------------------------- tmux

const NAME_RE = /^[A-Za-z0-9_.-]{1,32}$/;

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

// tmux は書式出力中のタブを "_" に潰すので、区切りには使えない
const SEP = '|::|';

async function listSessions() {
  const r = await tmux(['list-sessions', '-F', `#{session_name}${SEP}#{window_name}${SEP}#{session_activity}`]);
  if (!r.ok) return []; // tmux サーバーが起動していない = セッション 0
  return r.out
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [name, window, activity] = line.split(SEP);
      return { name, window, activity: Number(activity) || 0 };
    });
}

// そのセッションで動いているのが Claude Code か、素のシェルか。
// ここが見えないと「AIに話しかけたつもりがシェルに打っていた」が起きる。
async function currentCommand(name) {
  if (!NAME_RE.test(name)) return '';
  const r = await tmux(['display-message', '-p', '-t', '=' + name + ':', '#{pane_current_command}']);
  return r.ok ? r.out.trim() : '';
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

function authed(req, url) {
  const t = url.searchParams.get('t') || req.headers['x-token'];
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
      orientation: 'portrait',
      background_color: '#0e0f12',
      theme_color: '#0e0f12',
      icons: [
        { src: 'icon-180.png', sizes: '180x180', type: 'image/png' },
        { src: 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
      ],
    };
    return send(res, 200, JSON.stringify(manifest), 'application/manifest+json; charset=utf-8');
  }

  if (!p.startsWith('/api/')) return serveStatic(res, p);

  if (!authed(req, url)) return json(res, 401, { error: 'unauthorized' });

  try {
    // 全セッションの状態一覧
    if (p === '/api/state' && req.method === 'GET') {
      const sessions = await listSessions();
      const out = [];
      for (const s of sessions) {
        const text = (await captureScreen(s.name)) || '';
        const { status, quietMs } = judge(s.name, text);
        const cmd = await currentCommand(s.name);
        out.push({
          name: s.name, window: s.window, status, quietMs,
          kind: kindOf(cmd), command: cmd,
          preview: lastMeaningfulLine(text),
        });
      }
      return json(res, 200, { sessions: out, now: Date.now() });
    }

    // 1セッションの画面
    if (p === '/api/pane' && req.method === 'GET') {
      const name = url.searchParams.get('name') || '';
      const lines = Number(url.searchParams.get('lines') || 400);
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
      const text = String(body.text || '').replace(/[\r\n]+/g, ' ');
      if (text) {
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
      const r = await tmux(['new-session', '-d', '-s', name, '-c', fs.existsSync(cwd) ? cwd : os.homedir()]);
      if (!r.ok) return json(res, 500, { error: r.err.slice(0, 200) });
      if (body.run === 'claude') {
        await tmux(['send-keys', '-t', '=' + name + ':', '-l', 'claude']);
        await tmux(['send-keys', '-t', '=' + name + ':', 'Enter']);
      }
      return json(res, 200, { ok: true });
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

    // セッションを閉じる（中で動いているものごと終了する）
    if (p === '/api/kill' && req.method === 'POST') {
      const body = await readBody(req);
      const name = String(body.name || '');
      if (!NAME_RE.test(name)) return json(res, 400, { error: 'bad name' });
      const r = await tmux(['kill-session', '-t', '=' + name + ':']);
      prev.delete(name);
      return json(res, r.ok ? 200 : 500, r.ok ? { ok: true } : { error: r.err.slice(0, 200) });
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
