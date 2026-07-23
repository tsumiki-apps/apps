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

import subprocess
import sys
from pathlib import Path

SEISAKU = Path(__file__).resolve().parent
TOOLS = {
    # name: (ビルドコマンド, ビルド成果物, 配布ファイル名, アイコン, 表示名)
    'kouban': {
        'build': ['npm', '--prefix', str(SEISAKU / 'Kouban'), 'run', 'build'],
        'artifact': SEISAKU / 'Kouban' / 'dist' / 'index.html',
        'out': 'kouban.html',
        'icon': SEISAKU / 'icons' / 'icon-kouban.png',
        'title': '香盤メーカー',
    },
}
DEST = Path.home() / 'tsumiki-tools'


def deploy(name: str) -> None:
    t = TOOLS[name]
    print(f'== {name}: build')
    subprocess.run(t['build'], check=True)
    html = t['artifact'].read_text()
    assert 'tsumiki-back-button' not in html, '配布版に戻るボタンが混入している'
    icon_name = t['icon'].name
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
