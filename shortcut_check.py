# -*- coding: utf-8 -*-
"""使い方: python3 shortcut_check.py <つくった.wflow>

Appleショートカットを手組みしたら、焼く前に必ずこれを通す（正本の道具）。
**焼いた .shortcut は署名済みで読めない。検査は署名前の .wflow にかける。**

5段で照合する。段が増えた理由は、前の版が「照合できなかったものを黙って通していた」ため。
  ① アクション識別子とキー名 … 実動ライブラリ／システムの文字列／Apple の文言表に在るか
  ② 直列化の型 … 同じアクション・同じキーで、実動例と WFSerializationType が一致するか
  ③ 値の意味 … 定数を取る欄（WFCondition など）が、意味の分かっている値かどうか
  ④ **辞書の中身** … WFDictionaryFieldValueItems の WFKey / WFValue まで降りる
  ⑤ **組み立ての筋** … 差し込み先の UUID が実在するか・前方参照でないか、もし／繰り返しの 0→1→2 が対応するか

**照合できなかった引数は「一致」と言わない。** 実動ライブラリに例が無い (アクション, キー) は
VERIFIED に出どころを書いたものだけ通し、それ以外は ✗ にする。
2026-09-22 まで、downloadurl の5つの欄が「実例ゼロ＝無検査」のまま「✗ 0」と印字されていた。

正本: ~/Library/Shortcuts/Shortcuts.sqlite（複製を読む・本体は触らない。-wal も一緒に写す）
複製の置き場は ~/.cache/tsumiki/（0600）。**/tmp に置かない**（他の利用者から読める）。
"""
import plistlib, sqlite3, collections, sys, os, re, shutil, subprocess

CACHE_DIR = os.path.expanduser("~/.cache/tsumiki")
DB = os.path.join(CACHE_DIR, "shortcut_library.sqlite")
LIST = os.path.join(CACHE_DIR, "shortcut_strings.txt")
SRC = os.path.expanduser("~/Library/Shortcuts/Shortcuts.sqlite")
CACHE = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"
LOC = "/System/Library/PrivateFrameworks/WorkflowKit.framework/Resources/Localizable.loctable"
PAT = re.compile(r"^(is\.workflow\.actions\.[a-z0-9.]+|WF[A-Za-z]+|Repeat (Item|Index))$")

# 実測で意味を確定させた定数（実動4本から裏取り）。99 は実動3件あるが意味は未確定。
COND = {0: "より小さい", 1: "以下", 2: "より大きい", 3: "以上", 4: "等しい",
        99: "（実動例あり・意味は未確定）", 1003: "範囲内", 100: "値がある", 101: "値がない"}
ENUM = {
    ("is.workflow.actions.getitemfromlist", "WFItemSpecifier"):
        {"First Item", "Last Item", "Item At Index", "Random Item", "Items in Range"},
    ("is.workflow.actions.addnewreminder", "WFAlertEnabled"): {"Alert", "None"},
    ("is.workflow.actions.addnewreminder", "WFAlertCondition"): {"At Time", "Arrive", "Leave"},
    ("is.workflow.actions.addnewreminder", "WFPriority"): {"None", "Low", "Medium", "High"},
    ("is.workflow.actions.downloadurl", "WFHTTPMethod"): {"GET", "POST", "PUT", "PATCH", "DELETE"},
    ("is.workflow.actions.downloadurl", "WFHTTPBodyType"): {"JSON", "Form", "File", "Request Body"},
    ("is.workflow.actions.format.date", "WFDateFormatStyle"):
        {"Short", "Medium", "Long", "Relative", "ISO 8601", "RFC 2822", "Custom"},
    ("is.workflow.actions.date", "WFDateActionMode"): {"Current Date", "Specified Date"},
}

# 実動ライブラリに例が無いが、別の道で裏を取ったもの。**ここに書いていない未照合は ✗ になる。**
# 形は (識別子, キー): (許される直列化の型, 出どころ)
VERIFIED = {
    ("is.workflow.actions.downloadurl", "WFURL"):
        ("WFTextTokenString", "Watch実機で list が200で返った（2026-09-19/20）＋loctable にキーあり"),
    ("is.workflow.actions.downloadurl", "WFHTTPMethod"):
        ("str", "同上（POST が届いている＝Supabase のログに POST として記録）"),
    ("is.workflow.actions.downloadurl", "WFHTTPBodyType"):
        ("str", "同上（本文が JSON として解釈され、token と action が届いている）"),
    ("is.workflow.actions.downloadurl", "WFHTTPHeaders"):
        ("WFDictionaryFieldValue", "同上（Authorization が届かなければ 401 になる。200 が返っている）"),
    ("is.workflow.actions.downloadurl", "WFJSONValues"):
        ("WFDictionaryFieldValue", "同上（固定値の token / action は届いている。**差し込みは届かない** → 下の禁止）"),
}

def die(msg, code=2):
    print(msg)
    sys.exit(code)

