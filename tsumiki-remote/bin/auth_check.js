#!/usr/bin/env node
'use strict';
//
// ログインの期限まわりを、**時刻を偽って通しで確かめる**道具。
//
//   node bin/auth_check.js
//
// なぜ要るか:
//   この道は本番が壊れるまで一度も動かない。次に効くのは 2026-10-03 01:32 で、
//   そのとき出先で間違っていても直せない。だから「その日」を手元に持ってきて、
//   帯が出る・通知の文面が合う・夜中は鳴らさない・URLが1本に戻る、を毎回確かめる。
//
// 触るもの: 何も触らない。キーチェーンも tmux も ntfy も呼ばない
// （lib/auth.js は入れた値から答えを返すだけの部屋なので、そのまま試せる）。
//
// 終了コード: 0=全部合っている / 1=食い違いあり
//

const fs = require('fs');
const path = require('path');
const AUTH = require('../lib/auth');

const FIX = path.join(__dirname, 'fixtures');
let ng = 0;

function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) ng++;
  console.log((ok ? '  ✓ ' : '  ✗ ') + name
    + (ok ? '' : `\n      出た: ${JSON.stringify(got)}\n      ほしい: ${JSON.stringify(want)}`));
}

function at(s) { return new Date(s).getTime(); }

// ---------------------------------------------------------------- 期限の判断
//
// 2026-09-05 に実際にキーチェーンへ入っていた値。これが「その日」の再現。
//   更新用の鍵の期限 = 09-05 05:05:32（朝の時点でもう切れていた）
//   通行証の期限     = 09-05 12:05:29（ここで更新に行って断られ、鍵が空になった）
const REAL = {
  accessToken: 'あるものとする', refreshToken: 'あるものとする',
  expiresAt: at('2026-09-05T12:05:29+09:00'),
  refreshTokenExpiresAt: at('2026-09-05T05:05:32+09:00'),
};
const EMPTY = { accessToken: '', refreshToken: '', expiresAt: 0,
  refreshTokenExpiresAt: at('2026-09-05T05:05:32+09:00') };

console.log('■ 期限の判断（2026-09-05 に実際に入っていた値で）');
check('前の日の夜21時 → もうすぐ切れる',
  AUTH.stateOf(REAL, at('2026-09-04T21:00:00+09:00')).state, 'soon');
check('当日 06:21（実際に通信できていた時刻）→ もうすぐ切れる',
  AUTH.stateOf(REAL, at('2026-09-05T06:21:54+09:00')).state, 'soon');
check('当日 06:21 の「切れる時刻」は 12:05（更新用はもう切れているので通行証の期限）',
  AUTH.whenText(AUTH.stateOf(REAL, at('2026-09-05T06:21:54+09:00')).deadline),
  AUTH.whenText(at('2026-09-05T12:05:29+09:00')));
check('鍵が空 → 切れている',
  AUTH.stateOf(EMPTY, at('2026-09-05T12:05:31+09:00')).state, 'expired');
check('読めなかった → unknown（切れたとは言わない）',
  AUTH.stateOf(null, Date.now()).state, 'unknown');

console.log('■ 期限の判断（境目）');
const NOW = at('2026-10-02T12:00:00+09:00');
const alive = (refAt) => ({ accessToken: 'a', refreshToken: 'r',
  expiresAt: NOW + 3600e3, refreshTokenExpiresAt: refAt });
check('残り24時間ちょうど → まだ ok',
  AUTH.stateOf(alive(NOW + AUTH.SOON_MS), NOW).state, 'ok');
check('残り23時間59分 → soon',
  AUTH.stateOf(alive(NOW + AUTH.SOON_MS - 60e3), NOW).state, 'soon');
check('期限を1秒過ぎた → expired',
  AUTH.stateOf({ accessToken: 'a', refreshToken: 'r', expiresAt: NOW - 1000,
    refreshTokenExpiresAt: NOW - 1000 }, NOW).state, 'expired');
check('期限の数字が無い → unknown',
  AUTH.stateOf({ accessToken: 'a', refreshToken: 'r' }, NOW).state, 'unknown');

// ------------------------------------------------------------ 夜中は鳴らさない
console.log('■ 鳴らさない時間帯（22時〜8時）');
check('次の期限 2026-10-03 01:32 の24時間前（＝10-02 01:32）は鳴らさない',
  AUTH.quiet(at('2026-10-02T01:32:00+09:00')), true);
check('朝8時ちょうどは鳴らす', AUTH.quiet(at('2026-10-02T08:00:00+09:00')), false);
check('夜21時59分は鳴らす', AUTH.quiet(at('2026-10-02T21:59:00+09:00')), false);
check('夜22時ちょうどは鳴らさない', AUTH.quiet(at('2026-10-02T22:00:00+09:00')), true);

// ------------------------------------------------------------------ 通知の文面
console.log('■ iPhone に出る文面');
const soon = AUTH.notifyText('soon', at('2026-10-03T01:32:00+09:00'));
check('もうすぐ：見出し', soon.title, 'Claude のログインがもうすぐ切れます');
check('もうすぐ：本文に期限が入る', /10\/3/.test(soon.body) && /01:32|1:32/.test(soon.body), true);
check('切れた：強めに鳴らす', AUTH.notifyText('expired', 0).priority, 'high');
check('戻った：静かに鳴らす', AUTH.notifyText('ok', Date.now()).priority, 'low');
check('unknown では何も送らない', AUTH.notifyText('unknown', 0), null);

// ------------------------------------------------------------- URLの拾い直し
console.log('■ サインインURLの拾い直し（架空データの画面から）');
const want = 450;   // fixtures の中の架空URLの長さ
for (const f of ['login画面_51桁.txt', 'login画面_80桁.txt']) {
  const u = AUTH.findLoginUrl(fs.readFileSync(path.join(FIX, f), 'utf8'));
  check(f + ' から1本に戻せる', u ? u.length : 0, want);
  check(f + ' の中身が揃っている',
    !!u && ['client_id=', 'state=', 'code_challenge=', 'redirect_uri=', 'scope=']
      .every((k) => u.includes(k)), true);
}
// ⚠️ ここがいちばん大事。**切れたURLを「開けるリンク」として渡さない**
const cut = fs.readFileSync(path.join(FIX, 'login画面_51桁.txt'), 'utf8')
  .split('\n').slice(0, 8).join('\n');   // 途中で画面が切れた場合
check('途中で切れていたら渡さない（null）', AUTH.findLoginUrl(cut), null);
check('URLが無い画面では null', AUTH.findLoginUrl('ふつうの画面です\n❯ '), null);

console.log(ng ? `\n✗ 食い違い ${ng} 件` : '\n✓ 全部そろっています');
process.exit(ng ? 1 : 0);
