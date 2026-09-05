'use strict';
//
// Claude のログインの期限まわりの「判断」だけを集めた小さな部屋。
//
// なぜ server.js から出したか:
//   期限の判断（いつ切れる・いつ知らせる・URLがちゃんと拾えているか）は、
//   **本番が壊れるまで一度も動かない道**になりやすい。次に効くのは 2026-10-03 で、
//   そのとき出先で間違っていても直せない。だから外から呼べる形にして、
//   `bin/auth_check.js` で時刻を偽って通しで確かめられるようにした。
//
// ここには入れないもの: キーチェーンを読む・通知を送る・ログに書く（＝副作用）。
// それは server.js の仕事。ここは「入れた値から答えを返す」だけにしておく＝
// 試すのに本物のキーチェーンも ntfy も要らない。
//

const SOON_MS = 24 * 3600 * 1000;   // 残りこれを切ったら「もうすぐ切れます」

// キーチェーンの中身 → { state, deadline }
//   ok      … まだ余裕がある
//   soon    … 24時間以内に切れる
//   expired … もう切れている（鍵が空、または期限を過ぎている）
//   unknown … 読めなかった。**「切れた」とは言わない**（読めないことと切れたことは別。
//             一緒にすると、鍵が閉じているだけの朝に嘘をつく）
function stateOf(o, now) {
  now = now || Date.now();
  if (!o) return { state: 'unknown', deadline: 0 };
  const acc = typeof o.accessToken === 'string' ? o.accessToken : '';
  const ref = typeof o.refreshToken === 'string' ? o.refreshToken : '';
  // 更新を断られたとき Claude Code は鍵を空にして片付ける＝これが「切れた」の印
  // （2026-09-05 実測：他の項目は残ったまま、鍵2つだけが空文字になっていた）
  if (!acc || !ref) return { state: 'expired', deadline: 0 };
  const accAt = Number(o.expiresAt) || 0;
  const refAt = Number(o.refreshTokenExpiresAt) || 0;
  // 更新用の鍵が生きているあいだは、その期限が「ログインそのものの寿命」。
  // すでに切れているなら、次の更新で落ちる＝手持ちの通行証が切れる時刻が最期。
  // ⚠️ 2026-09-05 は後者だった（更新用は朝5:05に切れ、通行証は12:05まで生きていた）
  const deadline = refAt > now ? refAt : accAt;
  if (!deadline) return { state: 'unknown', deadline: 0 };
  if (deadline <= now) return { state: 'expired', deadline };
  return { state: deadline - now < SOON_MS ? 'soon' : 'ok', deadline };
}

// 夜中は鳴らさない時間帯か。「もうすぐ切れます」は24時間前に出るので、
// 期限が深夜だと知らせも深夜になる（実際、次の期限は 2026-10-03 01:32）
function quiet(now) {
  const h = new Date(now || Date.now()).getHours();
  return h < 8 || h >= 22;
}

// 期限を「いつ」で言う。ntfy の本文に入れる用（画面側は index.html の authWhen）
function whenText(deadline) {
  if (!deadline) return '';
  return new Date(deadline).toLocaleString('ja-JP',
    { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// iPhone に送る一言。送るのは決まり文句と時刻だけ（鍵も題名も外に出さない）。
// 返すのは { title, body, tags, priority }。送らない状態なら null
function notifyText(state, deadline) {
  const when = whenText(deadline);
  if (state === 'expired') {
    return { title: 'Claude のログインが切れました',
      body: 'つみきリモートから入り直せます', tags: 'warning', priority: 'high' };
  }
  if (state === 'soon') {
    return { title: 'Claude のログインがもうすぐ切れます',
      body: when + ' に切れます。今のうちに入り直せます', tags: 'hourglass', priority: 'default' };
  }
  if (state === 'ok') {
    return { title: 'Claude のログインが戻りました',
      body: '席はそのまま続けられます', tags: 'white_check_mark', priority: 'low' };
  }
  return null;
}

// ------------------------------------------------ サインインのURLを画面から拾う
//
// `/login` を打つと席の画面にサインインのURLが出るので、それを拾って
// iPhone で押せるリンクとして渡す（サインインは本人がブラウザで行う）。
//
// ⚠️ **URLは端末の幅で何行にも割れて出る**（2026-09-05 実測・80桁で6行／
//    iPhone の51桁で7行）。しかも `capture-pane -J` ではつながらなかった。
//    Claude Code 側が自分で折り返して出しているので、tmux から見ると
//    「折り返し」ではなく別の行になる。だから URL の頭の行を見つけたら、
//    **続きに見える行を自分でつなぐ**（空でない・空白を含まない・URLに使える字だけ）。
//
// ⚠️ 途中で切れたURLは返さない（押した先がログイン画面でないと、出先では
//    何が起きたのかも分からなくなる）。`state=` が末尾に付くので、
//    **client_id= と state= が揃っていること**を切れていない印として使う。
//    Anthropic 側が並びを変えたらこの見張りは効かなくなるが、そのときは
//    「URLが拾えません」と出るだけ＝壊れたリンクを渡すことはない。
const LOGIN_URL_HEAD = /https:\/\/(?:claude\.com|claude\.ai|console\.anthropic\.com)\/[A-Za-z0-9_./-]*oauth\/authorize\?/;
const URL_CHARS = /^[A-Za-z0-9\-._~:/?#[\]@!$&'()*+,;=%]+$/;

function findLoginUrl(text) {
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(LOGIN_URL_HEAD);
    if (!m) continue;
    let u = lines[i].slice(m.index).trim();
    // 続きに見える行だけをつなぐ。空行・空白入りの行が来たらそこで終わり
    for (let j = i + 1; j < lines.length; j++) {
      const t = lines[j].trim();
      if (!t || t !== lines[j].replace(/\s/g, '') || !URL_CHARS.test(t)) break;
      u += t;
    }
    found.push(u.replace(/[)\]}.,]+$/, ''));
  }
  // 切れていないものだけ。同じ画面に前回のURLが残っていることがあるので、
  // いちばん新しい（下にある）ものを返す
  const ok = found.filter((u) => u.includes('client_id=') && u.includes('state='));
  return ok.length ? ok[ok.length - 1] : null;
}

module.exports = { SOON_MS, stateOf, quiet, whenText, notifyText, findLoginUrl };
