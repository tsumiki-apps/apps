# -*- coding: utf-8 -*-
"""配布用アプリHTMLに「プロダクトキーゲート」を注入する。

使い方:
  python3 inject_license.py <対象HTML> <app名>
  例: python3 inject_license.py ~/tsumiki-tools/xxx.html xxx

仕組み（設計: ~/ObsidianVault/Decisions/2026-07-23-license-key-system.md）:
  - 初回だけキー入力オーバーレイ → Supabase RPC license_activate で照合 →
    端末にトークン保存（以後シームレス）。正解はHTML内に置かない。
  - 2回目以降は即アプリ表示、裏で license_verify。サーバーが明確に
    無効と答えた時だけゲート再表示。ネットワークエラー時は解錠のまま
    （オフラインでもお客様を止めない）。
  - 解錠後は右下に小さく「◯◯さま専用」の透かし（流出抑止＋パーソナライズ）。
  - 埋め込むのは公開前提のanonキーのみ。台帳テーブルは完全非公開（RLS）で、
    RPCも照合専用なので、ここから個人データには届かない。

注入方式は inject_backbtn.py と同じ: コメントマーカーで囲んだ自己完結ブロックを
</body> 直前に挿入。既にマーカーがあれば新版へ冪等に置換（app名は保持される）。
"""
import re
import sys
from pathlib import Path

MARKER = "tsumiki-license-gate"

SUPABASE_URL = "https://okbjqtdirrathscctyvx.supabase.co"
SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rYmpxdGRpcnJhdGhzY2N0eXZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjI4NTIsImV4cCI6MjA5NTg5ODg1Mn0.T-1AOK6vCD6uGdqrVGXjPui3L6WPSNrnygS-IHyfZ6Y"