# --ref <署名前の plist> … ライブラリに無いアクションの実動例として足す（公開ショートカットの記録など）。
#   出どころは呼ぶ側が控えておく（例: build_health_shortcut.py の REF）。何本でも。
args, REFS = [], []
_it = iter(sys.argv[1:])
for _a in _it:
    if _a == "--ref":
        REFS.append(next(_it, ""))
    else:
        args.append(_a)
if not args:
    die(__doc__.strip().split("\n")[0])
target = args[0]
if not os.path.exists(target):
    die("そのファイルがありません: " + target)
try:
    wf = plistlib.load(open(target, "rb"))
except plistlib.InvalidFileException:
    die("plist として読めません。**署名済みの .shortcut ではなく、署名前の .wflow を渡してください。**")

# ---- 実動ライブラリ（キー名と型を集める）-----------------------
os.makedirs(CACHE_DIR, exist_ok=True)
os.chmod(CACHE_DIR, 0o700)
copied = False
if os.path.exists(SRC):
    try:                                   # 読めるなら毎回写し直す（古い複製で照合しない）
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(SRC + ext):
                shutil.copy(SRC + ext, DB + ext)
                os.chmod(DB + ext, 0o600)
        copied = True
    except (PermissionError, OSError):
        pass
if not os.path.exists(DB):
    die("実動ライブラリが読めない。フルディスクアクセスのあるシェルで一度だけ:\n"
        f'  mkdir -p {CACHE_DIR} && cp "{SRC}" "{DB}" && chmod 600 "{DB}"')
if not copied:
    import time
    age = (time.time() - os.path.getmtime(DB)) / 86400
    print(f"  ※ ライブラリの複製は {age:.1f} 日前のもの（読み直せなかった）。新しく作ったショートカットは照合に入りません。")
    if age > 3:
        print(f'     新しくするなら、フルディスクアクセスのあるシェルで: cp "{SRC}" "{DB}" && chmod 600 "{DB}"')

lib = collections.defaultdict(set)
types = collections.defaultdict(collections.Counter)
for (data,) in sqlite3.connect(DB).execute("select ZDATA from ZSHORTCUTACTIONS"):
    if not data:
        continue
    try:
        acts = plistlib.loads(data)
    except Exception:
        continue
    if not isinstance(acts, list):
        continue
    for a in acts:
        i = a.get("WFWorkflowActionIdentifier")
        for k, v in (a.get("WFWorkflowActionParameters") or {}).items():
            lib[i].add(k)
            types[(i, k)][v.get("WFSerializationType") if isinstance(v, dict) else type(v).__name__] += 1

for _r in REFS:
    try:
        _acts = plistlib.load(open(_r, "rb")).get("WFWorkflowActions", [])
    except Exception:
        die("--ref が plist として読めません: " + _r)
    print(f"  ＋ 実動例として足した: {os.path.basename(_r)}（{len(_acts)} 個のアクション）")
    for a in _acts:
        i = a.get("WFWorkflowActionIdentifier")
        for k, v in (a.get("WFWorkflowActionParameters") or {}).items():
            lib[i].add(k)
            types[(i, k)][v.get("WFSerializationType") if isinstance(v, dict) else type(v).__name__] += 1

# ---- システムの文字列 --------------------------------------------
if not os.path.exists(LIST):
    lines = set()
    for f in (CACHE, CACHE + ".01"):
        if os.path.exists(f):
            out = subprocess.run(["strings", "-a", "-n", "6", f], capture_output=True, text=True).stdout
            lines |= {l for l in out.split("\n") if PAT.match(l)}
    open(LIST, "w", encoding="utf-8").write("\n".join(sorted(lines)))
    os.chmod(LIST, 0o600)
sysstr = set(open(LIST, encoding="utf-8").read().split("\n"))
# Apple の文言表からもキー名を拾う（共有キャッシュに文字列として出ないキーがある。例: WFURL）
if os.path.exists(LOC):
    _d = plistlib.load(open(LOC, "rb"))
    for _lang in ("en", "ja"):
        for _k in (_d.get(_lang) or {}):
            for _m in re.finditer(r"\((WF[A-Za-z]+)\)", _k):
                sysstr.add(_m.group(1))
            for _m in re.finditer(r"\$\{(WF[A-Za-z]+)\}", _k):
                sysstr.add(_m.group(1))

def stype(v):
    return v.get("WFSerializationType") if isinstance(v, dict) else type(v).__name__

def atts(v):
    """テキストの入れ物に差し込まれた添付を返す"""
    if isinstance(v, dict) and isinstance(v.get("Value"), dict):
        ab = v["Value"].get("attachmentsByRange")
        if isinstance(ab, dict):
            return list(ab.values())
    return []

ng, checked, verified, skipped = [], 0, 0, []
acts = wf["WFWorkflowActions"]
seen_uuid = set()

