#!/usr/bin/env node
// 履歴の中のファイル名を「光らせる種類」の点検（2026-09-30）。
//
// 使い方: node bin/link_ext_check.js     ✗ が1件でもあれば終了コード1
//
// ① 同じ一覧が3か所にある：server.js の LINK_EXT／index.html の RE_FILE・RE_SENT_EXT。
//    1か所だけ足すと、照合はするのに光らない（またはその逆）になる。3つが同じかを見る。
// ② 実際に作って送っている種類（~/.tsumiki-remote/made.jsonl の印）のうち、
//    3件以上あるのに光らない種類を挙げる。
//    `.shortcut` は印で32件あったのに一覧に無く、送るたびに光らなかった（本人の指摘で発覚）。
//    作業用の種類（下の WORK）は、本人が iPhone で開くものではないので対象外。
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = path.join(__dirname, '..');
const WORK = new Set(['py', 'swift', 'wflow', 'sql', 'mjs', 'js', 'css', 'sh', 'plist', 'log']);
const MIN = 3;

function exts(src) {
  return new Set(src.split('|').map((e) => e.replace('?', '')).flatMap((e) =>
    e === 'jpeg' ? ['jpg', 'jpeg'] : e === 'html' ? ['htm', 'html'] : [e]));
}
function pick(file, re, label) {
  const m = re.exec(fs.readFileSync(path.join(ROOT, file), 'utf8'));
  if (!m) { console.log(`✗ ${label} が見つからない（${file}）`); process.exitCode = 1; return null; }
  return { label, src: m[1], set: exts(m[1]) };
}

const lists = [
  pick('server.js', /const LINK_EXT = \/\\\.\(([^)]+)\)\$\/i;/, 'server.js LINK_EXT'),
  pick('public/index.html', /\+ '\\\\\.\(\?:([^)]+)\)\(\?!\[A-Za-z0-9\]\)', 'g'\);/, 'index.html RE_FILE'),
  pick('public/index.html', /var RE_SENT_EXT = \/\\\.\(\?:([^)]+)\)\$\/i;/, 'index.html RE_SENT_EXT'),
].filter(Boolean);

let bad = 0;
const base = lists[0];
for (const l of lists.slice(1)) {
  const miss = [...base.set].filter((e) => !l.set.has(e));
  const extra = [...l.set].filter((e) => !base.set.has(e));
  if (miss.length || extra.length) {
    bad++;
    console.log(`✗ ${l.label} が ${base.label} と違う：足りない=${miss.join(',') || 'なし'} 余分=${extra.join(',') || 'なし'}`);
  }
}

const made = path.join(os.homedir(), '.tsumiki-remote', 'made.jsonl');
if (fs.existsSync(made) && base) {
  const count = {};
  for (const line of fs.readFileSync(made, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    let d; try { d = JSON.parse(line); } catch (e) { continue; }
    const p = d.path || d.rel || d.file || '';
    const e = path.extname(p).slice(1).toLowerCase();
    if (e) count[e] = (count[e] || 0) + 1;
  }
  for (const [e, n] of Object.entries(count).sort((a, b) => b[1] - a[1])) {
    if (n < MIN || WORK.has(e) || base.set.has(e)) continue;
    bad++;
    console.log(`✗ .${e} は印に ${n} 件あるのに光らない（LINK_EXT に足すか、WORK に入れる）`);
  }
} else {
  console.log('（印 made.jsonl が無いので ② は飛ばした）');
}

console.log(bad ? `✗ ${bad}` : `✗ 0（3か所一致・印に多い種類はすべて光る：${[...base.set].join(' ')}）`);
if (bad) process.exitCode = 1;
