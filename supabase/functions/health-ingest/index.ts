// Supabase Edge Function: health-ingest
// からだ帳（health.html）に、iPhone のショートカットからヘルスケアの値を入れる受け口。
//
// 本文（ショートカットの「辞書」をそのまま送る）:
//   { token, mode: "probe" | "save", metric, window | limit, dates, ends?, values }
//   dates / ends / values は配列でも、改行区切りの文字でも受ける（ショートカットはリストを改行でつなぐ）。
//   metric: hrv / rhr / exercise / weight / walk / sleep
// mode:
//   "probe" … 送信テスト版。**値は保存しない。** 件数と、数字を伏せた形だけを health_probe に残して返す
//   "save"  … 日ごとにまとめて health_daily に入れる（同じ日・同じ指標は上書き＝何度送っても同じ結果）
// 合い言葉は Supabase の secrets（HEALTH_INGEST_TOKEN）。**コードにもクエリにも書かない。**
// 出力: どの道でも { ok, msg }。ショートカットは msg だけを見せる。

import { toList, aggregate, aggregateSleep, probeInfo, METRICS, dailyRaw, median, sleepValueRatio } from "./pure.js";
import { createClient } from "jsr:@supabase/supabase-js@2";

function json(o: unknown, s = 200) {
  return new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });
}
const NAMES: Record<string, string> = {
  hrv: "心拍変動", rhr: "安静時心拍", exercise: "運動", weight: "体重", walk: "歩行速度", sleep: "睡眠",
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, msg: "POSTのみ対応" }, 405);
  try {
    const TOKEN = Deno.env.get("HEALTH_INGEST_TOKEN") || "";
    const body: any = await req.json().catch(() => ({}));
    if (!TOKEN || String(body?.token || "") !== TOKEN) return json({ ok: false, msg: "合い言葉が違います" }, 401);

    const metric = String(body?.metric || "");
    if (!(metric in METRICS) && metric !== "sleep") return json({ ok: false, msg: "知らない種類: " + metric.slice(0, 20) }, 400);
    const name = NAMES[metric];
    const mode = String(body?.mode || "probe");
    // window（過去◯日）で取ったときは、いちばん古い日が途中からなので必ず捨てる。
    // 捨て方は limit と同じ道を通す（limit=1 なら「件数が上限に達した＝最古は途中」と同じ扱いになる）
    const limit = Number(body?.window || 0) > 0 ? 1 : Number(body?.limit || 0);
    const dates = toList(body?.dates), ends = toList(body?.ends), values = toList(body?.values);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    if (mode === "probe") {
      const info: any = { ...probeInfo(metric, dates, ends, values), keys: Object.keys(body || {}).filter((k) => k !== "token"),
        raw_type: Array.isArray(body?.values) ? "array" : typeof body?.values, raw_len: String(body?.values ?? "").length };
      // 書き出しから入れた値と、日ごとに比べる（**値は残さず比だけ**）。単位の食い違いを見つけるため
      if (metric === "sleep") {
        info.value_per_minute = sleepValueRatio(dates, ends, values);
      } else {
        const mine = dailyRaw(metric, dates, values);
        const days = [...mine.keys()];
        if (days.length) {
          const { data } = await sb.from("health_daily").select("day,value").eq("metric", metric).eq("source", "export").in("day", days);
          const ratios = (data || []).map((r: any) => mine.get(r.day) / Number(r.value)).filter((x: number) => isFinite(x));
          info.vs_export = { days: ratios.length, median_ratio: median(ratios) };
        }
      }
      const { error } = await sb.from("health_probe").insert({ metric, info });
      if (error) return json({ ok: false, msg: name + "：記録できませんでした（" + error.message + "）" }, 500);
      const vs = info.vs_export?.median_ratio, vpm = info.value_per_minute?.median;
      const hint = vs != null ? ` 書き出し比 ${Math.round(vs * 100) / 100}` : vpm != null ? ` 値/分 ${Math.round(vpm * 100) / 100}` : "";
      return json({ ok: true, msg: `${name}：${dates.length}件 ${info.parsed ? "読めた" : "読めない"}${hint}` });
    }

    if (mode === "save") {
      const rows = metric === "sleep" ? aggregateSleep(dates, ends, values, limit) : aggregate(metric, dates, values, limit);
      if (!rows.length) return json({ ok: true, msg: `${name}：入れるものなし（${dates.length}件届いた）` });
      const up = rows.map((r) => ({ ...r, source: "shortcut", updated_at: new Date().toISOString() }));
      const { error } = await sb.from("health_daily").upsert(up, { onConflict: "day,metric" });
      if (error) return json({ ok: false, msg: name + "：保存できませんでした（" + error.message + "）" }, 500);
      const days = rows.map((r) => r.day).sort();
      return json({ ok: true, msg: `${name}：${rows.length}日（${days[0].slice(5)}〜${days[days.length - 1].slice(5)}）` });
    }
    return json({ ok: false, msg: "mode は probe か save です" }, 400);
  } catch (e) {
    return json({ ok: false, msg: "受け口で例外: " + String(e).slice(0, 120) }, 500);
  }
});
