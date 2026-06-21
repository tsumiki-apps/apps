#!/usr/bin/env python3
"""日報メール生成＆送信スクリプト（GitHub Actions用）。

対象日（日本時間）の git コミットを集計し、Kodai指定フォーマットの日報を作って
Gmail SMTP で本人宛に送信する。AIは使わず、コミットメッセージを読みやすく整形する。

■ 重要：対象日の決め方（空振りバグ対策）
GitHubの定時実行(cron)は混雑で数時間遅れることが多く、23:30 JST 予定の実行が
実際には「翌朝(04:00〜07:30 JST)」に動く。その瞬間の now で「今日」を決めると
"もう次の日" を見てしまい、前日の作業を丸ごと取りこぼして「何もしませんでした」に
なっていた。そこで実行時刻の「時」で判定し、深夜〜昼前(< CUTOFF時)に動いた場合は
「前日」を対象日とする。これで定時実行でも遅延実行でも同じ正しい日を集計できる。

必要な環境変数（GitHub Secrets で設定）:
    SMTP_USER          送信元Gmailアドレス（例: kodai.20030112@gmail.com）
    SMTP_APP_PASSWORD  Googleアプリパスワード（16文字）
    MAIL_TO            宛先（未設定なら SMTP_USER と同じ）

リポジトリは fetch-depth: 0 でチェックアウトされている前提（git log を全部読むため）。
"""
import os
import smtplib
import subprocess
import sys
from datetime import datetime, timedelta
from email.message import EmailMessage
from zoneinfo import ZoneInfo

JST = ZoneInfo("Asia/Tokyo")

# 実行時刻の「時(JST)」がこの値より小さければ「遅延実行＝前日分」と判定する。
# 23:30 予定の実行が早朝に流れても、18時より前なら確実に前日が対象。
# （cronは予定より早くは動かないので、同じ日の18時より前に動くことはない）
CUTOFF_HOUR = 18

# 曜日の日本語表記（月=0 … 日=6）
JP_WEEKDAYS = ["月", "火", "水", "木", "金", "土", "日"]


def get_target_date(now=None):
    """集計対象の日付(JSTのdate)を返す。深夜〜昼前の実行は前日扱い。"""
    now = now or datetime.now(JST)
    if now.hour < CUTOFF_HOUR:
        return (now - timedelta(days=1)).date()
    return now.date()


def get_commits_for(target_date):
    """target_date(JST)に作られたコミットを (datetime, 件名) のリストで返す。"""
    # 対象日の前後に余裕を持って取り出し、JSTの日付で厳密に絞る
    result = subprocess.run(
        [
            "git", "log",
            "--since=3 days ago",
            "--no-merges",
            "--pretty=format:%aI\x1f%s",
        ],
        capture_output=True, text=True,
    )
    commits = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or "\x1f" not in line:
            continue
        aiso, subject = line.split("\x1f", 1)
        try:
            dt = datetime.fromisoformat(aiso).astimezone(JST)
        except ValueError:
            continue
        if dt.date() == target_date:
            commits.append((dt, subject.strip()))
    commits.sort(key=lambda x: x[0])
    return commits


def split_category(subject):
    """件名を (カテゴリ, 本文) に分ける。先頭の「◯◯:」「◯◯：」をカテゴリ扱い。"""
    for sep in ("：", ":"):
        if sep in subject:
            head, tail = subject.split(sep, 1)
            head, tail = head.strip(), tail.strip()
            # カテゴリは短い見出し想定（長すぎる＝ただの文章なら分けない）
            if head and tail and len(head) <= 20:
                return head, tail
    return None, subject


def build_body(target_date, commits):
    wd = JP_WEEKDAYS[target_date.weekday()]
    date_label = f"{target_date.month}/{target_date.day}（{wd}）"

    if not commits:
        return (
            f"📋 {date_label}の日報\n\n"
            "今日はおやすみでした。\n"
            "ゆっくり休んでね😊\n"
        )

    n = len(commits)
    # 見出し（箇条書き）＝やったこと、その下の行＝どのアプリ・何時か、の2行1セット。
    # 改行を多めにして読みやすく。
    lines = [
        f"📋 {date_label}の日報",
        "",
        f"今日は {n} 件のサポートをしました ✨",
        "",
    ]
    for dt, subject in commits:
        cat, body = split_category(subject)
        meta = f"{cat} ｜ {dt.strftime('%H:%M')}" if cat else dt.strftime("%H:%M")
        lines.append(f"・{body}")
        lines.append(f"　{meta}")
        lines.append("")

    lines.append("おつかれさまでした😊")
    return "\n".join(lines).rstrip() + "\n"


def main():
    smtp_user = (os.environ.get("SMTP_USER") or "").strip()
    app_password = (os.environ.get("SMTP_APP_PASSWORD") or "").strip()
    to_addr = (os.environ.get("MAIL_TO") or smtp_user).strip()

    if not smtp_user or not app_password:
        print("ERROR: SMTP_USER / SMTP_APP_PASSWORD が未設定です（GitHub Secretsを確認）", file=sys.stderr)
        return 1

    now = datetime.now(JST)
    target_date = get_target_date(now)
    commits = get_commits_for(target_date)
    body = build_body(target_date, commits)

    print(f"[daily-report] now={now:%Y-%m-%d %H:%M} JST / target={target_date} / commits={len(commits)}")
    print("---- body preview ----")
    print(body)
    print("----------------------")

    msg = EmailMessage()
    msg["Subject"] = f"📋 日報 {target_date}"
    msg["From"] = smtp_user
    msg["To"] = to_addr
    msg.set_content(body)

    try:
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as server:
            server.login(smtp_user, app_password)
            server.send_message(msg)
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: 送信失敗: {e}", file=sys.stderr)
        return 1

    print("SENT_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
