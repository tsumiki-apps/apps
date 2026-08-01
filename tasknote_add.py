# -*- coding: utf-8 -*-
"""たすくノート（Notion風タスク管理ハブ）にカードを1枚 追記するツール。

Claude Code が並行制作の各アプリで「Kodaiがやること・確認すること」が決まったとき、
Obsidian記録に加えてこのハブ（Supabase: tasknote_state / id='kodai'）へも起票するために使う。

安全設計:
  - 追記はサーバー側の SQL で「現在のtasks末尾に連結」＝私の読み取り時点ではなく
    実行時点のDB値に足すので、あなたが同時にスマホで編集していても上書きしない。
  - 各カードに安定キー _key を持たせ、同じ _key があれば追記しない（二重起票防止＝冪等）。
  - アプリ名→タグは名前で既存を再利用、無ければ作成（idで冪等）。
  - 実データ保護のため full-doc の上書きは一切しない（jsonb連結のみ）。

使い方:
  python3 tasknote_add.py --title "ボール：作り直しの方針を確認して" \
      --app "ボール" --status waiting --priority high \
      --body "どの案で作り直すか決めてほしい" --key "ball-redesign-confirm"

  --status : waiting(あなた待ち) / todo(やること) / doing(進行中) / done(完了)  既定 waiting
  --priority : high / mid / low / none   既定 none
  --due : YYYY-MM-DD（省略可）
  --app : アプリ名（タグになる。省略可）
  --body : 本文の段落（複数回指定でブロック複数）
  --key : 二重起票を防ぐ安定キー（省略時は title から自動生成）
  --source : 既定 claude（あなた自身の手動起票なら self 等）
"""
import argparse, json, hashlib, subprocess, sys, time, os

PROJECT_REF = "okbjqtdirrathscctyvx"
ANON = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9r"
        "YmpxdGRpcnJhdGhzY2N0eXZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjI4NTIsImV4cCI6"
        "MjA5NTg5ODg1Mn0.T-1AOK6vCD6uGdqrVGXjPui3L6WPSNrnygS-IHyfZ6Y")
REST = f"https://{PROJECT_REF}.supabase.co/rest/v1/tasknote_state"
MGMT = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
COLORS = ["gray","brown","orange","yellow","green","blue","purple","pink","red"]
STATUS_OK = {"waiting","todo","doing","done"}
PRIORITY_OK = {"high","mid","low","none",""}


def curl_json(args):
    out = subprocess.run(["curl","-s",*args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("curl failed: "+out.stderr)
    return out.stdout


def get_pat():
    """~/.claude.json の Supabase MCP env から Personal Access Token を読む。"""
    p = os.path.expanduser("~/.claude.json")
    d = json.load(open(p, encoding="utf-8"))
    return d["mcpServers"]["supabase"]["env"]["SUPABASE_ACCESS_TOKEN"]


def read_state():
    txt = curl_json(["-H",f"apikey: {ANON}","-H",f"Authorization: Bearer {ANON}",
                     f"{REST}?id=eq.kodai&select=state"])
    rows = json.loads(txt)
    return rows[0]["state"] if rows else None


def run_sql(pat, sql):
    body = json.dumps({"query": sql})
    txt = curl_json(["-X","POST",MGMT,"-H",f"Authorization: Bearer {pat}",
                     "-H","Content-Type: application/json","--data-binary",body])
    return txt


def dollar(s):
    """任意文字列を安全にSQLへ渡すためのドル引用符リテラル。"""
    tag = "$q9$"
    if tag in s:
        tag = "$q" + hashlib.md5(s.encode()).hexdigest()[:6] + "$"
    return tag + s + tag


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--app", default="")
    ap.add_argument("--status", default="waiting")
    ap.add_argument("--priority", default="none")
    ap.add_argument("--due", default="")
    ap.add_argument("--body", action="append", default=[])
    ap.add_argument("--key", default="")
    ap.add_argument("--source", default="claude")
    a = ap.parse_args()

    if a.status not in STATUS_OK:
        sys.exit(f"status は {STATUS_OK} のいずれか")
    # アプリ側のラベルは high/mid/low のみ。medium 等を入れるとカードに undefined と出る
    if a.priority not in PRIORITY_OK:
        sys.exit(f"priority は {sorted(PRIORITY_OK)} のいずれか（medium ではなく mid）")
    priority = None if a.priority in ("none","") else a.priority
    due = a.due or None
    key = a.key or ("auto-" + hashlib.md5((a.app+"|"+a.title).encode()).hexdigest()[:12])

    state = read_state()
    if state is None:
        sys.exit("tasknote_state に id='kodai' の行がありません（アプリを一度開くか初期化してください）")

    # --- タグ解決（名前で既存再利用、無ければ作成） ---
    tag_id = None
    new_tag_sql = None
    if a.app:
        for t in state.get("tags", []):
            if t.get("name") == a.app:
                tag_id = t["id"]; break
        if tag_id is None:
            tag_id = "app_" + hashlib.md5(a.app.encode()).hexdigest()[:8]
            color = COLORS[len(state.get("tags", [])) % len(COLORS)]
            tag_obj = {"id": tag_id, "name": a.app, "color": color}
            new_tag_sql = (
                "update public.tasknote_state set state = jsonb_set(state,'{tags}', "
                f"(state->'tags') || {dollar(json.dumps(tag_obj, ensure_ascii=False))}::jsonb) "
                f"where id='kodai' and not (state->'tags' @> {dollar(json.dumps([{'id':tag_id}]))}::jsonb);"
            )

    # --- カード生成 ---
    now = int(time.time()*1000)
    body = [{"id": f"b{now}_{i}", "type":"text", "text": p} for i, p in enumerate(a.body)]
    task = {
        "id": f"t{now}", "title": a.title, "status": a.status,
        "priority": priority, "due": due, "tags": [tag_id] if tag_id else [],
        "body": body, "created": now, "updated": now,
        "source": a.source, "_key": key,
    }
    task_sql = (
        "update public.tasknote_state set state = jsonb_set(state,'{tasks}', "
        f"(state->'tasks') || {dollar(json.dumps(task, ensure_ascii=False))}::jsonb), updated_at=now() "
        f"where id='kodai' and not (state->'tasks' @> {dollar(json.dumps([{'_key':key}]))}::jsonb);"
    )

    # 既に同じ _key があるか（冪等チェック・報告用）
    already = any(t.get("_key") == key for t in state.get("tasks", []))
    if already:
        print(f"⏭  既に起票済み（_key={key}）。追記しませんでした。")
        return

    pat = get_pat()
    if new_tag_sql:
        run_sql(pat, new_tag_sql)
    run_sql(pat, task_sql)
    print(f"✓ 起票しました: [{a.status}] {a.title}"
          + (f"  #タグ:{a.app}" if a.app else "")
          + (f"  優先:{priority}" if priority else "")
          + f"  _key={key}")


if __name__ == "__main__":
    main()
