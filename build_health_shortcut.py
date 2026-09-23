# -*- coding: utf-8 -*-
"""からだ帳（health.html）へ、iPhone のヘルスケアを送るショートカットを組み立てる。

使い方: python3 build_health_shortcut.py <出力先フォルダ>

2本作る。**上から順に実機で通す**:
  からだ帳 送信テスト.shortcut … 受け口は「形」だけを記録する（件数・数字を伏せた日付と値の形・睡眠の段階の文字）。
                                  **値は保存しない。** 書式が想定どおりかをここで確かめる
  からだ帳 送信.shortcut       … 日ごとにまとめて health_daily に入れる（何度押しても同じ結果）

組み方は公開ショートカット「Health Data Export」（heartbridge・iCloud 22bb56e73c354d9aa76a3678548dfe3a）の
実動の形をなぞる。**キーも値も推測しない**：
  ・検索（filter.health.quantity）＝「種類」だけで絞る。日付の条件は置かない（あなたのライブラリにも実例が無い）。
    新しい順（Latest First＝写真の検索3件で実例あり）に LIMIT 件だけ取り、日ごとのまとめは受け口でやる。
    LIMIT 件ちょうど届いたら、いちばん古い日は途中までかもしれないので受け口が捨てる。
  ・種類名は HealthKit の英語の表示名（Localizable-DataTypes.loctable で裏取り。例の "Heart Rate" と同じ出どころ）。
    心肺機能（VO₂ max）は名前が決めきれないので入れない（書き出しの取り込みで入る）。
  ・単位（WFHKSampleFilteringUnit）は置かない＝ヘルスケアの既定の単位（例では "count" だが種類ごとの正しい値の裏が無い）。
  ・開始日は「プロパティ → 日付を書式設定（Custom・en_US）」、値は「Value」の取り出し、どちらも例と同じ。
  ・送信は「辞書 → 値を設定 → URLの内容（本文＝ファイル＝辞書）」で例と同じ。
**焼く前に shortcut_check.py を必ず通す（この台本が --ref つきで自分で呼ぶ）。落ちたら焼かない。**
合い言葉はキーチェーン（health-ingest-token）から読む。**このファイルには書かない**（PUBLIC リポジトリ）。
焼いた .shortcut には合い言葉が入る。置き場は ~/つみき出力（非公開）だけ。
"""
import plistlib, uuid, sys, re, subprocess, pathlib, shutil, os

HERE = pathlib.Path(__file__).parent
SB_FUNC = "https://okbjqtdirrathscctyvx.supabase.co/functions/v1/health-ingest"
CACHE = pathlib.Path.home() / ".cache/tsumiki"
REF = CACHE / "ref_heartbridge.plist"
REF_URL = "https://www.icloud.com/shortcuts/api/records/22bb56e73c354d9aa76a3678548dfe3a"

# (受け口の名前, ヘルスケアの種類名, 取る件数, 終わりの時刻も要るか)。睡眠は最後（種類名が通らなかったときに前の5つは届いている）
METRICS = [
    ("hrv",      "Heart Rate Variability", 150, False),
    ("rhr",      "Resting Heart Rate",      20, False),
    ("exercise", "Exercise Minutes",       800, False),
    ("weight",   "Weight",                  10, False),
    ("walk",     "Walking Speed",          400, False),
    ("sleep",    "Sleep",                  400, True),
]

def U(): return str(uuid.uuid4()).upper()

def anon_key():
    s = (HERE / "health.html").read_text(encoding="utf-8")
    return re.search(r"var SB_ANON = '([^']+)'", s).group(1)

def token():
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "health-ingest-token", "-w"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("合い言葉がキーチェーン（health-ingest-token）にありません。")
    return r.stdout.strip()

def ensure_ref():
    """heartbridge の実動例（署名前の plist）を ~/.cache に取ってくる。照合の出どころ"""
    if REF.exists():
        return
    import json, urllib.request
    CACHE.mkdir(parents=True, exist_ok=True)
    out = subprocess.run(["curl", "-s", REF_URL], capture_output=True, text=True).stdout
    u = json.loads(out)["fields"]["shortcut"]["value"]["downloadURL"].replace("${f}", "x")
    subprocess.run(["curl", "-sL", u, "-o", str(REF)], check=True)
    os.chmod(REF, 0o600)

# ---- 値の入れ物（実動例に合わせる）------------------------------
def u16(s): return len(s.encode("utf-16-le")) // 2

def ts(parts):
    """WFTextTokenString。parts は文字列と (出力UUID, 出力名, [プロパティ名]) の並び"""
    if isinstance(parts, str): parts = [parts]
    s, att = "", {}
    for p in parts:
        if isinstance(p, str): s += p
        else:
            a = {"Type": "ActionOutput", "OutputUUID": p[0], "OutputName": p[1]}
            if len(p) > 2:
                a["Aggrandizements"] = [{"Type": "WFPropertyVariableAggrandizement", "PropertyName": p[2]}]
            att["{%d, 1}" % u16(s)] = a
            s += "￼"
    return {"Value": {"string": s, "attachmentsByRange": att}, "WFSerializationType": "WFTextTokenString"}

