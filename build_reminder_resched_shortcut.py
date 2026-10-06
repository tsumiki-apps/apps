# -*- coding: utf-8 -*-
"""期限が過ぎたリマインダーを、まとめて別の時刻へ動かすショートカットを組み立てる（Apple Watch でも使う）。

使い方: python3 build_reminder_resched_shortcut.py <出力先フォルダ> [--mac-test]

作るもの（下ほど部品が増える。**上から順に実機で通す**）:
  期限切れを見る.shortcut       … 探して並べるだけ。**何も書き換えない**
  まとめてリスケ.shortcut       … 探す → 時刻を選ぶ（1時間後／今夜23時／翌朝8:30）→ 全部の期限をその時刻へ
  1件ずつリスケ.shortcut        … 期限切れから動かす物をいくつでも選び、1件ずつ日付と時刻のつまみで決める
  リスケを戻す.shortcut         … 直前の「まとめてリスケ／朝9時へ」で動かした物を元の期限へ戻す
                                  （動かすときに、同じ題名・元の期限の控えを完了済みで作っておき、それを見て戻す）
  朝9時へ.shortcut              … 探す → 全部の期限を次の朝9:00へ（選ばない。0〜9時に押せばその朝）
  タグ「固定」の物（毎日・毎週の決まった時刻の物）は動かさない。
  どれも最後に探し直して「残りの期限切れ N件」を出す。「今夜23時」は23時を過ぎて押すと明日の23時、「翌朝8:30」は0〜8:30 に押すとその朝。

--mac-test … Mac で `shortcuts run` して確かめる版（_テスト〜）を作る。**本物のリマインダーは触らない**:
  題名が「_テスト期限切れ」の物だけを探す。自分でその題名の物を2件（期限は昨日）作ってから探す。
  _テスト見る … 作って・探して・出すだけ／_テスト選ぶ … ＋時刻を選んで書き換える／_テスト書く … ＋朝9時へ
  _テスト片付け … 題名 _テスト期限切れ の物を全部消す（**試したら必ず最後にこれ**。消す前に OS が題名つきで確認を出す）
  **この版は検査の ✗ があっても焼く**（Mac で動かすこと自体が裏取り）。
  検査は自作の物（_テスト〜 とこの台本の本番名）を実例から外す。リマインダーの部品は shortcut_check.py の
  VERIFIED に Mac での実測を出どころとして書いてある（Watch・iPhone での実行は別に確かめる）。

時刻は文字で組む（「yyyy/MM/dd」＋「 09:00」→ 日付の調整 +0分 で日付に戻す）。
日付の調整の単位は実例のある 'min' だけを使う。
「もし」は置かない（Watch で止まった前例。0件のときは結果に0件と出るだけで、書き換えは空振りする）。

作法の正本は ~/.claude/projects/.../memory/apple-shortcut-plist-authoring.md。
"""
import plistlib, uuid, sys, subprocess, pathlib, tempfile, shutil

HERE = pathlib.Path(__file__).parent
TEST_TITLE = "_テスト期限切れ"
FIXED_TAG = "固定"
MARK = "リスケの控え（消さないでください）"   # 控えのリマインダーのメモ。元に戻すときはこれで探す
BACK = "↩ "                                  # 控えの題名の頭（本物の完了と見分ける）
STAMP = "yyyy/MM/dd HH:mm"
USED = "リスケの控え・使用済み"               # 次に動かしたとき、前回の控えをこれに書き換える（元に戻すの対象から外す）

def U(): return str(uuid.uuid4()).upper()

def u16(s):
    return len(s.encode("utf-16-le")) // 2

def ts(parts):
    """WFTextTokenString。parts は 文字列 と (uuid, 出力名) の並び"""
    if isinstance(parts, str): parts = [parts]
    s, att = "", {}
    for p in parts:
        if isinstance(p, str): s += p
        else:
            att["{%d, 1}" % u16(s)] = {"Type": "ActionOutput", "OutputUUID": p[0], "OutputName": p[1]}
            s += "￼"
    return {"Value": {"string": s, "attachmentsByRange": att},
            "WFSerializationType": "WFTextTokenString"}

