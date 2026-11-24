# -*- coding: utf-8 -*-
"""Training board（jukou.html）から、ラーニングの時間をリマインダー「ラーニングリスト」へ入れるショートカットを組み立てる。

使い方: python3 build_learning_reminder_shortcut.py <出力先フォルダ> [--mac-test]

呼び出し（jukou.html 側）:
  shortcuts://run-shortcut?name=Learningを登録&input=text&text=<encodeURIComponent>
入力（1行＝1人・改行 \\n・区切りは全角の縦棒）:
  yyyy/MM/dd HH:mm｜名前        例 2026/11/24 14:30｜Taro Yamada
  ※ 日時は0埋め（14:05 の 0 も）。重複よけの照合は "yyyy/MM/dd HH:mm" の文字どうしで比べる。
  ※ 「｜」の無い行（空行など）は飛ばす。

1行ごとに:
  題名＝名前・通知（指定時刻）＝その日時 で「ラーニングリスト」に新規リマインダー。
  重複よけ：同じ題名で未完了の物を探し、その期限が同じ日時なら入れない（同じ入力を2回送っても増えない）。
最後に「N件入れました（同じ物があったので入れなかった M件）」を出す。

作るもの:
  Learningを登録.shortcut                           … 本番
  --mac-test のとき:
  _テストLearning.shortcut                         … 本番と同じ中身（名前だけ違う）。題名「_テスト架空〜」で試す
  _テストLearning片付け.shortcut                   … 題名に「_テスト架空」を含む物を消す（OS が題名つきで確認を出す）

リストの指定は「リマインド一括設定 1」（本人のライブラリ）の実例と同じ形
（WFCalendarDescriptor ＋ WFCalendarItemCalendar）。Identifier は Mac のリマインダーの
保存庫で読んだ ZIDENTIFIER（＝iCloud の識別子。iPhone でも同じ物）。
リストを作り直すと識別子が変わる → そのときは保存庫から読み直して LIST_ID を差し替える。

作法の正本は ~/.claude/projects/.../memory/apple-shortcut-plist-authoring.md。
部品の書き方は build_reminder_resched_shortcut.py と同じ。検査は shortcut_check.py。
"""
import plistlib, uuid, sys, subprocess, pathlib, tempfile, shutil

HERE = pathlib.Path(__file__).parent
# 名前に濁点・半濁点のある仮名を入れない：Mac で取り込むと名前が分解形（NFD）で保存され、
# shortcuts://run-shortcut?name=… の名前（NFC）と一致せず「見つかりませんでした」になる（2026-11-24 Mac 実測）
NAME = "Learningを登録"
LIST_TITLE = "ラーニングリスト"
LIST_ID = "F19AB806-B6BB-40F2-BF07-0A9B9ECC2BA7"   # 2026-11-24 Mac の保存庫で確認
SEP = "｜"
STAMP = "yyyy/MM/dd HH:mm"
L, R = "《", "》"                                  # 照合の両端（「Taro」が「Taro Yamada」に当たらないように）
TEST_MARK = "_テスト架空"

def U(): return str(uuid.uuid4()).upper()

def u16(s):
    return len(s.encode("utf-16-le")) // 2

def ts(parts):
    """WFTextTokenString。parts は 文字列 と (uuid, 出力名) と ("var", 変数名) と ("ri", "Repeat Item") の並び"""
    if isinstance(parts, str): parts = [parts]
    s, att = "", {}
    for p in parts:
        if isinstance(p, str): s += p
        else:
            if p[0] == "var":
                att["{%d, 1}" % u16(s)] = {"Type": "Variable", "VariableName": p[1]}
            else:
                att["{%d, 1}" % u16(s)] = {"Type": "ActionOutput", "OutputUUID": p[0], "OutputName": p[1]}
            s += "￼"
    return {"Value": {"string": s, "attachmentsByRange": att}, "WFSerializationType": "WFTextTokenString"}

