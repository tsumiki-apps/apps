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
  // いちばん下のURLの頭だけを見る。同じ画面（-S -200 の履歴）に前回のURLが残って
  // いても、いちばん新しいものが不完全なら古い方を渡さず null にする（反証役 2026-11-24）
  let i = -1, m = null;
  for (let k = lines.length - 1; k >= 0; k--) {
    const mm = lines[k].match(LOGIN_URL_HEAD);
    if (mm) { i = k; m = mm; break; }
  }
  if (i < 0) return null;
  let u = lines[i].slice(m.index).trim();
  let endBlank = false;   // URLのあとに空行が来た（＝Claude Code の画面どおりに終わった）
  let j = i + 1;
  // 続きに見える行だけをつなぐ。空行・空白入りの行が来たらそこで終わり
  for (; j < lines.length; j++) {
    const t = lines[j].trim();
    if (!t) { endBlank = true; break; }
    if (t !== lines[j].replace(/\s/g, '') || !URL_CHARS.test(t)) break;
    u += t;
  }
  u = u.replace(/[)\]}.,]+$/, '');
  // 従来の長い形：client_id と state が揃っていれば切れていない（state は末尾に付く）
  if (u.includes('client_id=') && u.includes('state=')) return u;
  // 2026-11-24 から Claude Code は短い形（`/oauth/authorize?z-<43字ほど>`、client_id も
  // state も無い）を出す。今までは全部「切れている」扱いで捨て、シートが「URLを待っています…」
  // のまま止まっていた。短い形は印が無いので、次の3つが揃ったときだけ渡す（反証役）
  //   ① `?z-` のあとが英数字 40〜46字だけ（実測43字＝32バイトの base64url。途中で切れた短い断片や、
  //      続きの行に付いた英単語でずれた長さを弾く）
  //   ② URLのすぐ下が空行（画面の下端・書きかけで切れていない）
  //   ③ その下に「Paste code here」がある（ログインの画面の続きが描かれ終わっている）
  if (!/\/oauth\/authorize\?z-[A-Za-z0-9_-]{40,46}$/.test(u)) return null;
  if (!endBlank) return null;
  if (!lines.slice(j).some((l) => /Paste code here/.test(l))) return null;
  return u;
}

// ------------------------------------------------ ログインの方法を選ぶ画面
//
// `/login` を打つと、まず「Select login method:」の3択が出る。出先の本人はいつも
// 1（Claude account with subscription）を手で押していた＝毎回同じ答えなので、こちらで押す。
// ⚠️ 押してよいのは**この画面で、カーソルが 1. Claude account に乗っているとき**だけ。
//    ほかの選ぶ画面（許可・質問）に数字を打つと、その答えになってしまう。
//    Claude Code 側の文言が変わったら押さなくなるだけ＝今までどおり手で押せる。
function loginMethodOpen(text) {
  const tail = String(text || '').replace(/\r/g, '').replace(/\s+$/, '').split('\n').slice(-15);
  // ⚠️ 「見出しの下のどこかに1行ある」では足りない（反証役）。返事の本文や許可の画面の
  //    コマンド表示にこの2行が載っていても true になり、許可の画面なら '1' が「Yes」になる。
  //    なので①いちばん下の行が `Esc to cancel` ②いちばん下の `❯` の行（＝本当のカーソル）が
  //    1. Claude account ③その上に見出し、の3つが揃ったときだけ
  if (!/^\s*Esc to cancel\s*$/.test(tail[tail.length - 1] || '')) return false;
  let cur = -1;
  for (let i = tail.length - 1; i >= 0; i--) if (/^\s*❯/.test(tail[i])) { cur = i; break; }
  if (cur < 0 || !/^\s*❯\s*1\.\s*Claude account with subscription/.test(tail[cur])) return false;
  return tail.slice(0, cur).some((l) => /^\s*Select login method:\s*$/.test(l));
}

// ------------------------------------------------ ログインが通った画面
//
// コードを貼ると「Login successful. Press Enter to continue…」で止まる。
// 2026-10-28 本人が出先でここに来て、通ったのかどうか分からず、Enter も要るのに
// 気づけなかった（帯も黄色のまま）。なのでこちらで見つけて Enter を押す。
// ⚠️ 押してよいのは**いちばん下の意味のある行がこの文**のときだけ。返事の本文に
//    同じ文が載っていても、下に入力欄などが続いていれば押さない。
function meaningful(text) {
  return String(text || '').replace(/\r/g, '').split('\n')
    .map((l) => l.trim()).filter((l) => l && !/^[│─╭╮╰╯\s]*$/.test(l));
}
function loginDone(text) {
  const lines = meaningful(text);
  const last = lines[lines.length - 1] || '';
  return /^Login successful\.\s*Press Enter to continue/i.test(last);
}

// コードを貼る欄が**いま開いているか**。いちばん下が `Esc to cancel`、そのすぐ上が
// `Paste code here` の行のときだけ。クリップボードの中身を席へ送ってよいのはこのときだけ
// ＝通った後や別の画面に送ると、鍵のような文字列がふつうの指示として送られてしまう（反証役）
function pasteOpen(text) {
  const lines = meaningful(text);
  if (!/^Esc to cancel$/.test(lines[lines.length - 1] || '')) return false;
  return /^Paste code here/i.test(lines[lines.length - 2] || '');
}

module.exports = { SOON_MS, stateOf, quiet, whenText, notifyText, findLoginUrl, loginMethodOpen, loginDone, pasteOpen };
