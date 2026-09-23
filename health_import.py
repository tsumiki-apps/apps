#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""health_import.py — iPhone の「ヘルスケアを書き出す」の zip から、からだ帳（health.html）用の日ごとの値を作って入れる。

使い方:
  python3 health_import.py [<書き出したデータ.zip または export.xml>] [--days 400] [--upload]
  引数を省くと ~/Downloads の「書き出したデータ*.zip」「export*.zip」のいちばん新しいものを使う。
  --upload を付けると Supabase の health_daily に入れる（同じ日・同じ指標は上書き＝何度流しても同じ結果）。

出すもの（~/.cache/tsumiki/health_rows.json・0600）: [{"d":"2026-09-23","m":"sleep","v":230}, ...]
  sleep     … その日の朝に目覚めた「いちばん長いひと続きの眠り」の、眠っていた分（コア・深い・レム・区別なし）。
               すき間が3時間以内の記録は同じ眠りとしてまとめてから、**終わった日の日付**に付ける
               （0時をまたぐ夜が前の日と今日に割れない）。昼寝は別のまとまりになるので足されない。
               時計の段階つきがあるまとまりでは iPhone の「区別なし」を使わない（起きていた時間まで埋めるため）。
  hrv       … 心拍変動 SDNN の日平均（ms）
  rhr       … 安静時心拍数の日平均（ヘルスケアの「平均」と同じ）
  exercise  … エクササイズ時間の合計（分）
  vo2       … 心肺機能（その日の最後の値）
  weight    … 体重 kg（lb なら換算）
  walk      … 歩行速度の日平均（km/h）

⚠️ 出力には本人の健康データが入る。**git の管理下（PUBLIC リポジトリ）には書かない**（書こうとすると止まる）。
   値は画面にも出さない（件数と期間だけ）。入れるときも Claude のツールを通さず、この台本から直接送る
   （会話の記録に数字が残らない）。鍵はキーチェーン supabase-mcp から読み、curl には標準入力で渡す。
   端末名（「◯◯のApple Watch」）などの sourceName は読まない。
