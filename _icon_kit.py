# -*- coding: utf-8 -*-
"""アイコン作成キット（作り直し版）
   ・部品を「見た目の外接矩形」で扱い、好きな並べ方で組んで、かたまりごと中央に据える
   ・描画は Chrome ヘッドレス（cairosvg が壊れているため）
"""
import subprocess, pathlib, tempfile, shutil
from PIL import Image
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BG="#1c1c1c"; LINE="#ffffff"
RATIO=0.075                      # つみき公式ロゴ：絵の幅に対する線の比（正本 4.5/60）

# ---- 部品 -------------------------------------------------------------
# 本体の線画（100座標・stroke 6 前提）。draw()は倍率1のときの内容、box は絵の範囲。
class Sym:
    def __init__(self, body, x0,y0,x1,y1, sw=6):
        self.body, self.box, self.sw = body, (x0,y0,x1,y1), sw
    def size(self, s):           # 見た目（線こみ）の大きさ
        h=self.sw/2
        return ((self.box[2]-self.box[0]+self.sw)*s, (self.box[3]-self.box[1]+self.sw)*s)
    def svg(self, s, left, top): # 見た目の左上を (left,top) に置く
        h=self.sw/2
        dx = left - (self.box[0]-h)*s
        dy = top  - (self.box[1]-h)*s
        return (f'<g transform="translate({dx:.3f},{dy:.3f}) scale({s})" fill="none" '
                f'stroke="{LINE}" stroke-width="{self.sw}" stroke-linecap="round" '
                f'stroke-linejoin="round">{self.body}</g>')

# つみき公式ロゴ（座標は正本のまま・9面）
TSUMIKI_BODY=('<polygon points="35,46 50,53.5 35,61 20,53.5"/><polygon points="20,53.5 35,61 35,76 20,68.5"/>'
 '<polygon points="50,53.5 35,61 35,76 50,68.5"/><polygon points="65,46 80,53.5 65,61 50,53.5"/>'
 '<polygon points="50,53.5 65,61 65,76 50,68.5"/><polygon points="80,53.5 65,61 65,76 80,68.5"/>'
 '<polygon points="50,24 65,31.5 50,39 35,31.5"/><polygon points="35,31.5 50,39 50,54 35,46.5"/>'
 '<polygon points="65,31.5 50,39 50,54 65,46.5"/>')
class Logo:
    box=(20,24,80,76)            # 絵の範囲（幅60・高さ52）
    def size(self, s):
        sw=60*s*RATIO
        return (60*s+sw, 52*s+sw)
    def svg(self, s, left, top):
        sw=60*s*RATIO; h=sw/2
        dx = left - (20*s - h); dy = top - (24*s - h)
        return (f'<g transform="translate({dx:.3f},{dy:.3f}) scale({s})" fill="{BG}" '
                f'stroke="{LINE}" stroke-width="{sw/s:.4f}" stroke-linejoin="round" '
                f'stroke-linecap="round">{TSUMIKI_BODY}</g>')

# ---- 組み立て：部品を置いた「かたまり」を中央へ ------------------------
def compose(parts):
    """parts = [(部品, 倍率, ローカルx, ローカルy), ...]  ローカル座標は左上基準"""
    boxes=[]
    for obj,s,x,y in parts:
        w,h = obj.size(s); boxes.append((x,y,x+w,y+h))
    L=min(b[0] for b in boxes); T=min(b[1] for b in boxes)
    R=max(b[2] for b in boxes); B=max(b[3] for b in boxes)
    W,H = R-L, B-T
    ox = (100-W)/2 - L; oy = (100-H)/2 - T
    svg="".join(obj.svg(s, x+ox, y+oy) for obj,s,x,y in parts)
    return svg, dict(W=W,H=H, margin=((100-W)/2,(100-H)/2,(100-W)/2,(100-H)/2),
                     boxes=[(b[0]+ox,b[1]+oy,b[2]+ox,b[3]+oy) for b in boxes])

def render(svg, out, px=540):
    d=tempfile.mkdtemp(); h=pathlib.Path(d)/'i.html'
    h.write_text(f'<!doctype html><meta charset="utf-8"><style>html,body{{margin:0;background:{BG}}}'
                 f'svg{{display:block}}</style>'
                 f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="{px}" height="{px}">'
                 f'<rect width="100" height="100" fill="{BG}"/>{svg}</svg>')
    p=pathlib.Path(d)/'s.png'
    subprocess.run([CHROME,"--headless","--disable-gpu","--hide-scrollbars",
                    f"--screenshot={p}",f"--window-size={px},{px}",f"file://{h}"],capture_output=True)
    Image.open(p).convert('RGB').resize((180,180),Image.LANCZOS).save(out)
    shutil.rmtree(d,ignore_errors=True); return out

def measure(png):
    """描いた結果から余白と塊の数を測る"""
    import numpy as np
    from collections import deque
    a=np.array(Image.open(png).convert('L')); w=a>110; k=100/a.shape[0]
    ys,xs=np.where(w)
    m=(xs.min()*k, ys.min()*k, 100-xs.max()*k, 100-ys.max()*k)
    seen=np.zeros_like(w); n=0; H,W=w.shape
    for y in range(H):
        for x in range(W):
            if w[y,x] and not seen[y,x]:
                n+=1; q=deque([(y,x)]); seen[y,x]=True
                while q:
                    cy,cx=q.popleft()
                    for dy in(-1,0,1):
                        for dx in(-1,0,1):
                            ny,nx=cy+dy,cx+dx
                            if 0<=ny<H and 0<=nx<W and w[ny,nx] and not seen[ny,nx]:
                                seen[ny,nx]=True; q.append((ny,nx))
    return dict(margin=m, diff=max(m)-min(m), blobs=n,
                size=((xs.max()-xs.min())*k, (ys.max()-ys.min())*k))
