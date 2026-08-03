#!/usr/bin/env python3
"""配布用リポジトリ（~/tsumiki-tools → tools.tsumiki-apps.com）へのデプロイ。

個人用つみき（apps リポ）とは置き場を分けている：
  - 人に渡すツール → tsumiki-tools（このスクリプトでデプロイ）
  - 自分・家族用   → apps（従来どおり deploy.command / git push）

使い方:
  python3 deploy_tools.py kouban   # 香盤メーカーをビルドして配布リポへ push
  python3 deploy_tools.py          # 登録済み全ツールをデプロイ

新しい配布ツールを増やすときは TOOLS に1エントリ足すだけ。
※ 配布リポには個人データ・個人プロジェクトのデータに届くSupabase接続を置かないこと。
   （例外＝プロダクトキーゲート: 非公開台帳へのRPC照合のみで個人データに届かないため可。
    有料ツールは TOOLS エントリに license='<app名>' を足すと inject_license.py のゲートを
    毎デプロイで注入する。詳細 Decisions/2026-07-23-license-key-system.md）
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
    #       out=配布ファイル名 / icon=apple-touch-icon / title=ホーム画面名 /
    #       license=プロダクトキーゲートのapp名（有料ツールのみ・不要なら省略）
    # mazeiro/dakoku 等の単一HTMLはここに載せない：本体は ~/tsumiki-tools/ を直接編集して
    # git push する運用（2026-07-23決定）。制作物側に開発ソースを持たない。

    # 香盤メーカー（鍵つき）。2026-07-27にライセンス一本化し、無料版 kouban.html は廃止。
    # 香盤はこの kouban-pro（license='kouban'）へ一本化。購入者にURL＋キーを配布。
    'kouban-pro': {
        'build': ['npm', '--prefix', str(SEISAKU / 'Kouban'), 'run', 'build'],
        'artifact': SEISAKU / 'Kouban' / 'dist' / 'index.html',
        'out': 'kouban-pro.html',
        'icon': SEISAKU / 'icons' / 'icon-kouban.png',
        'title': '香盤メーカー',
        'license': 'kouban',
    },

    # てっぱりボード（鍵つき）。お客様向けに 2026-07-31 新規作成。
    # 香盤メーカーと役割が違う：こちらは「その日どの場の稽古ができるか」専用。
    # 公演データ（役24・場面23・稽古日26・NG）は本体に同梱している。
    'teppari': {
        'build': ['npm', '--prefix', str(SEISAKU / 'Teppari'), 'run', 'build'],
        'artifact': SEISAKU / 'Teppari' / 'dist' / 'index.html',
        'out': 'teppari-board.html',
        'icon': SEISAKU / 'icons' / 'icon-teppari.png',
        'title': 'てっぱりボード',
        'license': 'teppari',
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
    # apps側を案内ページに差し替えた後、TOOLSのartifactを直し忘れると
    # 公開中の本体を案内ページで上書きしてしまう。ここで止める。
    assert '引っ越しました' not in html, (
        f'{name}: artifact が「引っ越しました」案内ページになっている。'
        '本体の場所を TOOLS に登録し直すこと（デプロイ中止）'
    )
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
    # 有料ツール: プロダクトキーゲートを注入（再ビルドでゲートを失わないよう毎回）
    if 'license' in t:
        import inject_license
        html = inject_license.BLOCK_RE.sub('', html)
        html = html.replace('</body>', inject_license.build_snippet(t['license']) + '\n</body>', 1)
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
