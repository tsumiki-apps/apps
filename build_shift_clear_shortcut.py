# -*- coding: utf-8 -*-
"""「シフトをリマインダーに」で入れたシフトのリマインダーだけを、まとめて消すショートカットを組み立てる。
シフト表が組み直されたとき、古いシフトを消してから入れ直すために使う。

使い方: python3 build_shift_clear_shortcut.py <出力先フォルダ> [--mac-test]

作るもの:
  シフトを全部消す.shortcut … 題名に「•」がある物（＝シフト。題名が「Product Zone • Sales 1」の形）を探し、
                              件数を見せて「まだのシフトだけ／済んだ分も全部／やめる」を選ぶ → 消す → 探し直して残りを出す。
                              消す直前に OS が題名つきで「削除しますか」を出す（ここでも止められる）。
  シフトを見る.shortcut     … 探して並べるだけ。**何も消さない**（消す前に、シフト以外が混ざっていないかを見る用）

シフトの見分け方は build_reminder_resched_shortcut.py の SHIFT_MARK と同じ（題名に「•」）。

--mac-test … Mac で `shortcuts run` して確かめる版（_テスト〜）。**本物のリマインダーは触らない**:
  題名が「_テスト消す」で始まる物だけを相手にする。自分で架空のシフト2件（未完了1・完了1）と、
  「•」の無い囮1件を作ってから消す。囮は残るはず。
  _テスト消す見る … 作って並べるだけ／_テスト消す … 作って選んで消す／_テスト消す片付け … _テスト消す〜 を全部消す
"""
import plistlib, sys, subprocess, pathlib, tempfile, shutil
from build_reminder_resched_shortcut import U, ts, att, wrap, SHIFT_MARK, O_FOUND, O_CNT, O_DATE, O_NEWREM

HERE = pathlib.Path(__file__).parent
TEST = "_テスト消す"

def cond(prop, op, **v):
    return {"Property": prop, "Operator": op, "Values": {"Unit": 4, **v}, "Removable": True}

def build(kind, test=False):
    """kind: "look"（見るだけ）／"clear"（選んで消す）／"clean"（テストの片付け）"""
    acts = []
    def A(i, p=None, u=None):
        q = dict(p or {})
        if u: q["UUID"] = u
        acts.append({"WFWorkflowActionIdentifier": i, "WFWorkflowActionParameters": q})
        return u

    def find(done=None, shift=True):
        """シフト（題名に•）を探す。done=False は未完了だけ。テスト版は題名の頭 _テスト消す でも絞る"""
        t = [cond("Title", 99, String=SHIFT_MARK)] if shift else []
        if done is not None:
            t.append(cond("Is Completed", 4, Bool=done))
        if test:
            t.insert(0, cond("Title", 99, String=TEST))
        return A("is.workflow.actions.filter.reminders", {"WFContentItemFilter": {"Value": {
            "WFActionParameterFilterPrefix": 1, "WFContentPredicateBoundedDate": False,
            "WFActionParameterFilterTemplates": t}, "WFSerializationType": "WFContentPredicateTableTemplate"},
            "WFContentItemLimitEnabled": False}, U())

    def count(u):
        return A("is.workflow.actions.count", {"WFCountType": "Items", "Input": att(u, O_FOUND)}, U())

    if kind == "clean":
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(find(shift=False), O_FOUND)}, U())
        return acts

    if test:
        # 架空のシフト2件（明日 10:00・1件は完了にする）と、• の無い囮1件
        u_now = A("is.workflow.actions.date", {}, U())
        u_t = A("is.workflow.actions.adjustdate", {"WFDate": ts([(u_now, O_DATE)]), "WFDuration": {
            "Value": {"Unit": "min", "Magnitude": "1440"}, "WFSerializationType": "WFQuantityFieldValue"}}, U())
        made = []
        for title in (TEST + " Zone • Sales 1", TEST + " Zone • Sales 2", TEST + " 囮"):
            made.append(A("is.workflow.actions.addnewreminder", {
                "WFCalendarItemTitle": ts(title), "WFAlertEnabled": "Alert", "WFAlertCondition": "At Time",
                "WFAlertCustomTime": ts([(u_t, "調整後の日付")]), "WFPriority": "None"}, U()))
        A("is.workflow.actions.setters.reminders", {"WFInput": att(made[1], O_NEWREM), "Mode": "Set",
            "WFContentItemPropertyName": "Is Completed", "WFReminderContentItemIsCompleted": True}, U())

    u_open, u_all = find(done=False), find()
    u_oc, u_ac = count(u_open), count(u_all)

    if kind == "look":
        A("is.workflow.actions.showresult", {"Text": ts(["シフト ", (u_ac, O_CNT), "件（まだ ", (u_oc, O_CNT), "件）\n",
                                                         (u_all, O_FOUND)])})
        return acts

    g, items = U(), ["まだのシフトだけ", "済んだ分も全部", "やめる"]
    A("is.workflow.actions.choosefrommenu", {
        "WFMenuPrompt": ts(["シフトのリマインダー\nまだ ", (u_oc, O_CNT), "件・済んだ分も入れて ", (u_ac, O_CNT), "件\nどれを消す？"]),
        "WFControlFlowMode": 0, "WFMenuItems": items, "GroupingIdentifier": g})
    for item, src in ((items[0], u_open), (items[1], u_all)):
        A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": item, "GroupingIdentifier": g, "WFControlFlowMode": 1})
        A("is.workflow.actions.removereminders", {"WFInputReminders": att(src, O_FOUND)}, U())
        # 消したあとに探し直す（最初に数えた件数だけを信じない）
        u_l = count(find(done=False if src == u_open else None))
        A("is.workflow.actions.showresult", {"Text": ts(["シフトを消しました\n残り ", (u_l, O_CNT), "件"])})
    A("is.workflow.actions.choosefrommenu", {"WFMenuItemTitle": items[2], "GroupingIdentifier": g, "WFControlFlowMode": 1})
    A("is.workflow.actions.choosefrommenu", {"GroupingIdentifier": g, "WFControlFlowMode": 2}, U())
    return acts

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    test = "--mac-test" in sys.argv
    if not args:
        sys.exit(__doc__.strip().split("\n")[3])
    out = pathlib.Path(args[0]); out.mkdir(parents=True, exist_ok=True)
    plan = ((("look", "_テスト消す見る"), ("clear", "_テスト消す"), ("clean", "_テスト消す片付け")) if test
            else (("look", "シフトを見る"), ("clear", "シフトを全部消す")))
    mine = [n for _, n in plan] + ["シフトを見る", "シフトを全部消す"]
    tmp = pathlib.Path(tempfile.mkdtemp())
    def stop(msg):
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit(msg)
    done = []
    for kind, name in plan:
        acts = build(kind, test)
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
