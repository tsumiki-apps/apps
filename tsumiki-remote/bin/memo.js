#!/usr/bin/env node
// 席のメモ欄に1行書く（hold で中断した席の Claude が、再開用のメモを残すのに使う）。
//   node ~/制作物/tsumiki-remote/bin/memo.js <席の名前> "<メモ>"
// 画面と同じ口（/api/memo）を通すので、スマホの送り先バーにもすぐ出る。
// 頭に「⏸ 」を付けて、中断のときに書いたメモだと見て分かるようにする
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const [name, ...rest] = process.argv.slice(2);
const text = rest.join(' ').trim();
if (!name || !text) {
  console.error('使い方: node memo.js <席の名前> "<メモ>"');
  process.exit(2);
}
const token = fs.readFileSync(path.join(os.homedir(), '.tsumiki-remote', 'token'), 'utf8').trim();
const body = JSON.stringify({ name, text: /^⏸/.test(text) ? text : '⏸ ' + text });
const req = http.request({
  host: process.env.TSUMIKI_REMOTE_HOST || '127.0.0.1',
  port: Number(process.env.TSUMIKI_REMOTE_PORT || 8787),
  path: '/api/memo', method: 'POST',
  headers: { 'content-type': 'application/json', 'x-token': token, 'content-length': Buffer.byteLength(body) }
}, (res) => {
  let s = '';
  res.on('data', (c) => { s += c; });
  res.on('end', () => {
    if (res.statusCode !== 200) { console.error(`書けませんでした（${res.statusCode}）: ${s}`); process.exit(1); }
    // 中身は出さない＝席の画面（ツールの結果）にメモを写さない。メモ欄で読めば足りる
    console.log(`メモ欄に書きました（${name}）`);
  });
});
req.on('error', (e) => { console.error('つみきリモートに届きません: ' + e.message); process.exit(1); });
req.end(body);
