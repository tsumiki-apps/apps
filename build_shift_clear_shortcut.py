# -*- coding: utf-8 -*-
"""「シフトをリマインダーに」で入れたシフトのリマインダーだけを、まとめて消すショートカットを組み立てる。
シフト表が組み直されたとき、古いシフトを消してから入れ直すために使う。

使い方: python3 build_shift_clear_shortcut.py <出力先フォルダ> [--mac-test]

作るもの:
  シフトを全部消す.shortcut … 題名に「•」がある物（＝シフト。題名が「Product Zone • Sales 1」の形）と、
                              題名がちょうど「Break」の物（休憩。画面の行がそのまま題名になる）を探し、
                              件数を見せて「まだのシフトだけ／済んだ分も全部／やめる」を選ぶ → 消す → 探し直して残りを出す。
                              消す直前に OS が題名つきで「削除しますか」を出す（ここでも止められる）。
  シフトを見る.shortcut     … 探して並べるだけ。**何も消さない**（消す前に、シフト以外が混ざっていないかを見る用）

シフトの見分け方は build_reminder_resched_shortcut.py の SHIFT_MARK と同じ（題名に「•」）。
Break は「等しい」で探す（「含む」は Breakfast なども拾う。題名の「含む」は大文字小文字を区別する＝2026-10-11 Mac 実測：
本物で Break 28件・break 0件）。シフトと Break は1つの変数に足してから1回で消す（OS の確認が1回で済む）。

--mac-test … Mac で `shortcuts run` して確かめる版（_テスト〜）。**本物のリマインダーは触らない**:
  題名が「_テスト消す」で始まる物だけを相手にする（--mac-test-empty は架空の物を作らない＝0件のときを試す）。自分で架空のシフト2件（未完了1・完了1）・Break 2件（同）と、
  囮2件（「•」の無い物・Breakfast）を作ってから消す。囮は残るはず。
  _テスト消す見る … 作って並べるだけ／_テスト消す … 作って選んで消す／_テスト消す片付け … _テスト消す〜 を全部消す
"""
import plistlib, sys, subprocess, pathlib, tempfile, shutil
from build_reminder_resched_shortcut import U, ts, att, wrap, SHIFT_MARK, O_FOUND, O_CNT, O_DATE, O_NEWREM

HERE = pathlib.Path(__file__).parent
TEST = "_テスト消す"
BREAK = "Break"
VAR = "消す物"

def cond(prop, op, **v):
    return {"Property": prop, "Operator": op, "Values": {"Unit": 4, **v}, "Removable": True}

