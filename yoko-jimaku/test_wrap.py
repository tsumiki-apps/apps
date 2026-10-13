"""字幕の折り返しの検査：言葉の途中で改行していないか・幅に収まるかを確かめる。

    ../douga-sync/.venv/bin/python test_wrap.py            # 下の例文で検査
    ../douga-sync/.venv/bin/python test_wrap.py job.json   # 作業の字幕（captions）で検査（読むだけ）

判定は折る仕組み（engine.breaks）とは別に、形態素解析で独立に見る：
  ・折った所が言葉（形態素）の途中でない
  ・英字・数字の続き（Intelligence・iPhone18Pro・1.48）の中でない
  ・カタカナ語（ノイズキャンセリング）・「◯◯する」・「について」などの言い回しの中でない
  ・次の行が助詞・助動詞・接尾辞・小さい字・のばす棒・句読点で始まらない
  ・どの行も札の幅に収まる
"""
import json
import sys

import engine

SAMPLES = [
    "ありがとうございますそうなんですそうなんです",
    "今まで確かにポートレートモードっていうのはあったんですよ",
    "それがApple Intelligenceで後からでも今できるんです",
    "実際にSeries 12とUltra 4とSE 3の3機種がありますので",
    "一応ここのテーブルにもですね全機種あと色もですね確認できるようになってますので",
    "引き続きちょっとお試しくださいませ",
    "いい写真撮れたなぁと思っても、後からもうちょっとだけ角度変えたら",
    "よかったなとか、撮っておいたらよかったなって思うことありますよね",
    "これで3つのApple Intelligenceの編集メニュー出て",
    "iPhone18Proの可変絞りについてご紹介します",
    "1.48と4.0の違いを見ていただきたいんですね",
    "バックグラウンドで心拍数の計測をしてくれてはいたんですけれども",
    "今回はですね5秒に1回のペースで測ってくれるようになってますし",
    "決まった方はですね僕の方に伝えていただきましたら隣のテーブルで",
    "背景のぼかし具合っていうのがちょっと切り替わったかなと思います",
    "こちらのiPadを使っていただきますと比較するというところもありますので",
    "こんな風にしてリフレームタップすると画像生成をしてくれています",
    "新しいスケジュール帳アプリでは予定をまとめて確認できます",
    "AirPods Pro 3のノイズキャンセリングをお試しください",
    "画面の右上から下にスワイプしてコントロールセンターを開きます",
    "実際にSE 3の3機種と5秒に1回のペースで約2.5倍速く測れます",
    "お値段は一九万八千円からで、お客様にとってより使いやすくなるようにということで改善されました",
    "Apple Intelligence Writing Tools Image Playground Genmoji などが使えます",
]


def _kata(ch):
    return 0x30A1 <= ord(ch) <= 0x30FA or ch in "ーヽヾ・"


def prev_q(ms, pos):
    return next((m[3] for m in ms if m[1] == pos), "")


def prev_pos(ms, pos):
    return next((m[2] for m in ms if m[1] == pos), "")


def joined_has_space(joined, lines, k):
    """元の文で、この改行の所に空白があったか（英単語の間の改行は正しい）。"""
    head = "".join(l.replace(" ", "") for l in lines[:k])
    n = 0
    for i, ch in enumerate(joined):
        if ch != " ":
            n += 1
        if n == len(head):
            return i + 1 < len(joined) and joined[i + 1] == " "
    return False


def check(text):
    """問題のリスト（空なら合格）。"""
    lines = engine.wrap(text)
    probs = []
    joined = " ".join(text.split())
    if "".join(lines).replace(" ", "") != joined.replace(" ", ""):
        probs.append("字が欠けた・増えた")
    ms = engine._morphs(joined.replace(" ", ""))
    starts = {m[0] for m in ms}
    flat, pos = joined.replace(" ", ""), 0
    for k, ln in enumerate(lines):
        if engine._tw(ln) > engine.CAP_MAXW * engine.CAP_SQUEEZE:
            probs.append(f"{k + 1}行目がはみ出す")
        if k == 0:
            pos += len(ln.replace(" ", ""))
            continue
        a, b = flat[pos - 1], flat[pos]
        m = next((m for m in ms if m[0] == pos), None)
        if joined_has_space(joined, lines, k):
            pass                      # 元の文の空白で折った（英単語の間）＝正しい
        elif pos not in starts:
            probs.append(f"言葉の途中で改行「{flat[max(0, pos - 4):pos]}｜{flat[pos:pos + 4]}」")
        elif engine._alnum(a) and engine._alnum(b):
            probs.append(f"英数字の途中で改行「{a}｜{b}」")
        elif _kata(a) and _kata(b):
            probs.append(f"カタカナ語の途中で改行「{flat[max(0, pos - 4):pos]}｜{flat[pos:pos + 4]}」")
        elif (flat[pos - 1].isdigit() or prev_q(ms, pos) == "数詞") and m and m[2] in ("名詞", "接尾辞"):
            probs.append(f"数字と単位の間で改行「{flat[max(0, pos - 4):pos]}｜{flat[pos:pos + 4]}」")
        elif m and m[2] == "動詞" and m[4] in ("為る", "出来る") and prev_pos(ms, pos) == "名詞":
            probs.append(f"「◯◯する」の途中で改行「{flat[max(0, pos - 4):pos]}｜{flat[pos:pos + 4]}」")
        elif m and m[2] == "動詞" and flat[pos - 1] in "にと" and flat[pos:pos + 2] in ("つい", "よっ", "対し", "おい", "して"):
            probs.append(f"決まった言い回しの途中で改行「{flat[max(0, pos - 4):pos]}｜{flat[pos:pos + 4]}」")
        elif m and (m[2] in ("助詞", "助動詞", "接尾辞")) and a not in engine.PUNCT:
            probs.append(f"{m[2]}で始まる行「{ln[:6]}」")
        elif b in "ーっゃゅょぁぃぅぇぉッャュョァィゥェォ、。！？!?":
            probs.append(f"行頭に来てはいけない字「{ln[:6]}」")
        pos += len(ln.replace(" ", ""))
    return lines, probs


def main():
    if len(sys.argv) > 1:
        texts = [c["text"] for c in json.load(open(sys.argv[1])).get("captions", [])]
    else:
        texts = SAMPLES
    bad = 0
    for t in texts:
        lines, probs = check(t)
        mark = "NG" if probs else "OK"
        bad += bool(probs)
        print(f"{mark}  {' ｜ '.join(lines)}" + (f"   ← {'・'.join(probs)}" if probs else ""))
    print(f"\n{len(texts)} 件中 NG {bad} 件")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
