// Supabase Edge Function: notify-reaction
// ゆずごはん日記で「投稿/いいね/コメント/スタンプ」が起きたとき、相手の端末へ Web Push を送る。
// クライアント(cooking.html)が、自分が操作した直後に呼ぶ。
//
// デプロイ: Supabaseダッシュボード → Edge Functions → 「notify-reaction」にこのコードを貼り付け。
// Secret(Project Settings → Edge Functions → Secrets):
//   VAPID_PUBLIC_KEY  … cooking.html の VAPID_PUBLIC と同じ公開鍵
//   VAPID_PRIVATE_KEY … 秘密鍵（クライアントには絶対に置かない）
//   VAPID_SUBJECT     … 連絡先（例: mailto:you@example.com）
// ※ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY は Supabase が自動で渡すので登録不要。

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  try {
    const { kind, actor, recordName, body, emoji, to, actorName } = await req.json();
    if (!actor) return json({ error: "actor が必要です" }, 400);

    const pub = Deno.env.get("VAPID_PUBLIC_KEY");
    const priv = Deno.env.get("VAPID_PRIVATE_KEY");
    const subject = Deno.env.get("VAPID_SUBJECT") || "mailto:example@example.com";
    if (!pub || !priv) return json({ error: "VAPIDキーが未設定です（Secretsを確認）" }, 500);
    webpush.setVapidDetails(subject, pub, priv);

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // 自分以外（＝相手）の端末を取得
    const { data: subs, error } = await sb
      .from("push_subs")
      .select("*")
      .neq("who", actor);
    if (error) return json({ error: error.message }, 500);

    // 2026-08-13〜 家族端末（こうだい/ゆずは 以外の名前）にも通知が届くようになった。
    // ただし家族に送るのは「新しい投稿」だけ。いいね/コメント/スタンプで
    // 1投稿あたり何通も鳴ると、見る側にはうるさいので送らない。
    // 2026-09-06〜 例外：to（@で呼ばれた人・返信された人）に入っている家族には届ける。
    const COUPLE = ["こうだい", "ゆずは"];
    const named: string[] = Array.isArray(to) ? to.filter((x) => typeof x === "string") : [];
    // kind==="mention" は「@で新しく呼んだ人だけ」に送る（コメントを直したときに使う）。
    // 直すたびに相手のぶんまで鳴ると、うるさいので送らない。
    const targets = (subs || []).filter((s) =>
      kind === "mention"
        ? named.includes(s.who)
        : COUPLE.includes(s.who) ? true : (kind === "post" || named.includes(s.who))
    );

    const name = recordName || "日記";
    const from = actorName || actor;   // 表示する名前（本人が設定していればそれ、無ければ鍵の名前）
    const msg = kind === "like"
      ? `${from}さんが「${name}」にいいねしました ❤️`
      : kind === "comment"
      ? `${from}さんが「${name}」にコメントしました 💬${body ? "：" + body : ""}`
      : kind === "reply"
      ? `${from}さんが「${name}」で返信しました ↩️${body ? "：" + body : ""}`
      : kind === "react"
      // react: body に絵文字が入ってくる（🙏＝またこれ食べたい、それ以外＝ひとこと返事）
      ? ((emoji || body) === "🙏"
        ? `${from}さんが「${name}」をまた食べたいそうです 🙏`
        : `${from}さんが「${name}」に ${emoji || body} しました`)
      // post: クライアントが用意した文面（保存メッセージ）をそのまま使う
      : (body || `${from}さんが「${name}」を投稿しました 📔`);
    // 名指しされた人（@で呼ばれた・返信された）には、その旨がひと目で分かる文面にする
    const mentionMsg = `${from}さんがあなたを呼びました 📣${body ? "：" + body : ""}`;
    const payload = JSON.stringify({ title: "🍋 ゆずごはん日記", body: msg });
    const mentionPayload = JSON.stringify({ title: "🍋 ゆずごはん日記", body: mentionMsg });

    let sent = 0;
    for (const s of targets) {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          named.includes(s.who) && kind !== "post" ? mentionPayload : payload,
        );
        sent++;
      } catch (e) {
        // 410(Gone)/404 は購読切れ → DBから掃除する
        const code = (e as { statusCode?: number })?.statusCode;
        if (code === 410 || code === 404) {
          await sb.from("push_subs").delete().eq("endpoint", s.endpoint);
        } else {
          console.error("push failed:", code, (e as Error)?.message);
        }
      }
    }

    return json({ ok: true, sent });
  } catch (e) {
    return json({ error: (e as Error)?.message || String(e) }, 500);
  }
});
