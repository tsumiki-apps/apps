#!/usr/bin/env python3
"""配布用リポジトリ（~/tsumiki-tools → tools.tsumiki-apps.com）へのデプロイ。

個人用つみき（apps リポ）とは置き場を分けている：
  - 人に渡すツール → tsumiki-tools（このスクリプトでデプロイ）
  - 自分・家族用   → apps（従来どおり deploy.command / git push）

使い方:
  python3 deploy_tools.py kouban   # 香盤メーカーをビルドして配布リポへ push
  python3 deploy_tools.py          # 登録済み全ツールをデプロイ

新しい配布ツールを増やすときは TOOLS に1エントリ足すだけ。
※ 配布リポには個人データ・Supabaseキー入りのものを置かないこと。
※ つみきの戻るボタン（inject_backbtn.py）は配布版には注入しない（外部の人に
   個人メニューへの導線を持たせないため）。apple-touch-icon はここで注入する。
"""

import re
import subprocess
import sys
from pathlib import Path

SEISAKU = Path(__file__).resolve().parent
TOOLS = {
    # name: build=ビルドコマンド（不要なら省略） / artifact=配布する成果物HTML /
    #       out=配布ファイル名 / icon=apple-touch-icon / title=ホーム画面名
    'kouban': {
        'build': ['npm', '--prefix', str(SEISAKU / 'Kouban'), 'run', 'build'],
        'artifact': SEISAKU / 'Kouban' / 'dist' / 'index.html',
        'out': 'kouban.html',
        'icon': SEISAKU / 'icons' / 'icon-kouban.png',
        'title': '香盤メーカー',
    },
    'mazeiro': {
        # 単一HTML（ビルドなし）。制作物の本体からコピーして配布用に整形する
        'artifact': SEISAKU / 'mazeiro.html',
        'out': 'mazeiro.html',
        'icon': SEISAKU / 'icons' / 'icon-mazeiro.png',
        'title': 'まぜいろ',
    },
}
DEST = Path.home() / 'tsumiki-tools'

BACK_BTN_RE = re.compile(
    r'\s*<!-- tsumiki-back-button -->.*?<!-- /tsumiki-back-button -->', re.S
)


def deploy(name: str) -> None:
    t = TOOLS[name]
    if 'build' in t:
        print(f'== {name}: build')
        subprocess.run(t['build'], check=True)
    html = t['artifact'].read_text()
    icon_name = t['icon'].name
    # つみきへ戻る導線は配布版に持ち込まない
    html = BACK_BTN_RE.sub('', html)
    assert 'tsumiki-back-button' not in html, '戻るボタンを剥がしきれていない'
    # アイコン参照を tools 直下に付け替え／未注入なら注入する
    html = html.replace(f'icons/{icon_name}', icon_name)
    if 'apple-touch-icon' not in html:
        tag = (
            f'<link rel="apple-touch-icon" href="{icon_name}">\n'
            f'<meta name="apple-mobile-web-app-title" content="{t["title"]}">\n'
        )
        html = html.replace('<title>', tag + '<title>', 1)
    (DEST / t['out']).write_text(html)
    (DEST / icon_name).write_bytes(t['icon'].read_bytes())
    print(f'== {name}: copied to {DEST / t["out"]}')


def main() -> None:
    names = sys.argv[1:] or list(TOOLS)
    for n in names:
        if n not in TOOLS:
            sys.exit(f'unknown tool: {n}（TOOLS に登録してから使う）')
        deploy(n)
    subprocess.run(['git', '-C', str(DEST), 'add', '-A'], check=True)
    r = subprocess.run(
        ['git', '-C', str(DEST), 'commit', '-m', f'更新: {", ".join(names)}'],
    )
    if r.returncode == 0:
        subprocess.run(['git', '-C', str(DEST), 'push'], check=True)
        print('== pushed（数分で公開URLに反映）')
    else:
        print('== 変更なし（push しない）')


if __name__ == '__main__':
    main()