def att(uid, name):
    return {"Value": {"Type": "ActionOutput", "OutputUUID": uid, "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}

def fixed_dict(pairs):
    items = [{"WFItemType": 0,
              "WFKey": {"Value": {"string": k, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"},
              "WFValue": {"Value": {"string": v, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}}
             for k, v in pairs]
    return {"Value": {"WFDictionaryFieldValueItems": items}, "WFSerializationType": "WFDictionaryFieldValue"}

def type_filter(type_name):
    """heartbridge の例の「種類」の条件をそのまま（日付の条件は置かない）"""
    return {"Value": {"WFActionParameterFilterPrefix": 1,
                      "WFContentPredicateBoundedDate": False,
                      "WFActionParameterFilterTemplates": [{
                          "Bounded": True, "Operator": 4, "Removable": False, "Property": "Type",
                          "Values": {"Enumeration": {"Value": type_name,
                                                     "WFSerializationType": "WFStringSubstitutableState"}}}]},
            "WFSerializationType": "WFContentPredicateTableTemplate"}

# 出力名（例の英語名。解決は UUID で行われるので名前の食い違いは動作に影響しない）
O_SAMPLES, O_PROP, O_FMT, O_DICT, O_URL, O_DICV = "Health Samples", "Start Date", "Formatted Date", "Dictionary", "Contents of URL", "Dictionary Value"

def build(mode, tok, anon):
    acts = []
    def A(i, p, u=None):
        q = dict(p)
        if u: q["UUID"] = u
        acts.append({"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": q})

    def stamp(u_find, prop):
        """サンプルの日時（開始／終了）→ '2026-09-23 04:45:00+0900' の並び"""
        u_p, u_f = U(), U()
        A("is.workflow.actions.properties.health.quantity",
          {"WFInput": att(u_find, O_SAMPLES), "WFContentItemPropertyName": prop}, u_p)
        A("is.workflow.actions.format.date",
          {"WFDateFormatStyle": "Custom", "WFDateFormat": "yyyy-MM-dd HH:mm:ssZ", "WFLocale": "en_US",
           "WFTimeFormatStyle": "Medium", "WFISO8601IncludeTime": False,
           "WFDate": ts([(u_p, prop)])}, u_f)
        return u_f

    msgs = []
    for key, type_name, limit, need_end in METRICS:
        u_find = U()
        A("is.workflow.actions.filter.health.quantity", {
            "WFContentItemFilter": type_filter(type_name),
            "WFContentItemSortProperty": "Start Date",
            "WFContentItemSortOrder": "Latest First",
            "WFContentItemLimitEnabled": True,
            "WFContentItemLimitNumber": float(limit),
            "WFHKSampleFilteringFillMissing": False,
        }, u_find)
        u_start = stamp(u_find, "Start Date")
        u_end = stamp(u_find, "End Date") if need_end else None

        u_d0 = U()
        A("is.workflow.actions.dictionary", {"WFItems": fixed_dict(
            [("token", tok), ("mode", mode), ("metric", key), ("limit", str(limit))])}, u_d0)
        def setv(u_in, k, value, u_out):
            A("is.workflow.actions.setvalueforkey",
              {"WFDictionary": att(u_in, O_DICT), "WFDictionaryKey": k, "WFDictionaryValue": value}, u_out)
        u_d1, u_d2 = U(), U()
        setv(u_d0, "dates", ts([(u_start, O_FMT)]), u_d1)
        setv(u_d1, "values", ts([(u_find, O_SAMPLES, "Value")]), u_d2)
        u_last = u_d2
        if need_end:
            u_d3 = U()
            setv(u_d2, "ends", ts([(u_end, O_FMT)]), u_d3)
            u_last = u_d3

        u_res, u_msg = U(), U()
        A("is.workflow.actions.downloadurl", {
            "WFURL": SB_FUNC,
            "WFHTTPMethod": "POST",
            "WFHTTPBodyType": "File",
            "WFRequestVariable": att(u_last, O_DICT),
            "WFHTTPHeaders": fixed_dict([("Authorization", "Bearer " + anon)]),
            "ShowHeaders": True,
        }, u_res)
        A("is.workflow.actions.getvalueforkey",
          {"WFInput": att(u_res, O_URL), "WFDictionaryKey": "msg"}, u_msg)
        msgs.append(u_msg)

    parts = []
    for i, u in enumerate(msgs):
        if i: parts.append("\n")
        parts.append((u, O_DICV))
    A("is.workflow.actions.showresult", {"Text": ts(parts)})
    return acts

def wrap(acts):
    return {
        "WFWorkflowClientVersion": "2605",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59446},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowActions": acts,
    }

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip().split("\n")[0])
    out_dir = pathlib.Path(sys.argv[1]).expanduser()
    ensure_ref()
    tok, anon = token(), anon_key()
    work = CACHE / "health_shortcut"
    work.mkdir(parents=True, exist_ok=True)
    os.chmod(work, 0o700)
    for mode, name in (("probe", "からだ帳 送信テスト"), ("save", "からだ帳 送信")):
        wf = work / f"{name}.wflow"
        with open(wf, "wb") as f:
            plistlib.dump(wrap(build(mode, tok, anon)), f, fmt=plistlib.FMT_BINARY)
        os.chmod(wf, 0o600)
        chk = subprocess.run([sys.executable, str(HERE / "shortcut_check.py"), str(wf), "--ref", str(REF)],
                             capture_output=True, text=True)
        tail = "\n".join(chk.stdout.strip().split("\n")[-6:])
        print(f"── 照合 {name}\n{tail}")
        if chk.returncode != 0:
            sys.exit(f"照合に落ちたので焼きません（{name}）。全文: python3 shortcut_check.py '{wf}' --ref '{REF}'")
        signed = work / f"{name}.shortcut"
        r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(wf), "--output", str(signed)],
                           capture_output=True, text=True)
        if r.returncode != 0 or not signed.exists() or signed.stat().st_size == 0:
            sys.exit(f"署名できませんでした（{name}）: {r.stderr.strip()[:200]}")
        out_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(signed, out_dir / signed.name)
        print(f"  焼いた: {out_dir / signed.name}")

if __name__ == "__main__":
    main()
