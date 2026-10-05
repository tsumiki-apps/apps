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
import plistlib, sqlite3, collections, sys, os, re, shutil, subprocess, unicodedata

CACHE_DIR = os.path.expanduser("~/.cache/tsumiki")
DB = os.path.join(CACHE_DIR, "shortcut_library.sqlite")
LIST = os.path.join(CACHE_DIR, "shortcut_strings.txt")
SRC = os.path.expanduser("~/Library/Shortcuts/Shortcuts.sqlite")
CACHE = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"
LOC = "/System/Library/PrivateFrameworks/WorkflowKit.framework/Resources/Localizable.loctable"
PAT = re.compile(r"^(is\.workflow\.actions\.[a-z0-9.]+|WF[A-Za-z]+|Repeat (Item|Index))$")

# 実測で意味を確定させた定数（実動4本から裏取り）。99 は実動3件あるが意味は未確定。
COND = {0: "より小さい", 1: "以下", 2: "より大きい", 3: "以上", 4: "等しい",
        99: "含む（タグ。Mac実測 2026-10-05：固定タグの架空1件だけが入った）",
        999: "含まない（タグ。Mac実測 2026-10-05：固定タグの架空1件だけが外れた）", 1003: "範囲内", 100: "値がある", 101: "値がない",
        1001: "過去◯以内（日付・Unit 16＝日。本人の見本 2026-09-23）"}
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
    # 2026-10-05 Mac の shortcuts run で、題名 _テスト〜 の架空データだけを使って実測（Watch・iPhone は未確認）
    ("is.workflow.actions.filter.reminders", "WFContentItemFilter"):
        ("WFContentPredicateTableTemplate", "Mac実測: 題名・未完了・期限（1001/16）で架空の2件だけが出た。"
         "Has Alarms=true で「今日・時刻なし・通知なし」の架空1件が外れ、本物（読むだけ）の時刻つき期限切れ10件は全部残った"),
    ("is.workflow.actions.filter.reminders", "WFContentItemLimitEnabled"):
        ("bool", "Mac実測: 同上（False で件数の上限なし）"),
    ("is.workflow.actions.setters.reminders", "WFInput"):
        ("WFTextTokenAttachment", "Mac実測: 繰り返しの Repeat Item で1件ずつ。一覧を丸ごと渡すと「項目を選択」で止まる"),
    ("is.workflow.actions.setters.reminders", "Mode"):
        ("str", "Mac実測: 'Set' で期限が書き換わった（loctable の ${Mode}）"),
    ("is.workflow.actions.setters.reminders", "WFContentItemPropertyName"):
        ("str", "Mac実測: 'Due Date' で期限と通知が一緒に動いた（通知センターで時刻どおりに出た）"),
    ("is.workflow.actions.setters.reminders", "WFReminderContentItemDueDate"):
        ("WFTextTokenString", "Mac実測: 日付の調整の出力を差し込んで、その時刻になった"),
    # 2026-10-05 「元に戻す」で Mac 実測（架空データ）：控えを作る→動かす→戻す→控えを消す。
    #   同じ題名で期限の違う囮・止まって残った控えのまねを置いても、動かした物だけが戻った
    ("is.workflow.actions.properties.reminders", "WFInput"):
        ("WFTextTokenAttachment", "Mac実測: Repeat Item から題名・期限が取れ、控えの題名と期限になった"),
    ("is.workflow.actions.properties.reminders", "WFContentItemPropertyName"):
        ("str", "Mac実測: 'Title'・'Due Date'・'Notes'"),
    ("is.workflow.actions.addnewreminder", "WFCalendarItemNotes"):
        ("WFTextTokenString", "Mac実測: 控えのメモに入った（DB の ZNOTES で確認）"),
    ("is.workflow.actions.setters.reminders", "WFReminderContentItemIsCompleted"):
        ("bool", "Mac実測: True で控えが完了済みになった"),
    ("is.workflow.actions.setters.reminders", "WFReminderContentItemNotes"):
        ("WFTextTokenString", "Mac実測: 'Notes' で前回の控えのメモが「使用済み」に書き換わった"),
    ("is.workflow.actions.ask", "WFAskActionDefaultAnswerDateAndTime"):
        ("WFTextTokenString", "Mac実測 2026-10-05: WFInputType 'Date and Time' で日時のつまみが出て、初めの値が差し込んだ時刻（今+1時間）になった"),
    ("is.workflow.actions.removereminders", "WFInputReminders"):
        ("WFTextTokenAttachment", "Mac実測: 探した架空の物だけが削除の確認に並び、消えた"),
}

def die(msg, code=2):
    print(msg)
    sys.exit(code)

# --ref <署名前の plist> … ライブラリに無いアクションの実動例として足す（公開ショートカットの記録など）。
#   出どころは呼ぶ側が控えておく（例: build_health_shortcut.py の REF）。何本でも。
# --self <名前> … 自分の台本が作って取り込んだショートカット。実例から外す（自作を自作で照合しない）。
#   名前が「_テスト」で始まる物は、指定がなくてもいつも外す。何本でも。
args, REFS, SELF = [], [], set()
_it = iter(sys.argv[1:])
for _a in _it:
    if _a == "--ref":
        REFS.append(next(_it, ""))
    elif _a == "--self":
        SELF.add(unicodedata.normalize("NFC", next(_it, "")))
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
# 2026-10-05: 自作のテスト版を取り込んだら、その中身が「実例」に数えられて ✗ 0 が出た（反証役の指摘）
_excluded = collections.Counter()
for (data, sname) in sqlite3.connect(DB).execute(
        "select a.ZDATA, s.ZNAME from ZSHORTCUTACTIONS a left join ZSHORTCUT s on a.ZSHORTCUT = s.Z_PK"):
    if not data:
        continue
    sname = unicodedata.normalize("NFC", sname or "")
    # 取り込み直すと「名前 1」のように数字が付く。後ろの「 数字」を落として比べる
    if sname.startswith("_テスト") or re.sub(r"\s+\d+$", "", sname) in SELF:
        _excluded[sname] += 1
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

if _excluded:
    print(f"  － 自作なので実例から外した: {'・'.join(sorted(_excluded))}")

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

# 探す条件の項目名（ContentKit の文言表の「(Content Property Name)」）
PROPS = set()
_ck = "/System/Library/PrivateFrameworks/ContentKit.framework/Versions/A/Resources/Localizable.loctable"
if os.path.exists(_ck):
    for _k in (plistlib.load(open(_ck, "rb")).get("en") or {}):
        if _k.endswith(" (Content Property Name)"):
            PROPS.add(_k[: -len(" (Content Property Name)")])

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
        if k not in lib.get(i, ()) and k not in sysstr and (i, k) not in VERIFIED:
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
        # ③' 探す条件（filter.*）の中身。Operator と Property まで降りる
        if isinstance(v, dict) and v.get("WFSerializationType") == "WFContentPredicateTableTemplate":
            for t in (v.get("Value") or {}).get("WFActionParameterFilterTemplates") or []:
                op, prop = t.get("Operator"), t.get("Property")
                if op not in COND:
                    ng.append(f"#{n} {i} の条件 {prop}：Operator {op} は意味が分かっていない値")
                else:
                    print(f"  ・#{n} 条件 {prop} の Operator={op} → 「{COND[op]}」")
                if prop not in PROPS:
                    ng.append(f"#{n} {i} の条件：Property '{prop}' は ContentKit の項目名に無い")
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
