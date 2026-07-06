// Supabase Edge Function: extract-shift
// Apple Retail のシフト（My Calendar / Your Shift）スクショ画像を受け取り、
// ゾーンごとの「セッション」を構造化JSONで抽出して返す。
// LLM: Google Gemini Vision（無料枠 gemini-2.5-flash）。APIキーはSecret(GEMINI_API_KEY)。
//
// 入力: { imageBase64: string(データURLでもraw base64でも可), mimeType?: string }
// 出力: { room, shiftHours, items:[ {time,hours,zone,role,tag} | {break:true,time} ... ] }
//
// デプロイ: supabase MCP / ダッシュボードのどちらでも。Secretは generate-recap-email と共有。

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

const PROMPT = [
  "You are an OCR + structuring assistant. The image is a screenshot of an Apple Retail employee shift schedule (screen titled 'My Calendar' / 'Your Shift').",
  "Read every row precisely and return the shift as structured JSON. Output JSON ONLY — no prose, no markdown code fences.",
  "",
  "The screen structure:",
  "- The TOP row (e.g. '10:00–18:45 [8.75]') is the WHOLE-SHIFT summary — it is NOT a session. Use it only for shiftHours.",
  "- Each indented row below is a segment: 'START–END [HOURS]' then a second line like 'R710 • 6. People • Meeting'.",
  "  In that second line the parts are: ROOM (e.g. R710) • ZONE (e.g. '6. People' or '1. Product Zone') • ROLE (e.g. 'Meeting', 'Out of Store', 'Sales 1', 'Daily Download').",
  "- A coffee-cup icon row (e.g. '12:00–12:15 [0.25] Break') is a BREAK.",
  "- A small tag line under a segment (a tag/label icon with text such as 'Demo') is a TAG belonging to that segment.",
  "",
  "Rules:",
  "1. Parse HOURS from the bracket, e.g. [1.50] -> 1.5, [0.25] -> 0.25.",
  "2. SESSIONIZE: merge CONSECUTIVE segments that have the SAME zone AND SAME role AND SAME tag into one item. Sum their hours and span the time (start of first to end of last). Any break, or any change of zone/role/tag, ends the current session.",
  "3. Keep breaks as separate items: {\"break\":true,\"time\":\"HH:MM–HH:MM\"}.",
  "4. For a floor session output: {\"time\":\"HH:MM–HH:MM\",\"hours\":<number>,\"zone\":\"<zone>\",\"role\":\"<role>\",\"tag\":<string or null>}.",
  "5. Preserve zone strings exactly including their leading number, e.g. '6. People', '1. Product Zone'.",
  "6. Use an en dash '–' between times. Keep items in chronological order.",
  "",
  "Return exactly this shape:",
  "{\"room\":\"<room or empty>\",\"shiftHours\":<number>,\"items\":[ ... ]}",
].join("\n");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POSTのみ対応" }, 405);

  try {
    const body = await req.json();
    let imageBase64: string = body?.imageBase64 || "";
    let mimeType: string = body?.mimeType || "image/jpeg";
    if (!imageBase64) return json({ error: "imageBase64 が空です" }, 400);

    // データURL（data:image/png;base64,....）で来ても受け取れるように分解
    const m = /^data:([^;]+);base64,(.*)$/s.exec(imageBase64);
    if (m) { mimeType = m[1]; imageBase64 = m[2]; }

    const apiKey = Deno.env.get("GEMINI_API_KEY");
    if (!apiKey) return json({ error: "GEMINI_API_KEY が未設定です（SupabaseのSecretsに登録してください）" }, 500);

    const model = "gemini-2.5-flash";
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

    const payload = JSON.stringify({
      contents: [{
        parts: [
          { inline_data: { mime_type: mimeType, data: imageBase64 } },
          { text: PROMPT },
        ],
      }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 2048,
        thinkingConfig: { thinkingBudget: 0 },
        responseMimeType: "application/json",
      },
    });

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

    if (!text) return json({ error: "抽出結果が空でした", detail: j }, 502);

    // responseMimeType=json 指定でも、稀にコードフェンスが混じることがあるので剥がす
    const cleaned = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
    let parsed: any;
    try { parsed = JSON.parse(cleaned); }
    catch (_e) {
      const s = cleaned.indexOf("{"), e2 = cleaned.lastIndexOf("}");
      if (s >= 0 && e2 > s) { try { parsed = JSON.parse(cleaned.slice(s, e2 + 1)); } catch (_e2) { /* noop */ } }
    }
    if (!parsed || !Array.isArray(parsed.items)) {
      return json({ error: "抽出結果の解析に失敗しました", raw: text }, 502);
    }

    // 軽い正規化
    const items = parsed.items.map((it: any) => {
      if (it && it.break) return { break: true, time: String(it.time || "") };
      return {
        time: String(it?.time || ""),
        hours: Number(it?.hours) || 0,
        zone: String(it?.zone || ""),
        role: String(it?.role || ""),
        tag: it?.tag ? String(it.tag) : null,
      };
    });

    return json({
      room: String(parsed.room || ""),
      shiftHours: Number(parsed.shiftHours) || 0,
      items,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