for n, a in enumerate(acts):
    i = a["WFWorkflowActionIdentifier"]
    if i not in lib and i not in sysstr:
        ng.append(f"#{n} {i}：アクションがどちらにも無い")
    params = a.get("WFWorkflowActionParameters") or {}
    for k, v in params.items():
        if k == "UUID":
            continue
        # ① キー名
        if k not in lib.get(i, ()) and k not in sysstr:
            ng.append(f"#{n} {i} の {k}：キー名がどちらにも無い")
            continue
        # ② 直列化の型
        seen = types.get((i, k))
        mine = stype(v)
        if seen:
            checked += 1
            if mine not in seen:
                ng.append(f"#{n} {i} の {k}：型が {mine}。実動例は {dict(seen)}")
        elif (i, k) in VERIFIED:
            want, src = VERIFIED[(i, k)]
            verified += 1
            if mine != want:
                ng.append(f"#{n} {i} の {k}：型が {mine}。裏取り表では {want}（{src}）")
        else:
            skipped.append(f"#{n} {i} の {k}（型 {mine}）")
        # ③ 値の意味
        if (i, k) in ENUM and isinstance(v, str) and v not in ENUM[(i, k)]:
            ng.append(f"#{n} {i} の {k}：値 '{v}' は既知の定数に無い（{sorted(ENUM[(i,k)])}）")
        if k == "WFCondition":
            if v not in COND:
                ng.append(f"#{n} {i} の WFCondition：{v} は意味が分かっていない値")
            else:
                print(f"  ・#{n} WFCondition={v} → 「{COND[v]}」")
        # ④ 辞書の中身（キーの型だけ見て通さない）
        if isinstance(v, dict) and v.get("WFSerializationType") == "WFDictionaryFieldValue":
            for it in (v.get("Value") or {}).get("WFDictionaryFieldValueItems") or []:
                if it.get("WFItemType") != 0:
                    ng.append(f"#{n} {i} の {k}：WFItemType={it.get('WFItemType')} は実動例（0＝テキスト）に無い")
                for side in ("WFKey", "WFValue"):
                    w = it.get(side)
                    if stype(w) != "WFTextTokenString":
                        ng.append(f"#{n} {i} の {k} の {side}：型が {stype(w)}。実動例は WFTextTokenString")
                    # **禁止**: 辞書の値への差し込みは Watch で空になる（2026-09-22 実測・Supabase のログで 400 を確認）
                    if atts(w):
                        ng.append(f"#{n} {i} の {k} の {side}：辞書の中に変数を差し込んでいる。"
                                  "**Watch では空で届く**（2026-09-22 実測）。URL の文字列に差し込む形にする")
        # ⑤ 差し込み先の UUID が実在するか・前方参照でないか
        for att in atts(v):
            if att.get("Type") == "ActionOutput":
                u = att.get("OutputUUID")
                if u not in seen_uuid:
                    ng.append(f"#{n} {i} の {k}：まだ出ていない（または存在しない）出力を差し込んでいる")
        if isinstance(v, dict) and v.get("Type") == "Variable":
            for att in atts(v.get("Variable")):
                if att.get("Type") == "ActionOutput" and att.get("OutputUUID") not in seen_uuid:
                    ng.append(f"#{n} {i} の {k}：まだ出ていない出力を差し込んでいる（Variable の中）")
        if isinstance(v, dict) and stype(v) == "WFTextTokenAttachment":
            val = v.get("Value") or {}
            if val.get("Type") == "ActionOutput" and val.get("OutputUUID") not in seen_uuid:
                ng.append(f"#{n} {i} の {k}：まだ出ていない出力を指している")
    if params.get("UUID"):
        seen_uuid.add(params["UUID"])

# ⑤' もし／繰り返しの 0→1→2 が対応しているか
groups = collections.defaultdict(list)
for n, a in enumerate(acts):
    p = a.get("WFWorkflowActionParameters") or {}
    if "GroupingIdentifier" in p:
        groups[p["GroupingIdentifier"]].append((n, p.get("WFControlFlowMode")))
for g, seq in groups.items():
    modes = [m for _, m in seq]
    if modes[0] != 0 or modes[-1] != 2 or any(m not in (0, 1, 2) for m in modes):
        ng.append(f"制御フローの組が対応していない（{[f'#{n}:{m}' for n, m in seq]}）")

print()
print(f"照合 {checked} 件（実動例と突き合わせ）／裏取り表 {verified} 件／**未照合 {len(skipped)} 件**")
for s in skipped:
    print("    未照合:", s)
if skipped:
    ng.append(f"未照合が {len(skipped)} 件ある。裏の取れないまま焼かない（VERIFIED に出どころを書くか、形を変える）")
if ng:
    print("✗ 指摘")
    for x in ng:
        print("   ", x)
else:
    print("✗ 0（キー名・型・定数・辞書の中身・組み立ての筋、すべて裏が取れている）")
sys.exit(1 if ng else 0)