def att(u, name):
    return {"Value": {"Type": "ActionOutput", "OutputUUID": u, "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}

def var(name):
    return {"Value": {"Type": "Variable", "VariableName": name}, "WFSerializationType": "WFTextTokenAttachment"}

EXT = {"Value": {"Type": "ExtensionInput"}, "WFSerializationType": "WFTextTokenAttachment"}   # ショートカットの入力
RI, RI2 = var("Repeat Item"), var("Repeat Item 2")
O_SPLIT, O_ITEM, O_TEXT, O_ADJ, O_FOUND, O_DET, O_FMT, O_CNT = (
    "テキストを分割", "リストからの項目", "テキスト", "調整後の日付", "リマインダー", "リマインダーの詳細", "フォーマット済みの日付", "数")

def build(kind):
    acts = []
    def A(i, p=None, u=None):
        q = dict(p or {})
        if u: q["UUID"] = u
        acts.append({"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": q})
        return u

    if kind == "clean":
        u_f = A("is.workflow.actions.filter.reminders", {"WFContentItemFilter": {"Value": {
            "WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
            "WFActionParameterFilterTemplates": [
                {"Property": "Title", "Operator": 99, "Values": {"Unit": 4, "String": TEST_MARK}, "Removable": True}]},
            "WFSerializationType": "WFContentPredicateTableTemplate"}, "WFContentItemLimitEnabled": False}, U())
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(u_f, O_FOUND)}, U())
        return acts

    # 照合用の控え（「《日時｜題名》」を足していく）。最初に空でない値で作っておく
    u_init = A("is.workflow.actions.gettext", {"WFTextActionText": ts("・")}, U())
    A("is.workflow.actions.setvariable", {"WFInput": att(u_init, O_TEXT), "WFVariableName": "既存"})

    u_lines = A("is.workflow.actions.text.split", {"text": EXT, "WFTextSeparator": "New Lines", "Show-text": True}, U())
    g = U()
    A("is.workflow.actions.repeat.each", {"WFInput": att(u_lines, O_SPLIT), "GroupingIdentifier": g, "WFControlFlowMode": 0})
    # 入れ子の後で Repeat Item の指す先がぶれないよう、最初に文字として取っておく
    u_line = A("is.workflow.actions.gettext", {"WFTextActionText": ts([("var", "Repeat Item")])}, U())
    gi = U()   # 「｜」がある行だけ
    A("is.workflow.actions.conditional", {"WFInput": {"Type": "Variable", "Variable": att(u_line, O_TEXT)},
        "WFCondition": 99, "WFConditionalActionString": ts(SEP), "WFControlFlowMode": 0, "GroupingIdentifier": gi})
    u_parts = A("is.workflow.actions.text.split", {"text": att(u_line, O_TEXT), "WFTextSeparator": "Custom",
                "WFTextCustomSeparator": SEP, "Show-text": True}, U())
    u_dt = A("is.workflow.actions.getitemfromlist", {"WFInput": att(u_parts, O_SPLIT), "WFItemSpecifier": "First Item"}, U())
    u_nm = A("is.workflow.actions.getitemfromlist", {"WFInput": att(u_parts, O_SPLIT), "WFItemSpecifier": "Last Item"}, U())
    u_when = A("is.workflow.actions.adjustdate", {"WFDate": ts([(u_dt, O_ITEM)]), "WFDuration": {
        "Value": {"Unit": "min", "Magnitude": "0"}, "WFSerializationType": "WFQuantityFieldValue"}}, U())
    # 同じ題名の未完了を探し、その期限を「《日時｜題名》」の形で控えに足す
    u_same = A("is.workflow.actions.filter.reminders", {"WFContentItemFilter": {"Value": {
        "WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
        "WFActionParameterFilterTemplates": [
            {"Property": "Title", "Operator": 4, "Values": {"Unit": 4, "String": ts([(u_nm, O_ITEM)])}, "Removable": True},
            {"Property": "Is Completed", "Operator": 4, "Values": {"Unit": 4, "Bool": False}, "Removable": True}]},
        "WFSerializationType": "WFContentPredicateTableTemplate"}, "WFContentItemLimitEnabled": False}, U())
    g2 = U()
    A("is.workflow.actions.repeat.each", {"WFInput": att(u_same, O_FOUND), "GroupingIdentifier": g2, "WFControlFlowMode": 0})
    u_due = A("is.workflow.actions.properties.reminders", {"WFInput": RI2, "WFContentItemPropertyName": "Due Date"}, U())
    u_df = A("is.workflow.actions.format.date", {"WFDate": ts([(u_due, O_DET)]), "WFDateFormatStyle": "Custom",
             "WFDateFormat": STAMP, "WFLocale": "en_US"}, U())
    u_k = A("is.workflow.actions.gettext", {"WFTextActionText": ts([L, (u_df, O_FMT), SEP, (u_nm, O_ITEM), R])}, U())
    A("is.workflow.actions.appendvariable", {"WFInput": att(u_k, O_TEXT), "WFVariableName": "既存"})
    A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g2, "WFControlFlowMode": 2}, U())
    # 入力の日時も同じ書式に揃えてから比べる（「2026/11/24 9:05」のような入力でも照合がずれない）
    u_inf = A("is.workflow.actions.format.date", {"WFDate": ts([(u_when, O_ADJ)]), "WFDateFormatStyle": "Custom",
              "WFDateFormat": STAMP, "WFLocale": "en_US"}, U())
    u_ex = A("is.workflow.actions.gettext", {"WFTextActionText": ts([("var", "既存")])}, U())
    gd = U()
    A("is.workflow.actions.conditional", {"WFInput": {"Type": "Variable", "Variable": att(u_ex, O_TEXT)},
        "WFCondition": 99, "WFConditionalActionString": ts([L, (u_inf, O_FMT), SEP, (u_nm, O_ITEM), R]),
        "WFControlFlowMode": 0, "GroupingIdentifier": gd})
    u_one = A("is.workflow.actions.gettext", {"WFTextActionText": ts("1")}, U())
    A("is.workflow.actions.appendvariable", {"WFInput": att(u_one, O_TEXT), "WFVariableName": "重複"})
    A("is.workflow.actions.conditional", {"WFControlFlowMode": 1, "GroupingIdentifier": gd})
    A("is.workflow.actions.addnewreminder", {
        "WFCalendarItemTitle": ts([(u_nm, O_ITEM)]),
        "WFCalendarDescriptor": {"Identifier": "<x-apple-reminderkit://REMCDList/%s>" % LIST_ID,
                                 "IsAllCalendar": False, "Title": LIST_TITLE},
        "WFCalendarItemCalendar": LIST_TITLE,
        "WFAlertEnabled": "Alert", "WFAlertCondition": "At Time", "WFAlertCustomTime": ts([(u_when, O_ADJ)]),
        "WFPriority": "None"}, U())
    u_one2 = A("is.workflow.actions.gettext", {"WFTextActionText": ts("1")}, U())
    A("is.workflow.actions.appendvariable", {"WFInput": att(u_one2, O_TEXT), "WFVariableName": "入れた"})
    # 同じ入力に同じ行が2つあっても2件目を入れない
    u_k2 = A("is.workflow.actions.gettext", {"WFTextActionText": ts([L, (u_inf, O_FMT), SEP, (u_nm, O_ITEM), R])}, U())
    A("is.workflow.actions.appendvariable", {"WFInput": att(u_k2, O_TEXT), "WFVariableName": "既存"})
    A("is.workflow.actions.conditional", {"WFControlFlowMode": 2, "GroupingIdentifier": gd}, U())
    A("is.workflow.actions.conditional", {"WFControlFlowMode": 2, "GroupingIdentifier": gi}, U())
    A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
    u_c1 = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": var("入れた")}, U())
    u_c2 = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": var("重複")}, U())
    A("is.workflow.actions.showresult", {"Text": ts([LIST_TITLE + " に ", (u_c1, O_CNT), "件入れました\n（同じ物があったので入れなかった ",
                                                     (u_c2, O_CNT), "件）"])})
    return acts

