#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""たすくノートの「進捗ビュー（プロジェクト・ダッシュボード）」用メタを安全に書き込むツール。

Claude Code が各アプリの作業を進めたとき、そのプロジェクト（＝タグ）の
  - フェーズ（構想/設計/実装/検証/公開/保留/完了）
  - 進捗％の手動上書き（省略時はカードの done/total で自動計算）
  - 課題・ブロッカー（Claudeが管理する「今の課題」欄）
  - 進捗ログ（時系列。何をした／次の一手）
を、たすくノートのハブ（Supabase: tasknote_state / id='kodai'）へ残すために使う。

安全設計（[[tasknote-hub]] / [[mistakes]] P0 と同じ精神）:
  - すべてサーバー側 SQL の jsonb_set で **projects キスだけ** を更新。full-doc の上書きは一切しない
    ＝あなたがスマホで同時にカードを編集していても、その編集を消さない。
  - log / issue は安定キー（--key、既定は本文のmd5）で冪等。同じ内容を二重に足さない。
  - プロジェクト＝既存アプリのタグ。存在しないアプリ名を渡したらエラー（勝手にタグを作らない）。
  - --id で対象行を切替（既定 kodai）。検証は throwaway id で行い、実データ id='kodai' を汚さない。

使い方:
  # フェーズと進捗％をセット（progressは省略可＝自動計算に任せる）
  python3 tasknote_project.py set --app "いつつ" --phase release --progress 80

  # 進捗ログを1件追記（時系列に積む）
  python3 tasknote_project.py log --app "いつつ" --text "申請段取りを整理。スクショ枚数と審査手順をまとめた"

  # 課題・ブロッカーを1件追加 / 全消し
  python3 tasknote_project.py issue-add --app "いつつ" --text "Apple Developer登録が本人作業で未完"
  python3 tasknote_project.py issue-clear --app "いつつ"

  # いまのメタを表示（読み取りのみ）
  python3 tasknote_project.py show [--app "いつつ"]

  phase: idea(構想) design(設計) build(実装) verify(検証) release(公開) hold(保留) done(完了)