def build(kind, test=False, empty=False):
    """kind: "look"（見るだけ）／"clear"（選んで消す）／"clean"（テストの片付け）"""
    acts = []
    def A(i, p=None, u=None):
        q = dict(p or {})
        if u: q["UUID"] = u
        acts.append({"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": q})
        return u

    def find(done=None, shift=True, brk=False):
        """シフト（題名に•）／brk=True は Break（題名が等しい）を探す。done=False は未完了だけ。
        テスト版は題名の頭 _テスト消す でも絞る（Break は題名 _テスト消すBreak と等しい物）"""
        if brk:
            t = [cond("Title", 4, String=(TEST if test else "") + BREAK)]
        else:
            t = [cond("Title", 99, String=SHIFT_MARK)] if shift else []
            if test:
                t.insert(0, cond("Title", 99, String=TEST))
        if done is not None:
            t.append(cond("Is Completed", 4, Bool=done))
        # 「シフトをリマインダーに」で入れた物は全部、時刻の通知つき。メモから貼った「•」の箇条書きなど、
        # 通知の無い物を巻き込まない（2026-10-11 反証役 W2・本物の128件は1件も外れない）
        t.append(cond("Has Alarms", 4, Bool=True))
        if not any(c["Property"] == "Title" for c in t):
            raise SystemExit("題名の条件が無い＝全部のリマインダーを探す形になる。焼かずに止めました")
        return A("is.workflow.actions.filter.reminders", {"WFContentItemFilter": {"Value": {
            "WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
            "WFActionParameterFilterTemplates": t}, "WFSerializationType": "WFContentPredicateTableTemplate"},
            "WFContentItemLimitEnabled": False}, U())

    def count(u):
        return A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u, O_FOUND)}, U())

    if kind == "clean":
        assert test, "片付けは試験版だけ"
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(find(shift=False), O_FOUND)}, U())
        return acts

    if test and not empty:
        # 架空のシフト2件（明日 10:00・1件は完了にする）と、• の無い囮1件
        u_now = A("is.workflow.actions.date", {}, U())
        u_t = A("is.workflow.actions.adjustdate", {"WFDate": ts([(u_now, O_DATE)]), "WFDuration": {
            "Value": {"Unit": "min", "Magnitude": "1440"}, "WFSerializationType": "WFQuantityFieldValue"}}, U())
        made = []
        for title in (TEST + " Zone • Sales 1", TEST + " Zone • Sales 2", TEST + BREAK, TEST + BREAK,
                      TEST + " 囮", TEST + BREAK + "fast"):
            made.append(A("is.workflow.actions.addnewreminder", {
                "WFCalendarItemTitle": ts(title), "WFAlertEnabled": "Alert", "WFAlertCondition": "At Time",
                "WFAlertCustomTime": ts([(u_t, "調整後の日付")]), "WFPriority": "None"}, U()))
        for i in (1, 3):
            A("is.workflow.actions.setters.reminders", {"WFInput": att(made[i], O_NEWREM), "Mode": "Set",
                "WFContentItemPropertyName": "Is Completed", "WFReminderContentItemIsCompleted": True}, U())

    u_open, u_all, b_open, b_all = find(done=False), find(), find(done=False, brk=True), find(brk=True)
    u_oc, u_ac, b_oc, b_ac = count(u_open), count(u_all), count(b_open), count(b_all)

    if kind == "look":
        A("is.workflow.actions.showresult", {"Text": ts(["シフト ", (u_ac, O_CNT), "件（まだ ", (u_oc, O_CNT), "件）・Break ",
                                                         (b_ac, O_CNT), "件（まだ ", (b_oc, O_CNT), "件）\n",
                                                         (u_all, O_FOUND), "\n", (b_all, O_FOUND)])})
        return acts

    g, items = U(), ["まだのシフトだけ", "済んだ分も全部", "やめる"]
    A("is.workflow.actions.choosefrommenu", {
        "WFMenuPrompt": ts(["シフトのリマインダー\nまだ：シフト ", (u_oc, O_CNT), "件・Break ", (b_oc, O_CNT),
                            "件\n済んだ分も入れて：シフト ", (u_ac, O_CNT), "件・Break ", (b_ac, O_CNT), "件\nどれを消す？"]),
        "WFControlFlowMode": 0, "WFMenuItems": items, "GroupingIdentifier": g})
    for item, src, bsrc, done in ((items[0], u_open, b_open, False), (items[1], u_all, b_all, None)):
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": item, "GroupingIdentifier": g, "WFControlFlowMode": 1})
        # シフトと Break を1つの変数に足してから1回で消す（OS の確認も1回）
        A("is.workflow.actions.appendvariable", {"WFInput": att(src, O_FOUND), "WFVariableName": VAR})
        A("is.workflow.actions.appendvariable", {"WFInput": att(bsrc, O_FOUND), "WFVariableName": VAR})
        # 0件なら消さない（空を渡したときの動きは裏が取れていない＝反証役 W1）
        u_n = A("is.workflow.actions.count", {"WFCountType": "Items", "Input": {"Value": {"Type": "Variable", "VariableName": VAR},
                "WFSerializationType": "WFTextTokenAttachment"}}, U())
        gi = U()
        A("is.workflow.actions.conditional", {"WFInput": {"Type": "Variable", "Variable": att(u_n, O_CNT)},
            "WFCondition": 2, "WFNumberValue": "0", "WFControlFlowMode": 0, "GroupingIdentifier": gi})
        A("is.workflow.actions.removereminders", {"WFInputReminders": {"Value": {"Type": "Variable", "VariableName": VAR},
                                                  "WFSerializationType": "WFTextTokenAttachment"}}, U())
        # 消したあとに探し直す（最初に数えた件数だけを信じない）
        u_l, b_l = count(find(done=done)), count(find(done=done, brk=True))
        what = "まだの分" if done is False else "済んだ分も入れて"
        A("is.workflow.actions.showresult", {"Text": ts([(u_n, O_CNT), "件を消しました\n残り（" + what + "）：シフト ",
                                                         (u_l, O_CNT), "件・Break ", (b_l, O_CNT), "件"])})
        A("is.workflow.actions.conditional", {"WFControlFlowMode": 1, "GroupingIdentifier": gi})
        A("is.workflow.actions.showresult", {"Text": ts("消すシフトはありません")})
        A("is.workflow.actions.conditional", {"WFControlFlowMode": 2, "GroupingIdentifier": gi}, U())
    A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[2], "GroupingIdentifier": g, "WFControlFlowMode": 1})
    A("is.workflow.actions.choosefrommenu", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
    return acts

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    empty = "--mac-test-empty" in sys.argv
    test = empty or "--mac-test" in sys.argv
    if not args:
        sys.exit(__doc__.strip().split("\n")[3])
    out = pathlib.Path(args[0]); out.mkdir(parents=True, exist_ok=True)
    plan = ((("clear", "_テスト消す0件"),) if empty else
            (("look", "_テスト消す見る"), ("clear", "_テスト消す"), ("clean", "_テスト消す片付け")) if test
            else (("look", "シフトを見る"), ("clear", "シフトを全部消す")))
    mine = [n for _, n in plan] + ["シフトを見る", "シフトを全部消す", "_テスト消す0件"]
    tmp = pathlib.Path(tempfile.mkdtemp())
    def stop(msg):
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(msg)
    done = []
    for kind, name in plan:
        acts = build(kind, test, empty)
        p, sp = tmp / (name + ".wflow"), tmp / (name + ".shortcut")
        plistlib.dump(wrap(acts, watch=False), open(p, "wb"))
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
    for p, sp, n in done:
        shutil.copy(sp, out / sp.name)
        if test:
            shutil.copy(p, out / p.name)
        print(sp.stem, "→", n, "アクション・署名OK →", str(out / sp.name), flush=True)
    shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
