#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""たすくノートの既存カードを1枚だけ書き換えるツール（タイトル・状態・優先度・本文の追記）。

tasknote_add.py が「新しく起こす」、tasknote_archive.py が「しまう」のに対して、
このツールは「すでにあるカードの中身を直す」担当。
中断・後回し・完了などで**カードの意味が変わったとき**に使う。

安全設計（[[tasknote-hub]] / [[mistakes]] P0 と同じ精神）:
  - 更新はすべてサーバー側 SQL。`state->'tasks'` を id で照合して**該当カードのキーだけ差し替える**。
    full-doc の read→write back は一切しない＝スマホで同時に編集していてもその編集を消さない。
  - 並び順は `with ordinality` で保存。タスク以外のキー（tags/columns/projects/ui）には触らない。
  - --append-body は本文ブロックを**末尾に足すだけ**。既存の本文は消さない。
  - --dry-run で変更前後を表示。--id で対象行を切替（検証は throwaway id で・実データ id='kodai' を汚さない）。

使い方:
  python3 tasknote_update.py --task-id t123 --title "新しいタイトル" --dry-run
  python3 tasknote_update.py --task-id t123 --status todo --priority low \
      --append-body "2026-08-17 後回しにした。理由＝…"
"""
import argparse, json, sys, time

from tasknote_add import ANON, REST, MGMT, curl_json, get_pat, run_sql, dollar, STATUS_OK, PRIORITY_OK  # noqa
from tasknote_archive import read_state_for  # noqa


def build_sql(state_id, task_id, patch, add_blocks):
    """該当カードだけ patch のキーを差し替え、add_blocks を body 末尾に足す。"""
    merge = dollar(json.dumps(patch, ensure_ascii=False)) + "::jsonb"
    body_expr = "t->'body'"
    if add_blocks:
        extra = dollar(json.dumps(add_blocks, ensure_ascii=False)) + "::jsonb"
        # body が無い/配列でないカードにも足せるように coalesce する
        body_expr = (f"(case when jsonb_typeof(t->'body') = 'array' "
                     f"then t->'body' else '[]'::jsonb end || {extra})")
    mutate = f"jsonb_set(t || {merge}, '{{body}}', {body_expr})"
    return (
        "update public.tasknote_state set state = jsonb_set(state, '{tasks}', coalesce(("
        "  select jsonb_agg(case when (t->>'id') = " + dollar(task_id) + " then " + mutate + " else t end order by ord)"
        "  from jsonb_array_elements(state->'tasks') with ordinality as e(t, ord)"
        "), '[]'::jsonb)), updated_at = now() "
        f"where id = {dollar(state_id)};"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task-id", required=True, help="書き換えるカードのid")
    ap.add_argument("--id", default="kodai", help="tasknote_state の行id（既定 kodai）")
    ap.add_argument("--title", default=None)
    ap.add_argument("--status", default=None, help="waiting / todo / doing / done")
    ap.add_argument("--priority", default=None, help="high / mid / low / none")
    ap.add_argument("--due", default=None, help="YYYY-MM-DD（空文字で解除）")
    ap.add_argument("--append-body", action="append", default=[], help="本文の末尾に足す段落（複数可）")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.status is not None and a.status not in STATUS_OK:
        sys.exit(f"status は {sorted(STATUS_OK)} のいずれか")
    if a.priority is not None and a.priority not in PRIORITY_OK:
        sys.exit(f"priority は {sorted(PRIORITY_OK)} のいずれか（medium ではなく mid）")

    state = read_state_for(a.id)
    if state is None:
        sys.exit(f"tasknote_state に id={a.id!r} の行がありません")
    card = next((t for t in state.get("tasks", []) if t.get("id") == a.task_id), None)
    if card is None:
        sys.exit(f"存在しないカードidです（中止）: {a.task_id}")

    patch = {"updated": int(time.time() * 1000)}
    if a.title is not None:
        patch["title"] = a.title
    if a.status is not None:
        patch["status"] = a.status
    if a.priority is not None:
        patch["priority"] = None if a.priority in ("none", "") else a.priority
    if a.due is not None:
        patch["due"] = a.due or None

    stamp = int(time.time() * 1000)
    add_blocks = [{"id": f"b{stamp}_{i}", "text": txt, "type": "text"}
                  for i, txt in enumerate(a.append_body)]

    print(f"■ 行id={a.id} / カードid={a.task_id}")
    for k, v in patch.items():
        if k == "updated":
            continue
        print(f"  {k}: {card.get(k)!r}  →  {v!r}")
    for b in add_blocks:
        print(f"  body +: {b['text'][:70]}")
    if not add_blocks and len(patch) == 1:
        sys.exit("変更する項目がありません")

    if a.dry_run:
        print("\n(dry-run: 何も書き込んでいません)")
        return

    out = run_sql(get_pat(), build_sql(a.id, a.task_id, patch, add_blocks))
    if '"error"' in out or ("message" in out and '"code"' in out):
        sys.exit("SQL失敗: " + out[:400])

    after = read_state_for(a.id)
    now = next((t for t in after.get("tasks", []) if t.get("id") == a.task_id), {})
    print(f"\n✓ 更新しました。いまの状態 = status:{now.get('status')} / priority:{now.get('priority')} / "
          f"本文{len(now.get('body') or [])}ブロック")
    print(f"  {now.get('title','')}")


if __name__ == "__main__":
    main()
