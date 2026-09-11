#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
caption_check.py — つみきIGのキャプション（投稿文）を、決まりに照らして検査する

つかいかた:
    python3 caption_check.py <文面.md>                 # md の ``` ブロックを1件ずつ見る
    python3 caption_check.py <文面.txt>                # ファイル全体を1件として見る
    python3 caption_check.py <ファイル> --names "実名,店名"   # 公開してはいけない固有名詞も探す

出力:
    ✗ … 決まり違反（1件でもあると終了コード1）
    △ … 確認してほしいところ（終了コードには影響しない）

決まりの正本:
    ~/.claude/skills/tsumiki-ig-post/SKILL.md の「キャプション」
    ~/つみき出力/Instagram運用/つみきIG_キャプションのテンプレ_2026-09-11.md

⚠️ このファイルは ~/制作物/skills/ に控えとして写る（PUBLIC）。実在の名前はここに書かず、--names で渡す。
"""

import argparse
import re
import sys

MAX_FIRST = 30        # 1行目はこれを超えたら ✗（目安は25字前後）
SOFT_FIRST = 25
MAX_TAGS = 5          # Instagram の上限（2025年12月から）
MAX_EMOJI = 6         # 締めを含めて4〜5個が目安。これを超えたら ✗
MAX_LEN = 2200        # Instagram の上限

NG_WORDS = ["小さな", "ちょっとした", "事務仕事", "タップだけで", "AIで", "安く作れ", "Apple", "アップル"]
KANJI_HINTS = {r"いま(?![すせ])": "今", r"いちばん": "一番", r"ほかの": "他の", r"あとで": "後で"}
CLOSE_PLACEHOLDER = "〔共通の締め〕"

EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF☀-➿⬀-⯿⏩-⏺⌚⌛]"
)


def captions_from(path):
    text = open(path, encoding="utf-8").read()
    if path.endswith(".md"):
        blocks = re.findall(r"```[^\n]*\n(.*?)```", text, re.S)
        return [b for b in blocks]
    return [text]


def check(cap, names):
    bad, warn = [], []
    body = cap.strip("\n")
    lines = body.split("\n")
    first = lines[0].strip() if lines else ""

    n = len(re.sub(r"[\s️]", "", EMOJI.sub("", first)))   # 絵文字と空白は数えない
    if n > MAX_FIRST:
        bad.append(f"1行目が{n}字（{MAX_FIRST}字まで）")
    elif n > SOFT_FIRST:
        warn.append(f"1行目が{n}字（目安は{SOFT_FIRST}字前後）")

    if "！" in body or "!" in body:
        bad.append("「！」が入っている（コールドの文体では使わない）")

    for w in NG_WORDS:
        if w in body:
            bad.append(f"言わない言葉「{w}」")

    for nm in names:
        if nm and nm in body:
            bad.append(f"公開しない名前「{nm}」")

    for pat, kanji in KANJI_HINTS.items():
        hits = re.findall(pat, body)
        if hits:
            warn.append(f"「{hits[0]}」→「{kanji}」にできないか")

    tags = re.findall(r"#[^\s#]+", body)
    if len(tags) > MAX_TAGS:
        bad.append(f"タグが{len(tags)}個（{MAX_TAGS}個まで）")
    elif not tags:
        warn.append("タグが0個")

    emojis = EMOJI.findall(body)
    has_close_placeholder = CLOSE_PLACEHOLDER in body
    count = len(emojis) + (1 if has_close_placeholder else 0)   # 締めの 💬 を数に含める
    if count > MAX_EMOJI:
        bad.append(f"絵文字が{count}個（{MAX_EMOJI}個まで・目安4〜5）")
    elif count == 0:
        warn.append("絵文字が0個")

    if not has_close_placeholder and not ("無料" in body and "料金" in body):
        warn.append("締め（無料の範囲と料金の目安）が見当たらない")

    if len(body) > MAX_LEN:
        bad.append(f"全体が{len(body)}字（{MAX_LEN}字まで）")

    return first, tags, count, bad, warn


def main():
    ap = argparse.ArgumentParser(description="つみきIGのキャプションを検査する")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--names", default="", help="公開してはいけない固有名詞をカンマ区切りで")
    a = ap.parse_args()
    names = [x.strip() for x in a.names.split(",") if x.strip()]

    total_bad = 0
    for path in a.files:
        caps = captions_from(path)
        print(f"■ {path}（{len(caps)}件）")
        for i, cap in enumerate(caps, 1):
            if not re.search(r"#[^\s#]+", cap) and CLOSE_PLACEHOLDER not in cap and len(cap.strip().split("\n")) <= 4:
                print(f"  {i:>2}. ・スキップ（タグのない短い部品＝締めなど）")
                continue
            first, tags, emo, bad, warn = check(cap, names)
            mark = "✗" if bad else ("△" if warn else "✓")
            print(f"  {i:>2}. {mark} {first[:28]}｜タグ{len(tags)}・絵文字{emo}")
            for b in bad:
                print(f"       ✗ {b}")
            for w in warn:
                print(f"       △ {w}")
            total_bad += len(bad)

    print(f"\n✗ {total_bad}件")
    sys.exit(1 if total_bad else 0)


if __name__ == "__main__":
    main()