SNIPPET = """<!-- tsumiki-license-gate -->
<style>
  #tsumikiLicGate{
    position:fixed; inset:0; z-index:99990;
    display:flex; align-items:center; justify-content:center;
    background:var(--paper,#F4F2EE); color:var(--ink,#242321);
    font-family:"Zen Maru Gothic",-apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;
    padding:24px; box-sizing:border-box;
  }
  #tsumikiLicGate .lic-card{ width:100%; max-width:340px; text-align:center; }
  #tsumikiLicGate .lic-kicker{
    font-size:11px; letter-spacing:.18em; color:var(--muted,#77736B); margin:0 0 6px;
  }
  #tsumikiLicGate h2{ font-size:19px; font-weight:700; margin:0 0 10px; }
  #tsumikiLicGate .lic-desc{
    font-size:13px; line-height:1.7; color:var(--muted,#77736B); margin:0 0 20px;
  }
  #tsumikiLicGate input{
    display:block; width:100%; box-sizing:border-box;
    font-size:16px; letter-spacing:.06em; text-align:center;
    padding:13px 12px; margin:0 0 12px;
    color:var(--ink,#242321); background:var(--control,#F8F7F4);
    border:1px solid var(--hair,#D8D4CC); border-radius:12px; outline:none;
    text-transform:uppercase;
  }
  #tsumikiLicGate input:focus{ border-color:var(--ghost,#BEB9B0); }
  #tsumikiLicGate button{
    display:block; width:100%; box-sizing:border-box;
    font-size:15px; font-weight:700; font-family:inherit;
    padding:14px 12px; border:none; border-radius:12px;
    background:var(--ink,#242321); color:var(--paper,#F4F2EE); cursor:pointer;
  }
  #tsumikiLicGate button:disabled{ opacity:.5; }
  #tsumikiLicGate .lic-err{
    font-size:12px; line-height:1.6; color:#9C4735; min-height:1.6em; margin:12px 0 0;
  }
  #tsumikiLicGate .lic-help{
    font-size:11px; color:var(--ghost,#BEB9B0); margin:18px 0 0;
  }
  #tsumikiLicGate .lic-help a{ color:var(--muted,#77736B); }
  #tsumikiLicMark{
    position:fixed; right:12px; bottom:10px; z-index:99980;
    font-size:10px; letter-spacing:.06em; color:var(--ghost,#BEB9B0);
    font-family:"Zen Maru Gothic",-apple-system,sans-serif;
    pointer-events:none; user-select:none; -webkit-user-select:none;
  }
</style>
<div id="tsumikiLicGate">
  <form class="lic-card" id="tsumikiLicForm">
    <p class="lic-kicker">TSUMIKI TOOLS</p>
    <h2>プロダクトキー</h2>
    <p class="lic-desc">このアプリのご利用にはプロダクトキーが必要です。お渡ししたキーを入力してください。</p>
    <input id="tsumikiLicInput" placeholder="TSUMIKI-XXXX-XXXX-XXXX"
      autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="done">
    <button id="tsumikiLicBtn" type="submit">利用をはじめる</button>
    <p class="lic-err" id="tsumikiLicErr"></p>
    <p class="lic-help">キーがわからない場合は <a href="mailto:support.tsumiki@gmail.com">support.tsumiki@gmail.com</a></p>
  </form>
</div>
<div id="tsumikiLicMark" hidden></div>
<script>
  (function(){
    var APP = '__APP__';
    var RPC = '__SUPABASE_URL__/rest/v1/rpc/';
    var KEY = '__SUPABASE_ANON__';
    var K_TOKEN = 'tsumiki-lic-token:' + APP;
    var K_CUST  = 'tsumiki-lic-customer:' + APP;
    var K_DEV   = 'tsumiki-lic-device';

    var gate = document.getElementById('tsumikiLicGate');
    var form = document.getElementById('tsumikiLicForm');
    var input = document.getElementById('tsumikiLicInput');
    var btn  = document.getElementById('tsumikiLicBtn');
    var err  = document.getElementById('tsumikiLicErr');
    var mark = document.getElementById('tsumikiLicMark');

    function rpc(name, body){
      return fetch(RPC + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY },
        body: JSON.stringify(body)
      }).then(function(r){ return r.json(); });
    }
    var device = localStorage.getItem(K_DEV);
    if(!device){
      device = (window.crypto && crypto.randomUUID) ? crypto.randomUUID()
             : 'd-' + Date.now() + '-' + Math.random().toString(36).slice(2, 10);
      localStorage.setItem(K_DEV, device);
    }
    function unlock(customer){
      gate.style.display = 'none';
      if(customer){
        localStorage.setItem(K_CUST, customer);
        mark.textContent = customer + ' さま専用';
        mark.hidden = false;
      }
    }
    function lock(){
      localStorage.removeItem(K_TOKEN);
      localStorage.removeItem(K_CUST);
      mark.hidden = true;
      gate.style.display = 'flex';
    }

    var token = localStorage.getItem(K_TOKEN);
    if(token){
      // 解錠済み端末：即表示して裏で照合。ネットワークエラーでは締め出さない。
      unlock(localStorage.getItem(K_CUST));
      rpc('license_verify', { p_token: token, p_app: APP, p_device_id: device })
        .then(function(res){
          if(res && res.ok === false){ lock(); }
          else if(res && res.ok && res.customer){ unlock(res.customer); }
        }).catch(function(){});
    }

    form.addEventListener('submit', function(e){
      e.preventDefault();
      var v = (input.value || '').trim();
      if(!v){ err.textContent = 'キーを入力してください'; return; }
      btn.disabled = true;
      err.textContent = '';
      rpc('license_activate', { p_key: v, p_app: APP, p_device_id: device })
        .then(function(res){
          btn.disabled = false;
          if(res && res.ok){
            localStorage.setItem(K_TOKEN, res.token);
            unlock(res.customer);
          }else if(res && res.code === 'device_limit'){
            err.textContent = 'ご利用できる端末数の上限に達しています。お手数ですがご連絡ください。';
          }else{
            err.textContent = 'キーが確認できませんでした。入力内容をお確かめください。';
          }
        }).catch(function(){
          btn.disabled = false;
          err.textContent = '通信できませんでした。電波の届く場所でもう一度お試しください。';
        });
    });
  })();
</script>
<!-- /tsumiki-license-gate -->
"""

BLOCK_RE = re.compile(
    r"<!-- tsumiki-license-gate -->.*?<!-- /tsumiki-license-gate -->",
    re.DOTALL,
)
APP_RE = re.compile(r"var APP = '([^']*)';")


def build_snippet(app: str) -> str:
    return (
        SNIPPET
        .replace("__APP__", app)
        .replace("__SUPABASE_URL__", SUPABASE_URL)
        .replace("__SUPABASE_ANON__", SUPABASE_ANON)
    )


def inject(path: Path, app: str) -> None:
    html = path.read_text(encoding="utf-8")
    snippet = build_snippet(app)
    if MARKER in html:
        html = BLOCK_RE.sub(lambda _: snippet, html, count=1)
        path.write_text(html, encoding="utf-8")
        print(f"↻ {path}: ゲートを新版に更新（app={app}）")
        return
    if "</body>" not in html:
        sys.exit(f"! {path}: </body> が見つからず注入できません")
    html = html.replace("</body>", snippet + "\n</body>", 1)
    path.write_text(html, encoding="utf-8")
    print(f"✓ {path}: プロダクトキーゲートを注入（app={app}）")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("使い方: python3 inject_license.py <対象HTML> <app名>")
    inject(Path(sys.argv[1]).expanduser(), sys.argv[2])
