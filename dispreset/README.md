# ディスプレイ配置プリセット

iPad mini（BetterDisplay の仮想ディスプレイ + Sidecar）の配置を、
名前をつけて保存し、ボタンひとつで元に戻すための道具。

繋ぎ直すたびにシステム設定 > ディスプレイでドラッグし直す作業をなくすのが目的。

## 使い方

`~/Applications/ディスプレイ配置.app` をダブルクリック（Dock に入れておくと1クリック）。

- 保存済みの配置が一覧で出る → 選んで「この配置に戻す」
- **＋ いまの配置を新しく保存…** → 名前をつけて今の配置を保存（家、カフェ、会社 など）
- **✏️ プリセットの名前を変更…** → 名前だけ付け替える（配置の中身はそのまま）
- **🗑 プリセットを削除…** → いらなくなった配置を消す
- **🔄 iPad接続時の自動復元：オン/オフ** → クリックで切り替え

## 自動復元

オンにすると、iPad を繋いだとき **最後に使ったプリセット**の配置に自動で戻る。
「最後に使った」＝最後に「この配置に戻す」を実行したもの。カフェで `カフェ` を選んだら、
以降は `カフェ` が自動復元の対象になる。

暴発しないよう、こういう作りにしてある:

- 見るのは「配置」ではなく**繋がっているディスプレイIDの集合**。適用しても集合は変わらないので、
  自分の適用が次の検知を呼ぶ無限ループにならない
- **増えたときだけ**動く。iPad を外したときは何もしない
- ログイン直後は現状を覚えるだけで、いきなり適用しない
- Sidecar と仮想ディスプレイは時間差で現れるので、増加を検知しても4秒待って
  集合が安定してから一度だけ適用する

常駐しているのは `dispreset_watch.py`（launchd の `com.kodai.dispreset.watch`）。
2秒ごとに CoreGraphics でディスプレイ数を見るだけなので負荷はほぼゼロ。
ログは `~/Library/Logs/dispreset-watch.log`。

システム設定 >「一般」>「ログイン項目と機能拡張」の「バックグラウンドでの実行を許可」に
**ディスプレイ配置** という名前で出る（末尾のほう。日本語名なので一覧の下）。

> この名前を出すのは地味に手こずった。launchd に python3 を直に起動させると "python3"、
> アプリバンドルに包むと実行ファイル名（"watcher"）が出てしまう。`AssociatedBundleIdentifiers`
> でメインアプリに紐付ける正攻法も、ad-hoc 署名（開発元不明）では効かなかった。
> 最終的に、この一覧が「起動する実行ファイルの名前」をそのまま出すことを利用し、
> `ディスプレイ配置` という名前の署名不要なランチャースクリプト経由で python3 を起動している。
> 実際の表示名は `sfltool dumpbtm | grep -B7 kodai.dispreset` の `Name:` で確認できる。

新しい場所で配置を整えたら、その都度「新しく保存」で足していく。

## 中身

| ファイル | 役割 |
|---|---|
| `dispreset.py` | エンジン。`displayplacer` を呼んで配置を読み書きする |
| `dispreset_watch.py` | 常駐役。iPad が繋がったのを検知して自動復元する |
| `ディスプレイ配置` | 常駐役を起動する薄いランチャースクリプト（`watch-on` が自動生成） |
| `ディスプレイ配置.applescript` | アプリのUI（一覧・保存・削除のダイアログ） |
| `build.sh` | `.applescript` から `~/Applications/ディスプレイ配置.app` を作り直す |
| `ディスプレイ配置.icns` | アプリのアイコン |

プリセットの保存先は `~/.config/dispreset/<名前>.json`。

## ターミナルから使う場合

```bash
python3 ~/制作物/dispreset/dispreset.py list             # 一覧
python3 ~/制作物/dispreset/dispreset.py save 家           # いまの配置を保存
python3 ~/制作物/dispreset/dispreset.py apply 家          # 戻す
python3 ~/制作物/dispreset/dispreset.py rename 家 リビング  # 名前を変更
python3 ~/制作物/dispreset/dispreset.py rm 家             # 削除

python3 ~/制作物/dispreset/dispreset.py watch-on          # 自動復元をオン
python3 ~/制作物/dispreset/dispreset.py watch-off         # オフ
python3 ~/制作物/dispreset/dispreset.py watch-status      # on / off
python3 ~/制作物/dispreset/dispreset.py last              # 最後に使ったプリセット名
```

動作確認するときは `DISPRESET_DIR` で保存先を切り替えて、本物のプリセットを汚さないこと。

```bash
DISPRESET_DIR=/tmp/test python3 ~/制作物/dispreset/dispreset.py save あ
```

## 仕組みのメモ

エンジンは [displayplacer](https://github.com/jakehilborn/displayplacer)（`brew install displayplacer`）。
各画面の解像度・配置座標・回転を丸ごと記録して復元する。

再接続でディスプレイIDが変わることがあるため、各画面の**永続ID と シリアルID の両方**を保存し、
復元時にその時点で実在する方のIDへ読み替える。保存時に繋がっていた画面が今は無い場合は、
その画面だけ飛ばして残りを復元し、飛ばした画面名を通知で知らせる。

## 注意

- UI を直したら `./build.sh` を実行しないとアプリに反映されない。
- `.app` の Resources を書き換えると署名が壊れるので、`build.sh` が ad-hoc 署名をやり直している。
- このMacはスポットライトの索引が無効（`mdutil -s /` → Indexing disabled）なので、
  スポットライト検索でアプリが出ないことがある。Dock に置くのが確実。
