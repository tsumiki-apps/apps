// つみきロック（Mac の幕）とのやりとりと、Face ID（パスキー）の確かめ。
//
//   iPhone ──/api/lock/*──▶ server.js ──127.0.0.1:8797──▶ TsumikiLock.app（幕）
//
// パスキーは「この iPhone の持ち主の顔（指）で通った」ことの証明として使う。
// 公開鍵だけを ~/.tsumiki-remote/passkeys.json に置く（秘密は iPhone から出ない）。
// 確かめ方は WebAuthn の決まりどおり：
//   ① 渡した問い（challenge）が1回きりで、60秒以内に戻ってきた
//   ② 出どころ（origin）が https://<この Mac の ts.net の名前>
//   ③ authenticatorData の rpIdHash がその名前の SHA-256・UP と UV（＝本人確認済み）が立っている
//   ④ 署名が authenticatorData ‖ SHA-256(clientDataJSON) に対して、登録した公開鍵で正しい
// ⚠️ 合言葉（?t=）を持っていれば席に何でも打てるので、ここは「合言葉の上にもう1枚」であって、
//    合言葉が漏れたときの最後の砦ではない（README）。

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');

const CONF = path.join(os.homedir(), '.tsumiki-remote');
const PASSKEY_FILE = process.env.TSUMIKI_PASSKEY_FILE || path.join(CONF, 'passkeys.json');
const KEY_FILE = process.env.TSUMIKI_LOCK_KEY_FILE || path.join(CONF, 'lock-key');
const LOCK_PORT = Number(process.env.TSUMIKI_LOCK_PORT || 8797);

const b64u = (buf) => Buffer.from(buf).toString('base64url');
const unb64u = (s) => Buffer.from(String(s || ''), 'base64url');
const sha256 = (b) => crypto.createHash('sha256').update(b).digest();

// ------------------------------------------------------------ 幕との口

function lockCall(method, p, body) {
  let key;
  try { key = fs.readFileSync(KEY_FILE, 'utf8').trim(); } catch (e) { return Promise.resolve({ ok: false, code: 0, data: { error: '幕のアプリが入っていません' } }); }
  const data = body ? JSON.stringify(body) : '';
  return new Promise((resolve) => {
    const rq = http.request({ host: '127.0.0.1', port: LOCK_PORT, path: p, method, timeout: 3000,
      headers: { 'x-lock-key': key, 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        let j = {};
        try { j = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (e) { /* 空の返事 */ }
        resolve({ ok: res.statusCode === 200, code: res.statusCode, data: j });
      });
    });
    rq.on('timeout', () => rq.destroy(new Error('timeout')));
    rq.on('error', () => resolve({ ok: false, code: 0, data: { error: '幕のアプリが動いていません' } }));
    rq.end(data);
  });
}

// 巡回（/api/state）に乗せる写し。2秒ごとに幕へ聞きに行く（127.0.0.1 なので軽い）
let snap = { app: false };
async function refresh() {
  const r = await lockCall('GET', '/status');
  snap = r.ok ? Object.assign({ app: true }, r.data, { passkeys: loadKeys().length }) : { app: false, passkeys: loadKeys().length };
  return snap;
}
setInterval(() => { refresh().catch(() => {}); }, 2000).unref();
refresh().catch(() => {});
function snapshot() { return snap; }

// ------------------------------------------------------------ パスキー

// 無い＝0件。あるのに読めない＝null（壊れたときに「最初の登録」の道が開き直らないように）
function readKeys() {
  let raw;
  try { raw = fs.readFileSync(PASSKEY_FILE, 'utf8'); } catch (e) { return e.code === 'ENOENT' ? [] : null; }
  try { const a = JSON.parse(raw); return Array.isArray(a) ? a : null; } catch (e) { return null; }
}
function loadKeys() { return readKeys() || []; }
function keysBroken() { return readKeys() === null; }
function saveKeys(a) {
  fs.writeFileSync(PASSKEY_FILE + '.tmp', JSON.stringify(a, null, 1), { mode: 0o600 });
  fs.renameSync(PASSKEY_FILE + '.tmp', PASSKEY_FILE);
}

// 問いは1回きり・60秒。何のための問いか（purpose）も一緒に覚える＝
// 「登録の問い」で取った署名を「解除」に使い回せない
const challenges = new Map();
const PURPOSES = new Set(['register', 'unlock', 'pin', 'add']);
function newChallenge(purpose) {
  if (!PURPOSES.has(purpose)) return null;
  const now = Date.now();
  for (const [k, v] of challenges) if (v.exp < now) challenges.delete(k);
  // 連打で溜めない。消すのは古いほうから（全部消すと本人が取っておいた問いまで消える）
  while (challenges.size >= 50) challenges.delete(challenges.keys().next().value);
  const c = b64u(crypto.randomBytes(32));
  challenges.set(c, { purpose, exp: now + 60000 });
  return c;
}
function takeChallenge(c, purpose) {
  const v = challenges.get(c);
  challenges.delete(c);
  return !!v && v.purpose === purpose && v.exp >= Date.now();
}

