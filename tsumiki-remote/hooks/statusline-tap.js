#!/usr/bin/env node
'use strict';

// つみきリモート — Claude Code のステータス行の「包み」（2026-10-22）。
//
// Claude Code はステータス行のコマンドに、標準入力で JSON を渡してくる。
// そこには 5時間枠・週枠の使用率（応答ヘッダー由来＝追加の問い合わせなし）と、
// その席の文脈の大きさが入っている。これを席ごとのファイルに写してから、
// **同じ標準入力をそのまま元のステータス行（Vibe Island）に渡し、その出力を返す**。
//
//   Claude Code ──stdin──▶ この包み ──写し──▶ ~/.tsumiki-remote/status/<席>.json
//                              └──同じ stdin──▶ vibe-island-statusline ──▶ stdout
//
// 守ること：
//   ・速く（Node の起動込みで 50ms 前後）。ステータス行は会話のたびに走る
//   ・**何があっても失敗を表に出さない**。写せなくても、元のステータス行は必ず呼ぶ。
//     元が無ければ何も出さないだけ。終了コードはいつも 0
//   ・書くのは必要な項目だけ（会話の中身・パス以外の個人情報は写さない）
//   ・書き込みは一時ファイル → rename（読む側に書きかけを見せない）
//
// 環境変数（試験用）：
//   TSUMIKI_STATUS_DIR       写す先（既定 ~/.tsumiki-remote/status）
//   TSUMIKI_STATUSLINE_NEXT  渡す先（既定 ~/.vibe-island/bin/vibe-island-statusline。空文字なら渡さない）

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOME = os.homedir();
const DIR = process.env.TSUMIKI_STATUS_DIR || path.join(HOME, '.tsumiki-remote', 'status');
const NEXT = process.env.TSUMIKI_STATUSLINE_NEXT !== undefined
  ? process.env.TSUMIKI_STATUSLINE_NEXT
  : path.join(HOME, '.vibe-island', 'bin', 'vibe-island-statusline');
// 元のステータス行を待つ上限。Claude Code 側にも締め切りがあるので、ここは保険。
// 固まったときは**プロセスグループごと**止める（孫の sleep などが出力の口を握ったままだと、
// 包みが先に終わっても Claude Code は EOF を待ち続ける）
const NEXT_TIMEOUT_MS = 1500;
// 標準入力の上限。ステータス行の JSON は数 KB。これを超える入力は切って読む
const STDIN_MAX = 1024 * 1024;
// 標準入力が閉じられないまま来ないとき（手で叩いたときなど）の保険
const STDIN_TIMEOUT_MS = 2000;

function num(v) { return typeof v === 'number' && isFinite(v) ? v : null; }

function bucket(b) {
  if (!b || typeof b !== 'object') return null;
  const used = num(b.used_percentage);
  const resets = num(b.resets_at);
  if (used === null) return null;
  return { used_percentage: used, resets_at: resets };
}

// 写す中身。**ここに無い項目は書かない**（transcript_path・会話の中身などは要らない）
function pick(d) {
  const cw = d.context_window && typeof d.context_window === 'object' ? d.context_window : {};
  const cu = cw.current_usage && typeof cw.current_usage === 'object' ? cw.current_usage : null;
  const rl = d.rate_limits && typeof d.rate_limits === 'object' ? d.rate_limits : null;
  const pc = d.prompt_cache && typeof d.prompt_cache === 'object' ? d.prompt_cache : null;
  const tmux = String(process.env.TMUX || '');
  return {
    v: 1,
    at: Date.now(),
    session_id: typeof d.session_id === 'string' ? d.session_id.slice(0, 80) : null,
    cwd: typeof d.cwd === 'string' ? d.cwd.slice(0, 400) : null,
    pane: process.env.TMUX_PANE || null,
    // TMUX は「ソケットのパス,pid,番号」。試験用の別 tmux と本番の %番号 を取り違えないための印
    tmux_socket: tmux ? tmux.split(',')[0] : null,
    version: typeof d.version === 'string' ? d.version.slice(0, 40) : null,
    model: d.model && typeof d.model === 'object'
      ? { id: String(d.model.id || '').slice(0, 80), display_name: String(d.model.display_name || '').slice(0, 80) }
      : null,
    rate_limits: rl ? { five_hour: bucket(rl.five_hour), seven_day: bucket(rl.seven_day) } : null,
    context_window: {
      context_window_size: num(cw.context_window_size),
      total_input_tokens: num(cw.total_input_tokens),
      used_percentage: num(cw.used_percentage),
      remaining_percentage: num(cw.remaining_percentage),
      current_usage: cu ? {
        input_tokens: num(cu.input_tokens),
        cache_creation_input_tokens: num(cu.cache_creation_input_tokens),
        cache_read_input_tokens: num(cu.cache_read_input_tokens),
      } : null,
    },
    prompt_cache: pc ? {
      warm: typeof pc.warm === 'boolean' ? pc.warm : null,
      ttl: typeof pc.ttl === 'string' ? pc.ttl.slice(0, 8) : null,
      expires_at: num(pc.expires_at),
      recache_tokens_if_cold: num(pc.recache_tokens_if_cold),
    } : null,
  };
}