"""
import argparse, json, hashlib, sys, time

# 既存ツールのヘルパー・定数を再利用（import時は定数評価のみ・副作用なし）
from tasknote_add import ANON, REST, MGMT, curl_json, get_pat, run_sql, dollar, read_state  # noqa

PHASES = {"idea", "design", "build", "verify", "release", "hold", "done"}


def read_state_for(state_id):
    """指定idのstateを読む（read_stateはkodai固定なので汎用版）。"""
    txt = curl_json(["-H", f"apikey: {ANON}", "-H", f"Authorization: Bearer {ANON}",
                     f"{REST}?id=eq.{state_id}&select=state"])
    rows = json.loads(txt)
    return rows[0]["state"] if rows else None


def resolve_tag(state, app):
    """アプリ名 → 既存タグid。無ければ利用可能な名前を並べて終了。"""
    for t in state.get("tags", []):
        if t.get("name") == app:
            return t["id"]
    names = [t.get("name") for t in state.get("tags", [])]
    sys.exit(f"タグ（プロジェクト）が見つかりません: {app!r}\n利用可能: {names}")


def ensure_project_sql(state_id, tag_id):
    """projects と projects.<tagId> を最低 {} で存在させる（後続のパス指定を安全にする）。"""
    tq = dollar(tag_id)
    return (
        "update public.tasknote_state set state = jsonb_set("
        "  case when state ? 'projects' then state else state || '{\"projects\":{}}'::jsonb end,"
        f"  array['projects', {tq}],"
        f"  coalesce(state->'projects'->{tq}, '{{}}'::jsonb), true) "
        f"where id={dollar(state_id)};"
    )


def append_array_sql(state_id, tag_id, field, entry, dedup_key):
    """projects.<tagId>.<field>（配列）へ1件追記。dedup_key で冪等。"""
    tq = dollar(tag_id)
    cur = f"coalesce(state->'projects'->{tq}->'{field}', '[]'::jsonb)"
    entry_j = dollar(json.dumps([entry], ensure_ascii=False))
    guard = dollar(json.dumps([{"id": dedup_key}], ensure_ascii=False))
    return (
        "update public.tasknote_state set state = jsonb_set(state,"
        f"  array['projects', {tq}, '{field}'],"
        f"  {cur} || {entry_j}::jsonb, true), updated_at=now() "
        f"where id={dollar(state_id)} and not ({cur} @> {guard}::jsonb);"
    )


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_set = sub.add_parser("set", help="フェーズ/進捗%/開始日をセット（マージ）")
    p_set.add_argument("--app", required=True)
    p_set.add_argument("--phase", default=None)
    p_set.add_argument("--progress", type=int, default=None)
    p_set.add_argument("--started", default=None)
    p_set.add_argument("--id", default="kodai")

    p_log = sub.add_parser("log", help="進捗ログを1件追記")
    p_log.add_argument("--app", required=True)
    p_log.add_argument("--text", required=True)
    p_log.add_argument("--key", default="")
    p_log.add_argument("--id", default="kodai")

    p_iadd = sub.add_parser("issue-add", help="課題・ブロッカーを1件追加")
    p_iadd.add_argument("--app", required=True)
    p_iadd.add_argument("--text", required=True)
    p_iadd.add_argument("--key", default="")
    p_iadd.add_argument("--id", default="kodai")

    p_iclr = sub.add_parser("issue-clear", help="課題・ブロッカーを全消し")
    p_iclr.add_argument("--app", required=True)
    p_iclr.add_argument("--id", default="kodai")

    p_show = sub.add_parser("show", help="いまのメタを表示（読み取りのみ）")
    p_show.add_argument("--app", default=None)
    p_show.add_argument("--id", default="kodai")

    a = ap.parse_args()
    state = read_state_for(a.id)
    if state is None:
        sys.exit(f"tasknote_state に id={a.id!r} の行がありません")

    # ---- show（読み取りのみ・SQLを打たない） ----
    if a.cmd == "show":
        projects = state.get("projects", {}) or {}
        tags = {t["id"]: t.get("name") for t in state.get("tags", [])}
        if a.app:
            tid = resolve_tag(state, a.app)
            print(json.dumps({tags.get(tid, tid): projects.get(tid, {})}, ensure_ascii=False, indent=2))
        else:
            named = {tags.get(k, k): v for k, v in projects.items()}
            print(json.dumps(named, ensure_ascii=False, indent=2))
        return

    tag_id = resolve_tag(state, a.app)
    now = int(time.time() * 1000)
    pat = get_pat()

    # ---- set（フェーズ/進捗/開始日をマージ） ----
    if a.cmd == "set":
        patch = {}
        if a.phase is not None:
            if a.phase not in PHASES:
                sys.exit(f"phase は {sorted(PHASES)} のいずれか")
            patch["phase"] = a.phase
        if a.progress is not None:
            patch["progress"] = max(0, min(100, a.progress))
        if a.started is not None:
            patch["started"] = a.started
        if not patch:
            sys.exit("--phase / --progress / --started のいずれかを指定してください")
        patch["updated"] = now
        tq = dollar(tag_id)
        sql = (
            "update public.tasknote_state set state = jsonb_set("
            "  case when state ? 'projects' then state else state || '{\"projects\":{}}'::jsonb end,"
            f"  array['projects', {tq}],"
            f"  coalesce(state->'projects'->{tq}, '{{}}'::jsonb) || {dollar(json.dumps(patch, ensure_ascii=False))}::jsonb,"
            f"  true), updated_at=now() where id={dollar(a.id)};"
        )
        run_sql(pat, sql)
        print(f"✓ set [{a.app}] " + " ".join(f"{k}={v}" for k, v in patch.items() if k != "updated"))
        return

    # ---- issue-clear ----
    if a.cmd == "issue-clear":
        run_sql(pat, ensure_project_sql(a.id, tag_id))
        tq = dollar(tag_id)
        sql = (
            "update public.tasknote_state set state = jsonb_set(state,"
            f"  array['projects', {tq}, 'issues'], '[]'::jsonb, true), updated_at=now() "
            f"where id={dollar(a.id)};"
        )
        run_sql(pat, sql)
        print(f"✓ issue-clear [{a.app}]")
        return

    # ---- log / issue-add（配列に冪等追記） ----
    field = "log" if a.cmd == "log" else "issues"
    key = a.key or ("k" + hashlib.md5(a.text.encode()).hexdigest()[:12])
    already = any(e.get("id") == key
                  for e in (state.get("projects", {}).get(tag_id, {}) or {}).get(field, []))
    if already:
        print(f"⏭  既に登録済み（{field} id={key}）。追記しませんでした。")
        return
    entry = {"id": key, "at": now, "text": a.text}
    run_sql(pat, ensure_project_sql(a.id, tag_id))
    run_sql(pat, append_array_sql(a.id, tag_id, field, entry, key))
    label = "進捗ログ" if field == "log" else "課題"
    print(f"✓ {label}を追記 [{a.app}] {a.text}  id={key}")


if __name__ == "__main__":
    main()