"""
import sys, os, zipfile, json, pathlib, argparse, subprocess, tempfile, unicodedata
import datetime as dt, xml.etree.ElementTree as ET
from collections import defaultdict

HOME = pathlib.Path.home()
PROJECT_REF = "okbjqtdirrathscctyvx"
MGMT = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
GAP = dt.timedelta(hours=3)          # これ以内のすき間は同じ眠り
MIN_SLEEP = 30                       # 30分未満のまとまりは数えない
ASLEEP = {"HKCategoryValueSleepAnalysisAsleepCore", "HKCategoryValueSleepAnalysisAsleepDeep",
          "HKCategoryValueSleepAnalysisAsleepREM", "HKCategoryValueSleepAnalysisAsleepUnspecified",
          "HKCategoryValueSleepAnalysisAsleep"}
UNSPEC = "HKCategoryValueSleepAnalysisAsleepUnspecified"
Q = {
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": ("hrv", "mean"),
    "HKQuantityTypeIdentifierRestingHeartRate": ("rhr", "mean"),
    "HKQuantityTypeIdentifierAppleExerciseTime": ("exercise", "sum"),
    "HKQuantityTypeIdentifierVO2Max": ("vo2", "last"),
    "HKQuantityTypeIdentifierBodyMass": ("weight", "last"),
    "HKQuantityTypeIdentifierWalkingSpeed": ("walk", "mean"),
}
nfc = lambda s: unicodedata.normalize("NFC", s)


def ts(s):
    # 例: 2026-09-23 04:45:00 +0900 → 書かれている時差のまま（その土地の日付で数える）
    return dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z")


def find_default():
    d = HOME / "Downloads"
    c = [p for p in d.iterdir() if p.suffix.lower() == ".zip"
         and (nfc(p.name).startswith("書き出したデータ") or p.name.lower().startswith("export"))]
    if not c:
        sys.exit("~/Downloads に書き出したデータの zip が見つかりません。パスを渡してください。")
    return max(c, key=lambda p: p.stat().st_mtime)


def open_xml(path):
    path = pathlib.Path(path)
    if path.suffix.lower() == ".zip":
        z = zipfile.ZipFile(path)
        ok = ("export.xml", "書き出したデータ.xml")
        name = next((n for n in z.namelist() if nfc(n).rsplit("/", 1)[-1] in ok), None)
        if not name:
            sys.exit("zip の中に export.xml（書き出したデータ.xml）がありません。")
        return z.open(name)
    return open(path, "rb")


def union_minutes(spans):
    """重なっている区間を1本にまとめてから、合計の分を返す"""
    total, cs, ce = 0.0, None, None
    for s, e in sorted(spans):
        if ce is None or s > ce:
            if ce is not None:
                total += (ce - cs).total_seconds() / 60
            cs, ce = s, e
        elif e > ce:
            ce = e
    if ce is not None:
        total += (ce - cs).total_seconds() / 60
    return total


def sleep_sessions(spans):
    """[(start, end, staged)] → [(終わった時刻, 眠っていた分)]。すき間が GAP 以内なら同じ眠り"""
    groups, cur, cur_end = [], [], None
    for sp in sorted(spans):
        if cur and sp[0] - cur_end > GAP:
            groups.append(cur); cur, cur_end = [], None
        cur.append(sp)
        cur_end = sp[1] if cur_end is None else max(cur_end, sp[1])
    if cur:
        groups.append(cur)
    res = []
    for ses in groups:
        if any(st for _, _, st in ses):
            ses = [x for x in ses if x[2]]
        mins = union_minutes([(a, b) for a, b, _ in ses])
        if mins >= MIN_SLEEP:
            res.append((max(b for _, b, _ in ses), mins))
    return res


def build(src, days):
    since = dt.date.today() - dt.timedelta(days=days)
    vals = defaultdict(list)          # (metric, day) -> [(time, value)]
    spans = []                        # 眠っていた区間（全部）
    n_rec = 0
    root = None
    for ev, el in ET.iterparse(src, events=("start", "end")):
        if ev == "start":
            if root is None:
                root = el
            continue
        if el.tag != "Record":
            if el.tag in ("Workout", "ActivitySummary", "Correlation"):
                root.clear()
            continue
        n_rec += 1
        t = el.get("type")
        if t == "HKCategoryTypeIdentifierSleepAnalysis" and el.get("value") in ASLEEP:
            s, e = ts(el.get("startDate")), ts(el.get("endDate"))
            if e.date() >= since - dt.timedelta(days=1):
                spans.append((s, e, el.get("value") != UNSPEC))
        elif t in Q:
            m, _ = Q[t]
            s = ts(el.get("startDate"))
            if s.date() >= since:
                try:
                    v = float(el.get("value"))
                except (TypeError, ValueError):
                    root.clear(); continue
                u = el.get("unit") or ""
                if m == "weight" and u == "lb":
                    v *= 0.45359237
                if m == "walk" and u == "m/s":
                    v *= 3.6
                vals[(m, s.date())].append((s, v))
        root.clear()          # 読み終えた記録を木から外す（数GBの書き出しでもメモリが増えない）

    rows = []
    best = {}                         # 起きた日 -> いちばん長い眠り
    for end, mins in sleep_sessions(spans):
        d = end.date()
        if d >= since and mins > best.get(d, 0):
            best[d] = mins
    for d, mins in best.items():
        rows.append({"d": d.isoformat(), "m": "sleep", "v": round(mins)})
    how = {m: h for m, h in Q.values()}
    for (m, day), lst in vals.items():
        lst.sort()
        v = {"mean": lambda a: sum(x for _, x in a) / len(a),
             "sum": lambda a: sum(x for _, x in a),
             "last": lambda a: a[-1][1]}[how[m]](lst)
        rows.append({"d": day.isoformat(), "m": m, "v": round(v, 1)})
    rows.sort(key=lambda r: (r["d"], r["m"]))
    return rows, n_rec


def in_git(p):
    for d in [p, *p.parents]:
        if (d / ".git").exists():
            return d
    return None


def write_private(path, text):
    """最初から 0600 で作る（書いた直後の一瞬も他人に読めない）"""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, 0o600)


def get_pat():
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "supabase-mcp", "-w"],
                       capture_output=True, text=True, timeout=10)
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("キーチェーン（supabase-mcp）から鍵を読めませんでした。")
    return r.stdout.strip()


def upload(rows):
    """管理APIで health_daily に入れる。値は SQL に数値として埋める（文字は日付と決まった指標名だけ）"""
    ok_m = {m for m, _ in Q.values()} | {"sleep"}
    pat, sent = get_pat(), 0
    tmpdir = HOME / ".cache/tsumiki"
    for i in range(0, len(rows), 500):
        chunk = rows[i:i + 500]
        parts = []
        for r in chunk:
            dt.date.fromisoformat(r["d"])                   # 日付の形でなければここで落ちる
            if r["m"] not in ok_m:
                raise ValueError("unknown metric")
            parts.append(f"('{r['d']}','{r['m']}',{float(r['v'])},'export',now())")
        sql = ("insert into public.health_daily(day,metric,value,source,updated_at) values "
               + ",".join(parts)
               + " on conflict (day,metric) do update set value=excluded.value, source=excluded.source, updated_at=now();")
        body = tmpdir / f"health_upload_{os.getpid()}_{i}.json"
        write_private(body, json.dumps({"query": sql}))
        try:
            cfg = f'header = "Authorization: Bearer {pat}"\n'
            r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-K", "-",
                                "-X", "POST", MGMT, "-H", "Content-Type: application/json",
                                "--data-binary", "@" + str(body)],
                               input=cfg, capture_output=True, text=True, timeout=120)
        finally:
            body.unlink(missing_ok=True)
        code = r.stdout.strip()
        if code not in ("200", "201"):
            sys.exit(f"入れられませんでした（HTTP {code}）。{sent}件までは入っています。")
        sent += len(chunk)
    return sent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?")
    ap.add_argument("--days", type=int, default=400)
    ap.add_argument("--out", default=str(HOME / ".cache/tsumiki/health_rows.json"))
    ap.add_argument("--upload", action="store_true")
    a = ap.parse_args()
    out = pathlib.Path(a.out).expanduser().resolve()
    repo = in_git(out.parent)
    if repo:
        sys.exit(f"出力先が git の管理下です（{repo}）。~/.cache/tsumiki/ などにしてください。")
    src = a.src or find_default()
    rows, n = build(open_xml(src), a.days)
    write_private(out, json.dumps(rows, ensure_ascii=False))
    by = defaultdict(int)
    for r in rows:
        by[r["m"]] += 1
    days = sorted({r["d"] for r in rows})
    print(f"読んだ記録 {n}件 → 日ごとの値 {len(rows)}件（{days[0] if days else '-'} 〜 {days[-1] if days else '-'}）")
    print("  " + " / ".join(f"{k} {v}日" for k, v in sorted(by.items())))
    print(f"  書き出し先: {out}")
    if a.upload:
        print(f"  入れた: {upload(rows)}件（health_daily）")


if __name__ == "__main__":
    main()
