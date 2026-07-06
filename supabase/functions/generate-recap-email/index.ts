// Supabase Edge Function: generate-recap-email
// Recap（週次リキャップ）の数値から、Leaders宛て送信メールの下書きをAIで生成する。
// LLM: Google Gemini（無料枠）。APIキーはこの関数のSecret(GEMINI_API_KEY)に置き、クライアントには出さない。
//
// デプロイ: Supabaseダッシュボード → Edge Functions → 新規作成「generate-recap-email」にこのコードを貼り付け。
// Secret: Project Settings → Edge Functions → Secrets で GEMINI_API_KEY を登録。

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
    const body = await req.json();
    const data = body?.data || {};
    const lang = body?.lang === "en" ? "en" : "ja";

    const apiKey = Deno.env.get("GEMINI_API_KEY");
    if (!apiKey) return json({ error: "GEMINI_API_KEY が未設定です（SupabaseのSecretsに登録してください）" }, 500);

    const prompt = buildPrompt(data, lang);

    // モデルは無料枠のある gemini-2.5-flash を使用。429や404が出る場合は gemini-flash-latest 等に変更。
    const model = "gemini-2.5-flash";
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

    const payload = JSON.stringify({
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.7,
        maxOutputTokens: 1024,
        // 2.5系の思考トークンを無効化（本文に予算を回し、高速・低コスト化）
        thinkingConfig: { thinkingBudget: 0 },
      },
    });

    // 503(混雑)/429(レート)は一時的なことが多いので、短い待機で最大3回リトライ
    let r: Response | null = null;
    let j: any = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      r = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: payload,
      });
      j = await r.json();
      if (r.ok) break;
      const code = r.status;
      if ((code === 503 || code === 429) && attempt < 2) {
        await new Promise((res) => setTimeout(res, 1200 * (attempt + 1)));
        continue;
      }
      break;
    }
    if (!r || !r.ok) return json({ error: "Gemini APIエラー", detail: j }, 502);

    const text = (j?.candidates?.[0]?.content?.parts || [])
      .map((p: { text?: string }) => p.text || "")
      .join("")
      .trim();

    if (!text) return json({ error: "生成結果が空でした", detail: j }, 502);
    return json({ text });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

// ---- データ → プロンプト ----
// メールは個人のNPS/KPI数値の報告ではなく、チームでの取り組み（Personal Action）と
// 協働・進捗を共有するもの。送られてくる data は actions[] が中心。
function buildPrompt(d: any, lang: "ja" | "en"): string {
  const facts = factLines(d, lang);

  if (lang === "en") {
    return [
      "You are a retail team member writing a short weekly Recap email to your leader/manager.",
      "This email shares the TEAM / collaborative initiatives you worked on this week — NOT personal NPS or KPI scores.",
      "Write a professional but warm email in natural English based ONLY on the data below.",
      "",
      "Guidelines:",
      "- Output ONLY the email: first line is `Subject: ...`, then a blank line, then the body.",
      "- Greet the manager by name if provided.",
      "- Center the email on the actions/initiatives: for each, describe what was done, who collaborated, and what progress or impact came of it — in flowing sentences, not a list.",
      "- Lead with the initiatives that moved forward. If something is still in progress, note a brief, concrete focus for next week.",
      "- Do NOT report or invent metric numbers (no NPS/KPI figures); keep it about the team's actions and growth.",
      "- Do NOT confuse the roles: the sender's present role is the `Current position`; the `Goal` is a role they are still working toward. Refer to the sender as their current position and never write the goal role as if it were their current title.",
      "- If a goal is provided, tie the closing to growing toward it (not to a role already held).",
      "- Keep it concise (about 150-220 words). Sign off with the sender's first name.",
      "- Do not use markdown bullets or asterisks.",
      "",
      "DATA:",
      facts,
    ].join("\n");
  }

  return [
    "あなたはApple Retailのチームメンバーで、上長(Leader)宛てに週次Recapの共有メールを書きます。",
    "このメールは個人のNPSやKPIの数字の報告ではなく、今週チームで取り組んだアクション（協働・進捗）を共有するものです。",
    "以下のデータ「だけ」を根拠に、丁寧だが堅すぎない自然な日本語のビジネスメールを書いてください。",
    "",
    "ルール:",
    "- 出力はメール本文のみ。1行目は『件名: ...』、次に空行、その後に本文。",
    "- 宛名（上長名）があれば冒頭に入れる。",
    "- アクション（取り組み）を中心に書く。各アクションについて『何をしたか・誰と協働したか・どんな進捗や手応えがあったか』を、箇条書きにせず自然な文章でまとめる。",
    "- まず前進した取り組みに触れる。まだ途中のものがあれば、来週の具体的なフォーカスを短く添える。",
    "- NPSやKPIなどの数値は報告しない（創作もしない）。あくまでチームの取り組みと成長の話にする。",
    "- 役職を混同しないこと。送信者の今の役職は『現在のポジション』であり、『目標』はこれから目指す役職。送信者を現在のポジションとして扱い、目標の役職を今の肩書きのように書かない。",
    "- 目標があれば、締めで『その目標に向けて成長していきたい』という方向で自然に結びつける（すでに就いている役職のようには書かない）。",
    "- 180〜320字程度で簡潔に。最後は送信者の名前で締める。",
    "- 箇条書き記号(*や•)やMarkdownは使わない。",
    "",
    "データ:",
    facts,
  ].join("\n");
}

function factLines(d: any, lang: "ja" | "en"): string {
  const ja = lang === "ja";
  const L: string[] = [];
  const period = `FY${d.fy || "-"} Q${d.q || "-"} Week${d.week || "-"}`;
  L.push((ja ? "送信者: " : "Sender: ") + (d.name || "-"));
  if (d.cm) L.push((ja ? "宛先(上長): " : "Manager: ") + d.cm);
  L.push((ja ? "期間: " : "Period: ") + period);
  if (d.myPosition) L.push((ja ? "現在のポジション（今の役職）: " : "Current position (present role): ") + d.myPosition);
  if (d.myGoal) L.push((ja ? "目標（将来目指す役職）: " : "Goal (role aimed for in the future): ") + d.myGoal);
  L.push("");

  if (Array.isArray(d.actions) && d.actions.length) {
    L.push(ja ? "今週のチーム/協働アクション:" : "Team / collaborative actions this week:");
    d.actions.forEach((a: any, i: number) => {
      const title = (a.name || "").trim() || (ja ? "（無題のアクション）" : "(untitled action)");
      L.push(`${i + 1}. ${title}`);
      if (Array.isArray(a.collaborators) && a.collaborators.length) {
        L.push(`   ${ja ? "協働メンバー: " : "Collaborators: "}${a.collaborators.join(", ")}`);
      }
      const prog = ja
        ? ((a.ja || "").trim() || (a.en || "").trim())
        : ((a.en || "").trim() || (a.ja || "").trim());
      if (prog) L.push(`   ${ja ? "進捗: " : "Progress: "}${prog}`);
    });
  } else {
    L.push(ja ? "（今週のアクションは未登録）" : "(no actions recorded this week)");
  }
  return L.join("\n");
}
