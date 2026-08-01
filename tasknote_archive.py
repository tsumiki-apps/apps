#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""たすくノートのカードを「アーカイブ」する／戻すツール。

アーカイブ＝カードに `archived: true` を立てるだけ。削除ではない。
たすくノート側は archived のカードをボード/リスト/カレンダー/進捗のどこにも出さず、
集計にも数えない。「絞り込み → アーカイブを表示」で見返せて、詳細ページの箱アイコンで戻せる。

安全設計（[[tasknote-hub]] / [[mistakes]] P0 と同じ精神）:
  - 更新はすべてサーバー側 SQL。`state->'tasks'` を id で照合して**該当カードにキーを1個足すだけ**。
    full-doc の read→write back は一切しない＝スマホで同時に編集していてもその編集を消さない。
  - 並び順は `with ordinality` で保存。タスク以外のキー（tags/columns/projects/ui）には触らない。
  - 冪等。すでに archived のカードに再実行しても内容は変わらない。
  - --dry-run で対象だけ表示。--id で対象行を切替（検証は throwaway id で・実データ id='kodai' を汚さない）。

使い方:
  python3 tasknote_archive.py --file plan.json --dry-run     # 対象を確認
  python3 tasknote_archive.py --file plan.json               # 実行（アーカイブ）
  python3 tasknote_archive.py --file plan.json --unarchive   # まとめて戻す
  python3 tasknote_archive.py --task-id t123 --task-id t456  # idを直接指定

  plan.json の形: {"archive": [{"id": "t...", "title": "...", "why": "..."}]}
"""
import argparse, json, sys

from tasknote_add import ANON, REST, MGMT, curl_json, get_pat, run_sql, dollar  # noqa


def read_state_for(state_id):
    txt = curl_json(["-H", f"apikey: {ANON}", "-H", f"Authorization: Bearer {ANON}",
                     f"{REST}?id=eq.{state_id}&select=state"])
    rows = json.loads(txt)
    return rows[0]["state"] if rows else None


def build_sql(state_id, ids, unarchive):
    """tasks配列を走査し、id一致のカードだけ archived を足す/外す。順序は ordinality で保持。"""
    arr = "array[" + ",".join(dollar(i) for i in ids) + "]::text[]"
    mutate = "(t - 'archived')" if unarchive else "(t || '{\"archived\": true}'::jsonb)"
    return (
        "update public.tasknote_state set state = jsonb_set(state, '{tasks}', coalesce(("
        "  select jsonb_agg(case when (t->>'id') = any(" + arr + ") then " + mutate + " else t end order by ord)"
        "  from jsonb_array_elements(state->'tasks') with ordinality as e(t, ord)"
        "), '[]'::jsonb)), updated_at = now() "
        f"where id = {dollar(state_id)};"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="", help="plan.json（archive配列）")
    ap.add_argument("--task-id", action="append", default=[], help="対象カードid（複数可）")
    ap.add_argument("--id", default="kodai", help="tasknote_state の行id（既定 kodai）")
    ap.add_argument("--unarchive", action="store_true", help="アーカイブから戻す")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    ids = list(a.task_id)
    plan = []
    if a.file:
        plan = json.load(open(a.file, encoding="utf-8"))["archive"]
        ids += [p["id"] for p in plan]
    ids = list(dict.fromkeys(ids))
    if not ids:
        sys.exit("対象がありません（--file か --task-id を指定）")

    state = read_state_for(a.id)
    if state is None:
        sys.exit(f"tasknote_state に id={a.id!r} の行がありません")
    by_id = {t.get("id"): t for t in state.get("tasks", [])}

    missing = [i for i in ids if i not in by_id]
    if missing:
        sys.exit(f"存在しないカードidが含まれています（中止）: {missing}")

    verb = "アーカイブから戻す" if a.unarchive else "アーカイブする"
    done_verb = "アーカイブから戻しました" if a.unarchive else "アーカイブしました"
    want = (not a.unarchive)
    todo = [i for i in ids if bool(by_id[i].get("archived")) != want]
    print(f"■ 対象 {len(ids)}件／うち実際に変わるもの {len(todo)}件（行id={a.id}・{verb}）")
    titles = {p["id"]: p for p in plan}
    for i in ids:
        mark = "→" if i in todo else "・"  # ・= すでにその状態（冪等）
        why = titles.get(i, {}).get("why", "")
        print(f"  {mark} {by_id[i].get('title','')[:52]}" + (f"   〔{why}〕" if why else ""))

    if a.dry_run:
        print("\n(dry-run: 何も書き込んでいません)")
        return
    if not todo:
        print("\n変更なし（すでに全部その状態です）")
        return

    out = run_sql(get_pat(), build_sql(a.id, ids, a.unarchive))
    if '"error"' in out or "message" in out and '"code"' in out:
        sys.exit("SQL失敗: " + out[:400])

    after = read_state_for(a.id)
    n = sum(1 for t in after.get("tasks", []) if t.get("archived"))
    print(f"\n✓ {done_verb}。いまアーカイブ済み = {n}件／全{len(after.get('tasks', []))}件")


if __name__ == "__main__":
    main()