def wrap(acts):
    return {
        "WFWorkflowClientVersion": "2605",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowTypes": [],
        "WFWorkflowActions": acts,
    }

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    test = "--mac-test" in sys.argv
    if not args:
        sys.exit(__doc__.strip().split("\n")[2])
    out = pathlib.Path(args[0]); out.mkdir(parents=True, exist_ok=True)
    plan = (("main", "_テストLearning"), ("clean", "_テストLearning片付け")) if test else (("main", NAME),)
    mine = [NAME, "_テストLearning", "_テストLearning片付け"]
    tmp = pathlib.Path(tempfile.mkdtemp())
    def stop(msg):
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(msg)
    done = []
    for kind, name in plan:
        acts = build(kind)
        p, sp = tmp / (name + ".wflow"), tmp / (name + ".shortcut")
        plistlib.dump(wrap(acts), open(p, "wb"))
        print("―― " + name + " の検査 ――", flush=True)
        if subprocess.run([sys.executable, str(HERE / "shortcut_check.py"), str(p)]
                          + sum((["--self", m] for m in mine), [])).returncode != 0:
            if not test:
                stop("検査で止めました。焼いていません。")
            print("（Mac で試す版なので、このまま焼きます）")
        r = subprocess.run(["shortcuts", "sign", "-m", "anyone", "-i", str(p), "-o", str(sp)],
                           capture_output=True, text=True)
        if r.returncode != 0 or not sp.exists():
            stop("署名に失敗しました（" + (r.stderr or r.stdout).strip() + "）")
        done.append((p, sp, len(acts)))
    for p, sp, n in done:
        shutil.copy(sp, out / sp.name)
        shutil.copy(p, out / p.name)        # 署名前も残す（署名後は読めない）
        print(sp.stem, "→", n, "アクション・署名OK →", str(out / sp.name), flush=True)
    shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