def att(u, name):
    return {"Value": {"Type": "ActionOutput", "OutputUUID": u, "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}

# 出力名（loctable の Default Output Name）。解決は UUID で行われるので名前のずれは動作に響かない
O_DATE, O_ADJ, O_FMT, O_FOUND, O_MENU, O_CNT = "日付", "調整後の日付", "フォーマット済みの日付", "リマインダー", "メニューの結果", "数"
O_PICK, O_ASK = "選択した項目", "指定入力"
O_DET, O_NEWREM, O_REP, O_TEXT = "リマインダーの詳細", "新規リマインダー", "テキストを置き換え", "テキスト"

def fil(title_only, only_title=False, alarms=True, fixed=False):
    """未完了 かつ 期限が過去3650日以内（＝今より前。今日のこれからの時刻は入らない＝Mac で実測）かつ 通知あり。
    only_title=True は題名だけ（片付け用。完了済みも消す）。
    alarms=False は「通知なしの期限切れ」＝対象外にした物を数える用（黙って外さず、件数を見せる）。
    タグ「固定」の付いた物も外す（fixed=True でその件数を数える）"""
    t = [] if only_title else [
        {"Property": "Is Completed", "Operator": 4, "Values": {"Unit": 4, "Bool": False}, "Removable": True},
        {"Property": "Due Date", "Operator": 1001, "Values": {"Unit": 16, "Number": "3650"}, "Removable": True},
        # 時刻なし（終日）の物は「今日」でも期限切れに入ってしまう（2026-10-05 Mac で実測）。
        # 時刻つきの物には通知が付き、時刻なしの物には付かないので、通知ありだけにする
        {"Property": "Has Alarms", "Operator": 4, "Values": {"Unit": 4, "Bool": alarms}, "Removable": True},
        # タグ「固定」の物（毎日・毎週の決まった時刻の物）は動かさない。fixed=True は逆に固定だけを数える用。
        # ショートカットからは「繰り返し」が見えないので、本人がタグで印を付ける（2026-10-05）
        {"Property": "Tags", "Operator": 99 if fixed else 999, "Values": {"Unit": 4, "String": FIXED_TAG}, "Removable": True},
        # 控え（作ってから完了にする前に止まった物）は動かさない
        {"Property": "Notes", "Operator": 999, "Values": {"Unit": 4, "String": "リスケの控え"}, "Removable": True}]
    if title_only:
        t.insert(0, {"Property": "Title", "Operator": 4, "Values": {"Unit": 4, "String": TEST_TITLE}, "Removable": True})
    return {"Value": {"WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
                      "WFActionParameterFilterTemplates": t},
            "WFSerializationType": "WFContentPredicateTableTemplate"}

def build(kind, test=False):
    """kind: "look"（見るだけ）／"menu"（選んで書く）／"morning"（朝9時へ書く）／"undo"（直前の分を元に戻す）／"pick"（選んで1件ずつ時刻を決める）／"clean"（テストの片付け）"""
    acts = []
    def A(i, p=None, u=None):
        q = dict(p or {})
        if u: q["UUID"] = u
        acts.append({"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": q})
        return u

    def mins(src, n, u=None):
        """src（uuid,名前）または文字の部品 に n 分足す。+0 は「文字を日付に戻す」ため"""
        return A("is.workflow.actions.adjustdate",
                 {"WFDate": ts(src), "WFDuration": {"Value": {"Unit": "min", "Magnitude": str(n)},
                                                    "WFSerializationType": "WFQuantityFieldValue"}}, u or U())

    def day_at(src, hhmm):
        """src の日付の hh:mm"""
        u_f = A("is.workflow.actions.format.date",
                {"WFDate": ts([src]), "WFDateFormatStyle": "Custom", "WFDateFormat": "yyyy/MM/dd",
                 "WFLocale": "en_US"}, U())
        return mins([(u_f, O_FMT), " " + hhmm], 0)

    def next_at(h, m=0):
        """これから来る最初の h:m。「もし」を使わず、(今 + (24時間 − h:m)) の日付の h:m にする。
        例 23:00: 22:59 → 今日23時／23:01 → 明日23時。8:30: 1:00 → 今朝8:30／9:00 → 明日8:30"""
        u = A("is.workflow.actions.date", {}, U())       # 押した瞬間の「今」（メニューで迷った分を含めない）
        return day_at((mins([(u, O_DATE)], 24 * 60 - (h * 60 + m)), O_ADJ), "%02d:%02d" % (h, m))

    def skipped_note():
        """時刻なし・通知なしの期限切れは動かさない。その件数を見せる"""
        u_s = A("is.workflow.actions.filter.reminders",
                {"WFContentItemFilter": fil(test, alarms=False), "WFContentItemLimitEnabled": False}, U())
        u_sc = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_s, O_FOUND)}, U())
        u_x = A("is.workflow.actions.filter.reminders",
                {"WFContentItemFilter": fil(test, fixed=True), "WFContentItemLimitEnabled": False}, U())
        u_xc = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_x, O_FOUND)}, U())
        return ["\n（#固定で対象外 ", (u_xc, O_CNT), "件・時刻なしで対象外 ", (u_sc, O_CNT), "件）"]

    RI = {"Value": {"Type": "Variable", "VariableName": "Repeat Item"}, "WFSerializationType": "WFTextTokenAttachment"}
    RI2 = {"Value": {"Type": "Variable", "VariableName": "Repeat Item 2"}, "WFSerializationType": "WFTextTokenAttachment"}

    def detail(src, prop):
        """リマインダーの詳細（題名・期限）を取る"""
        return A("is.workflow.actions.properties.reminders", {"WFInput": src, "WFContentItemPropertyName": prop}, U())

    def controls(mark=MARK):
        """控え（完了済み・メモに mark）を探す。テスト版は題名でも絞る。
        mark="リスケの控え" なら使用済みも含めて全部"""
        t = [{"Property": "Is Completed", "Operator": 4, "Values": {"Unit": 4, "Bool": True}, "Removable": True},
             {"Property": "Notes", "Operator": 99, "Values": {"Unit": 4, "String": mark}, "Removable": True}]
        if test:
            t.insert(0, {"Property": "Title", "Operator": 4, "Values": {"Unit": 4, "String": BACK + TEST_TITLE}, "Removable": True})
        return A("is.workflow.actions.filter.reminders", {"WFContentItemFilter": {"Value": {
            "WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
            "WFActionParameterFilterTemplates": t}, "WFSerializationType": "WFContentPredicateTableTemplate"},
            "WFContentItemLimitEnabled": False}, U())

    if kind == "undo":
        # 先に件数を見せて「戻す／やめる」を選ばせる（書き換えてから確認、にしない）
        u_c = controls()
        u_cc = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_c, O_FOUND)}, U())
        gm, items = U(), ["戻す", "やめる"]
        A("is.workflow.actions.choosefrommenu", {"WFMenuPrompt": ts(["直前に動かした ", (u_cc, O_CNT), "件を元に戻す？"]),
                                                 "WFControlFlowMode": 0, "WFMenuItems": items, "GroupingIdentifier": gm})
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[0], "GroupingIdentifier": gm, "WFControlFlowMode": 1})
        g = U()
        A("is.workflow.actions.repeat.each", {"WFInput": att(u_c, O_FOUND), "GroupingIdentifier": g, "WFControlFlowMode": 0})
        # 控え：題名「↩ 元の題名」・期限＝元の期限・メモ＝MARK＋動かした先の時刻
        u_ct, u_d, u_n = detail(RI, "Title"), detail(RI, "Due Date"), detail(RI, "Notes")
        u_t = A("is.workflow.actions.text.replace", {"WFInput": ts([(u_ct, O_DET)]), "WFReplaceTextFind": "^" + BACK,
                "WFReplaceTextReplace": "", "WFReplaceTextRegularExpression": True}, U())
        u_to = A("is.workflow.actions.text.replace", {"WFInput": ts([(u_n, O_DET)]), "WFReplaceTextFind": "^[^）]*）",
                 "WFReplaceTextReplace": "", "WFReplaceTextRegularExpression": True}, U())
        # 同じ題名の未完了のうち、**今の期限が「動かした先の時刻」と同じ物だけ**を戻す（題名だけで選ぶと別の物を壊す）
        u_m = A("is.workflow.actions.filter.reminders", {
            "WFContentItemFilter": {"Value": {"WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
                "WFActionParameterFilterTemplates": [
                    {"Property": "Title", "Operator": 4, "Values": {"Unit": 4, "String": ts([(u_t, O_REP)])}, "Removable": True},
                    {"Property": "Is Completed", "Operator": 4, "Values": {"Unit": 4, "Bool": False}, "Removable": True}]},
                "WFSerializationType": "WFContentPredicateTableTemplate"},
            "WFContentItemLimitEnabled": False}, U())
        g2 = U()
        A("is.workflow.actions.repeat.each", {"WFInput": att(u_m, O_FOUND), "GroupingIdentifier": g2, "WFControlFlowMode": 0})
        u_cd = detail(RI2, "Due Date")
        u_cf = A("is.workflow.actions.format.date", {"WFDate": ts([(u_cd, O_DET)]), "WFDateFormatStyle": "Custom",
                 "WFDateFormat": STAMP, "WFLocale": "en_US"}, U())
        gi = U()
        A("is.workflow.actions.conditional", {"WFInput": {"Type": "Variable", "Variable": att(u_cf, O_FMT)},
            "WFCondition": 4, "WFConditionalActionString": ts([(u_to, O_REP)]), "WFControlFlowMode": 0, "GroupingIdentifier": gi})
        A("is.workflow.actions.setters.reminders", {"WFInput": RI2, "Mode": "Set",
            "WFContentItemPropertyName": "Due Date", "WFReminderContentItemDueDate": ts([(u_d, O_DET)])}, U())
        u_one = A("is.workflow.actions.gettext", {"WFTextActionText": ts("1")}, U())
        A("is.workflow.actions.appendvariable", {"WFInput": att(u_one, O_TEXT), "WFVariableName": "戻した"})
        A("is.workflow.actions.conditional", {"WFControlFlowMode": 2, "GroupingIdentifier": gi}, U())
        A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g2, "WFControlFlowMode": 2}, U())
        A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
        # 控えは消す（使用済みも一緒に。削除の確認が出るのはここだけ）
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(controls("リスケの控え"), O_FOUND)}, U())
        u_done = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": {"Value": {"VariableName": "戻した", "Type": "Variable"},
                   "WFSerializationType": "WFTextTokenAttachment"}}, U())
        A("is.workflow.actions.showresult", {"Text": ts([(u_done, O_CNT), "件を元の時刻に戻しました"])})
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[1], "GroupingIdentifier": gm, "WFControlFlowMode": 1})
        A("is.workflow.actions.choosefrommenu", {"GroupingIdentifier": gm, "WFControlFlowMode": 2}, U())
        return acts

    if kind == "clean":   # 題名 _テスト期限切れ の物を消す（OS が件数と題名つきで削除の確認を出す）
        u_f = A("is.workflow.actions.filter.reminders",
                {"WFContentItemFilter": fil(True, only_title=True), "WFContentItemLimitEnabled": False}, U())
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(u_f, O_FOUND)}, U())
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(controls("リスケの控え"), O_FOUND)}, U())   # テストの控えも
        return acts

    if test:
        # 架空の2件（期限＝昨日 10:00）。本物は題名で外れる
        u_now = A("is.workflow.actions.date", {}, U())
        u_y10 = day_at((mins([(u_now, O_DATE)], -1440), O_ADJ), "10:00")
        for _ in range(2):
            A("is.workflow.actions.addnewreminder", {
                "WFCalendarItemTitle": ts(TEST_TITLE), "WFAlertEnabled": "Alert",
                "WFAlertCondition": "At Time", "WFAlertCustomTime": ts([(u_y10, O_ADJ)]),
                "WFPriority": "None"}, U())

    u_found = A("is.workflow.actions.filter.reminders",
                {"WFContentItemFilter": fil(test), "WFContentItemLimitEnabled": False}, U())
    u_cnt = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_found, O_FOUND)}, U())

    if kind == "look":
        A("is.workflow.actions.showresult", {"Text": ts(["期限切れ ", (u_cnt, O_CNT), "件\n", (u_found, O_FOUND)]
                                                         + skipped_note())})
        return acts

    new = None
    if kind == "menu":
        g, items = U(), ["1時間後", "今夜23時", "翌朝8:30"]   # 本人の希望（2026-10-06）
        A("is.workflow.actions.choosefrommenu", {"WFMenuPrompt": "いつに動かす？", "WFControlFlowMode": 0,
                                                 "WFMenuItems": items, "GroupingIdentifier": g})
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[0], "GroupingIdentifier": g, "WFControlFlowMode": 1})
        u = A("is.workflow.actions.date", {}, U())
        mins([(u, O_DATE)], 60)
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[1], "GroupingIdentifier": g, "WFControlFlowMode": 1})
        next_at(23)
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[2], "GroupingIdentifier": g, "WFControlFlowMode": 1})
        next_at(8, 30)
        u_new = A("is.workflow.actions.choosefrommenu", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
        new = (u_new, O_MENU)
    elif kind == "morning":
        new = (next_at(9), O_ADJ)

    def retire():
        """前回の控えは「使用済み」にする（元に戻せるのは直前の1回だけ）。
        消すと毎回「削除しますか」の確認が出て紛らわしいので、消すのは「リスケを戻す」のときだけ"""
        g0 = U()
        A("is.workflow.actions.repeat.each", {"WFInput": att(controls(), O_FOUND), "GroupingIdentifier": g0,
                                              "WFControlFlowMode": 0})
        A("is.workflow.actions.setters.reminders", {"WFInput": RI, "Mode": "Set",
            "WFContentItemPropertyName": "Notes", "WFReminderContentItemNotes": ts(USED)}, U())
        A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g0, "WFControlFlowMode": 2}, U())

    def move_one(new):
        """繰り返しの中の1件（Repeat Item）を new へ動かす。先に控え（↩ 題名・元の期限・メモに動かした先の時刻）を作る"""
        u_stamp = A("is.workflow.actions.format.date", {"WFDate": ts([new]), "WFDateFormatStyle": "Custom",
                    "WFDateFormat": STAMP, "WFLocale": "en_US"}, U())
        u_t, u_d = detail(RI, "Title"), detail(RI, "Due Date")
        u_k = A("is.workflow.actions.addnewreminder", {
            "WFCalendarItemTitle": ts([BACK, (u_t, O_DET)]), "WFCalendarItemNotes": ts([MARK, (u_stamp, O_FMT)]),
            "WFAlertEnabled": "Alert", "WFAlertCondition": "At Time", "WFAlertCustomTime": ts([(u_d, O_DET)]),
            "WFPriority": "None"}, U())
        A("is.workflow.actions.setters.reminders", {"WFInput": att(u_k, O_NEWREM), "Mode": "Set",
            "WFContentItemPropertyName": "Is Completed", "WFReminderContentItemIsCompleted": True}, U())
        # 「リマインダーを編集」は1件ずつしか受け取らない（複数を渡すと「項目を選択」で止まる＝2026-10-05 Mac で実測）
        A("is.workflow.actions.setters.reminders", {"WFInput": RI, "Mode": "Set",
            "WFContentItemPropertyName": "Due Date", "WFReminderContentItemDueDate": ts([new])}, U())

    def left_note():
        """書き換えたあとにもう一度探す。「残り0件」なら全部動いている（最初に数えた件数だけを信じない）"""
        u_left = A("is.workflow.actions.filter.reminders",
                   {"WFContentItemFilter": fil(test), "WFContentItemLimitEnabled": False}, U())
        u_lc = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_left, O_FOUND)}, U())
        return ["\n残りの期限切れ ", (u_lc, O_CNT), "件"]

    retire()
    g = U()
    if kind == "pick":
        # 選んだ物を1件ずつ、日付と時刻のつまみで決める（初めの値は今から1時間後）
        u_ch = A("is.workflow.actions.choosefromlist", {"WFInput": att(u_found, O_FOUND),
                 "WFChooseFromListActionPrompt": "動かす物を選ぶ", "WFChooseFromListActionSelectMultiple": True}, U())
        u_chc = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u_ch, O_PICK)}, U())
        A("is.workflow.actions.repeat.each", {"WFInput": att(u_ch, O_PICK), "GroupingIdentifier": g, "WFControlFlowMode": 0})
        u_t0 = detail(RI, "Title")
        u_n = A("is.workflow.actions.date", {}, U())
        u_def = mins([(u_n, O_DATE)], 60)
        u_ask = A("is.workflow.actions.ask", {"WFAskActionPrompt": ts([(u_t0, O_DET), " → いつにする？"]),
                  "WFInputType": "Date and Time", "WFAskActionDefaultAnswerDateAndTime": ts([(u_def, O_ADJ)])}, U())
        move_one((u_ask, O_ASK))
        A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
        A("is.workflow.actions.showresult", {"Text": ts([(u_chc, O_CNT), "件を動かしました"] + left_note() + skipped_note())})
        return acts

    A("is.workflow.actions.repeat.each", {"WFInput": att(u_found, O_FOUND), "GroupingIdentifier": g,
                                          "WFControlFlowMode": 0})
    move_one(new)
    A("is.workflow.actions.repeat.each", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
    u_fmt = A("is.workflow.actions.format.date",
              {"WFDate": ts([new]), "WFDateFormatStyle": "Custom", "WFDateFormat": "M/d HH:mm",
               "WFLocale": "en_US"}, U())
    A("is.workflow.actions.showresult", {"Text": ts([(u_cnt, O_CNT), "件を ", (u_fmt, O_FMT), " へ"]
                                                    + left_note() + skipped_note())})
    return acts

def wrap(acts, watch=True):
    return {
        "WFWorkflowClientVersion": "2605",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        # ⚠️ 空 [] は「どこにも出さない」。Watch に出すには "Watch" が要る（build_okidoki_watch.py・2026-09-22 実機）
        "WFWorkflowTypes": ["Watch"] if watch else [],   # テスト版は Watch に出さない（押すと架空の物が増える）
        "WFWorkflowActions": acts,
    }

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    test = "--mac-test" in sys.argv
    if not args:
        sys.exit(__doc__.strip().split("\n")[2])
    out = pathlib.Path(args[0]); out.mkdir(parents=True, exist_ok=True)
    plan = ((("look", "_テスト見る"), ("menu", "_テスト選ぶ"), ("morning", "_テスト書く"), ("undo", "_テスト戻す"), ("pick", "_テスト1件ずつ"),
             ("clean", "_テスト片付け"))
            if test else (("look", "期限切れを見る"), ("menu", "まとめてリスケ"), ("morning", "朝9時へ"), ("undo", "リスケを戻す"), ("pick", "1件ずつリスケ")))
    mine = [n for _, n in plan] + ["期限切れを見る", "まとめてリスケ", "朝9時へ", "明日9時へ", "元に戻す", "リスケを戻す", "1件ずつリスケ"]
    tmp = pathlib.Path(tempfile.mkdtemp())
    def stop(msg):
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(msg)
    done = []
    for kind, name in plan:
        acts = build(kind, test)
        p, sp = tmp / (name + ".wflow"), tmp / (name + ".shortcut")
        plistlib.dump(wrap(acts, watch=not test), open(p, "wb"))
        print("―― " + name + " の検査 ――", flush=True)
        if subprocess.run([sys.executable, str(HERE / "shortcut_check.py"), str(p)]
                          + sum((["--self", m] for m in mine), [])).returncode != 0:
            if not test:
                stop("検査で止めました。焼いていません。")
            print("（Mac で試す版なので、このまま焼きます）")
        r = subprocess.run(["shortcuts", "sign", "-m", "anyone", "-i", str(p), "-o", str(sp)],
                           capture_output=True, text=True)
        if r.returncode != 0 or not sp.exists():
            stop("署名に失敗しました（" + (r.stderr or r.stdout).strip() + "）。1本も写していません")
        done.append((p, sp, len(acts)))
    # 全部焼けてから写す（途中で止まって一式が半端に残らないように）
    for p, sp, n in done:
        shutil.copy(sp, out / sp.name)
        if test:
            shutil.copy(p, out / p.name)        # 署名前を残す（署名後は読めない）。本番の置き場には出さない
        print(sp.stem, "→", n, "アクション・署名OK →", str(out / sp.name), flush=True)
    shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