// 席ごとのファイル名。tmux のペインがあればそれ（ソケットの名前を前に付ける＝
// 別の tmux の %3 と混ざらない）、無ければ session_id
function fileName(rec) {
  const safe = (s) => String(s).replace(/[^A-Za-z0-9_.-]/g, '_').slice(0, 80);
  if (rec.pane) {
    const sock = rec.tmux_socket ? path.basename(rec.tmux_socket) : 'tmux';
    return 'pane-' + safe(sock) + '-' + safe(rec.pane.replace(/^%/, '')) + '.json';
  }
  if (rec.session_id) return 'sid-' + safe(rec.session_id) + '.json';
  return null;
}

function tap(raw) {
  try {
    const d = JSON.parse(raw);
    if (!d || typeof d !== 'object') return;
    const rec = pick(d);
    const name = fileName(rec);
    if (!name) return;
    fs.mkdirSync(DIR, { recursive: true, mode: 0o700 });
    const dest = path.join(DIR, name);
    const tmp = dest + '.' + process.pid + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(rec), { mode: 0o600 });
    fs.renameSync(tmp, dest);
  } catch (e) { /* 写せなくても黙る（ステータス行を止めない） */ }
}

let forwarded = false;
let rawSeen = '';
function forward(raw) {
  if (forwarded) return;     // 2回呼ばれても元のステータス行は1回だけ
  forwarded = true;
  if (!NEXT) return process.exit(0);
  try { fs.accessSync(NEXT, fs.constants.X_OK); } catch (e) { return process.exit(0); }
  let child;
  try {
    // detached ＝ 新しいプロセスグループ。時間切れで孫ごと止めるため
    child = spawn(NEXT, [], { stdio: ['pipe', 'inherit', 'ignore'], detached: true });
  } catch (e) { return process.exit(0); }
  const killGroup = () => {
    try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { try { child.kill('SIGKILL'); } catch (e2) {} }
  };
  const timer = setTimeout(() => { killGroup(); process.exit(0); }, NEXT_TIMEOUT_MS);
  child.on('error', () => { clearTimeout(timer); process.exit(0); });
  child.on('close', () => { clearTimeout(timer); process.exit(0); });
  child.stdin.on('error', () => {});   // 相手が先に閉じても落ちない（EPIPE）
  child.stdin.end(raw);
}

function main() {
  const chunks = [];
  let size = 0;
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    const raw = Buffer.concat(chunks).toString('utf8');
    rawSeen = raw;
    // 写しで何が起きても、元のステータス行は必ず呼ぶ
    try { tap(raw); } catch (e) {}
    forward(raw);
  };
  setTimeout(finish, STDIN_TIMEOUT_MS).unref();
  process.stdin.on('data', (c) => {
    if (size >= STDIN_MAX) return;
    chunks.push(c);
    size += c.length;
    if (size >= STDIN_MAX) finish();   // 1MB で打ち切る（それ以上は読まない）
  });
  process.stdin.on('end', finish);
  process.stdin.on('error', finish);
}

// 包み自体が落ちても、元のステータス行（Vibe Island）は必ず呼ぶ
process.on('uncaughtException', () => {
  try { forward(rawSeen); } catch (e) { process.exit(0); }
});
try { main(); } catch (e) { try { forward(rawSeen); } catch (e2) { process.exit(0); } }
