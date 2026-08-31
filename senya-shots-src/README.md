# つみき&せんや：説明書用スクリーンショットの撮り方

`tsumiki-senya-tsukaikata.html`（使い方ページ）に貼っている実機スクショを、
**本番のデータベースにいっさい触らずに**撮り直すための道具。

## しくみ
`mkmock.py` が `~/tsumiki-tools/tsumiki-senya.html` / `tsumiki-senya-kanri.html` の
複製を作り、先頭に「ニセの通信」を差し込む。`window.fetch` を差し替えて、Supabase の
RPC には行かず、その場で作った**架空のお店・架空の9人**を返すだけ。
→ 書き込みは1回も起きない。複製のファイル名は `_テスト用_` で始まり、
`shoot.mjs` はその文字が URL に無ければ撮影を中止する（二重の安全弁）。

## 使い方
```bash
# 1. 複製を作る（出し先は作業用の空フォルダ）
python3 mkmock.py /tmp/w

# 2. その場所をローカルサーバーで出す
cd /tmp/w && python3 -m http.server 8791 &

# 3. ヘッドレスChrome を立ち上げる
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --disable-gpu --hide-scrollbars --remote-debugging-port=9334 \
  --user-data-dir=/tmp/chromeprof "--remote-allow-origins=*" about:blank &

# 4. 撮る（jall.json に「どの画面をどう撮るか」が書いてある）
node shoot.mjs /tmp/shots jall.json

# 5. 軽くして senya-shots/ へ
python3 - <<'PY'
import glob,os
from PIL import Image
for f in glob.glob('/tmp/shots/*.png'):
    Image.open(f).convert('RGB').quantize(colors=128, dither=Image.NONE)\
        .save(os.path.expanduser('~/tsumiki-tools/senya-shots/')+os.path.basename(f), optimize=True)
PY
```

## jall.json の書き方
- `app` … `staff` か `kanri`
- `q` … 複製に渡すクエリ。`scene=`（open/kime/pub/req/empty/nostaff/sending/paused、
  スタッフ側は empty/sheet/time/filled/usual/usual0/done/locked/req）、
  `tut=1`（チュートリアルを出す）、`lic=1`（プロダクトキー画面）、`anon=1`（ログイン前）、
  `a2hs=1`（ホーム画面に追加のご案内）
- `js` … 撮る前に流すコード（`openDay('2026-10-08')` など）
- `clip` … `["セレクタ"]` か `["上端","下端"]`。その範囲だけを切り出す
- `h` … 画面の高さ。`clip` が画面より下にあると撮れないので、足りなければ高くする