// 名前は Host から取る（tailscale serve がそのまま渡す）。ts.net の https 以外ではパスキーは作れない
function rpOf(req) {
  const host = String(req.headers.host || '').replace(/:\d+$/, '').toLowerCase();
  return /^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$/.test(host) ? host : null;
}

function options(req, purpose) {
  const rpId = rpOf(req);
  if (!rpId) return { error: 'https（…ts.net）で開いたときだけ使えます' };
  const challenge = newChallenge(purpose);
  if (!challenge) return { error: 'bad purpose' };
  const keys = loadKeys().filter((k) => k.rpId === rpId);
  return { challenge, rpId, allow: keys.map((k) => k.id), userId: b64u(sha256(Buffer.from('tsumiki-lock:' + rpId)).subarray(0, 16)) };
}

function checkClient(cdB64, type, purpose, rpId) {
  const cdRaw = unb64u(cdB64);
  let cd;
  try { cd = JSON.parse(cdRaw.toString('utf8')); } catch (e) { return { error: '返事が読めません' }; }
  if (cd.type !== type) return { error: '種類が違います' };
  if (!takeChallenge(cd.challenge, purpose)) return { error: '問いが古いか、使い済みです。もう一度押してください' };
  if (cd.origin !== 'https://' + rpId) return { error: '出どころが違います' };
  return { cdRaw };
}

function checkAuthData(ad, rpId) {
  if (ad.length < 37) return '本人確認のデータが短すぎます';
  if (!ad.subarray(0, 32).equals(sha256(Buffer.from(rpId)))) return '名前が違います';
  const flags = ad[32];
  if (!(flags & 0x01) || !(flags & 0x04)) return 'Face ID で本人確認されていません';
  return null;
}

// 登録：iPhone 側で navigator.credentials.create → getPublicKey()（SPKI）を送ってもらう
// ⚠️ attestation:none なので、ここの確かめは「本物の認証器で作った」ことを証明しない
//    （手で組んだ鍵とデータでも通る＝反証役が確認）。登録を守っているのは server.js 側の
//    「0件・幕のアプリが応答している・幕が外れている」と、2件目からの Face ID だけ。
//    下の確かめは、壊れた送りものを早めに断るためのもの
function register(req, body, name) {
  const rpId = rpOf(req);
  if (!rpId) return { error: 'https（…ts.net）で開いたときだけ使えます' };
  const c = checkClient(body.clientDataJSON, 'webauthn.create', 'register', rpId);
  if (c.error) return c;
  const ad = unb64u(body.authenticatorData);
  const bad = checkAuthData(ad, rpId);
  if (bad) return { error: bad };
  if (Number(body.alg) !== -7) return { error: 'ES256 のパスキーだけ受け付けます' };
  let pub;
  try { pub = crypto.createPublicKey({ key: unb64u(body.publicKey), format: 'der', type: 'spki' }); }
  catch (e) { return { error: '公開鍵が読めません' }; }
  if (pub.asymmetricKeyType !== 'ec' || (pub.asymmetricKeyDetails || {}).namedCurve !== 'prime256v1') {
    return { error: 'ES256（P-256）のパスキーだけ受け付けます' };
  }
  const id = String(body.id || '');
  if (!/^[A-Za-z0-9_-]{16,400}$/.test(id)) return { error: 'bad id' };
  if (keysBroken()) return { error: 'passkeys.json が読めません' };
  const keys = loadKeys().filter((k) => k.id !== id);
  keys.push({ id, rpId, publicKey: body.publicKey, counter: ad.readUInt32BE(33), name: String(name || '').slice(0, 40), created: Date.now() });
  saveKeys(keys);
  return { ok: true, count: keys.length };
}

// 本人確認：navigator.credentials.get の返事を確かめる
function verify(req, a, purpose) {
  const rpId = rpOf(req);
  if (!rpId) return { error: 'https（…ts.net）で開いたときだけ使えます' };
  if (!a || typeof a !== 'object') return { error: 'Face ID の返事がありません' };
  const keys = loadKeys();
  const k = keys.find((x) => x.id === a.id && x.rpId === rpId);
  if (!k) return { error: 'このパスキーは登録されていません' };
  const c = checkClient(a.clientDataJSON, 'webauthn.get', purpose, rpId);
  if (c.error) return c;
  const ad = unb64u(a.authenticatorData);
  const bad = checkAuthData(ad, rpId);
  if (bad) return { error: bad };
  let ok = false;
  try {
    ok = crypto.verify('sha256', Buffer.concat([ad, sha256(c.cdRaw)]),
      crypto.createPublicKey({ key: unb64u(k.publicKey), format: 'der', type: 'spki' }), unb64u(a.signature));
  } catch (e) { ok = false; }
  if (!ok) return { error: '署名が合いません' };
  // 数え（signCount）。Apple のパスキーは常に0なので、0のときは見ない
  const n = ad.readUInt32BE(33);
  if (n !== 0 || k.counter !== 0) {
    if (n <= k.counter) return { error: '数えが戻っています（写しの疑い）' };
    k.counter = n;
    saveKeys(keys);
  }
  return { ok: true };
}

module.exports = { lockCall, refresh, snapshot, loadKeys, keysBroken, options, register, verify, rpOf };
