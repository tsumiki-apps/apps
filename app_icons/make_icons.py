# 自作Macアプリのアイコン：Macリセット（~/mac-reset/icon/make_icon.py）と同じ作法
#  透明の地・黒 #111 の丸ペン線画・線の太さ 50px（1024角）・白いフチ 16px・外枠は一辺の8割で真ん中に置く
#
#   python3 make_icons.py            → out/<名前>.png（1024角）と out/<名前>.icns
#   python3 make_icons.py --apply    → 上に加えて ~/Applications などのアプリへ「カスタムアイコン」として貼る
#                                      （中身と署名は変えない＝権限を取り直さずに済む）
import subprocess, pathlib, tempfile, shutil, sys, json
from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = pathlib.Path(__file__).parent
OUT = HERE / "out"
S = 1024
SW = 50          # 線の太さ（仕上がりの画素）
HALO_W = 16      # 白いフチの片側
CONTENT = 0.80   # 外枠の長い辺が一辺の何割か

H = pathlib.Path.home()
APPS = {
    "メモのチェックリスト": H / "Applications/メモのチェックリスト.app",
    "リマインダー読み取り": H / "Applications/リマインダー読み取り.app",
    "リマインダー追加": H / "Applications/リマインダー追加.app",
    "通知まとめ消し": H / "Applications/通知まとめ消し.app",
    "タブグループ整理": pathlib.Path("/Applications/タブグループ整理.app"),
}

def sparkle(x, y, k):
    q = k*0.16
    return (f"M{x} {y-k} Q{x+q} {y-q} {x+k} {y} Q{x+q} {y+q} {x} {y+k} "
            f"Q{x-q} {y+q} {x-k} {y} Q{x-q} {y-q} {x} {y-k} Z")

def rrect(x, y, w, h, r):
    return (f"M{x+r} {y} H{x+w-r} A{r} {r} 0 0 1 {x+w} {y+r} V{y+h-r} A{r} {r} 0 0 1 {x+w-r} {y+h} "
            f"H{x+r} A{r} {r} 0 0 1 {x} {y+h-r} V{y+r} A{r} {r} 0 0 1 {x+r} {y} Z")

def circle(cx, cy, r):
    return f"M{cx-r} {cy} A{r} {r} 0 1 0 {cx+r} {cy} A{r} {r} 0 1 0 {cx-r} {cy} Z"

# ───────── 形（どれも 0〜1000 の座標で描き、あとで真ん中に寄せる） ─────────
def memo():
    # メモ用紙＋チェック済みの箱と空の箱
    return [rrect(170, 90, 660, 820, 100),
            rrect(290, 220, 180, 180, 45), "M330 300 L385 355 L500 200", "M560 310 H710",
            rrect(290, 560, 180, 180, 45), "M560 650 H710"]

def rem_rows(ends):
    out = []
    for i, x1 in enumerate(ends):
        y = 180 + i*230
        out += [circle(220, y, 62), f"M370 {y} H{x1}"]
    return out

def rem_read():
    # リマインダーの行（○―）＋虫めがね
    return rem_rows([800, 800, 470]) + [circle(690, 680, 150), "M800 790 L880 870"]

def rem_add():
    # リマインダーの行（○―）＋足す
    return rem_rows([800, 800, 520]) + ["M740 560 V840", "M600 700 H880"]

def notif():
    # 重なった通知（奥2枚は上の縁だけ）＋手前の札に ×
    return ["M290 250 Q290 190 350 190 H650 Q710 190 710 250",
            "M210 360 Q210 300 270 300 H730 Q790 300 790 360",
            rrect(120, 420, 760, 440, 100),
            "M420 560 L580 720", "M580 560 L420 720"]

def tabs():
    # ブラウザの窓とタブ2つ＋きらり（整える）
    return ["M120 330 V780 Q120 860 200 860 H800 Q880 860 880 780 V410 Q880 330 800 330 H120",
            "M120 330 V240 Q120 170 190 170 H400 Q470 170 470 240 V330",
            "M560 330 V240 Q560 170 630 170 H740 Q810 170 810 240 V330",
            sparkle(500, 595, 160)]

SHAPES = {"メモのチェックリスト": memo, "リマインダー読み取り": rem_read, "リマインダー追加": rem_add,
          "通知まとめ消し": notif, "タブグループ整理": tabs}

def svg(paths, tf, halo=True):
    common = 'fill="none" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"'
    def grp(color, w):
        return (f'<g transform="{tf}">' + "".join(
            f'<path d="{d}" stroke="{color}" stroke-width="{w}" {common}/>' for d in paths) + "</g>")
    body = (grp("#ffffff", SW + HALO_W*2) if halo else "") + grp("#111111", SW)
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">{body}</svg>'

def render(svgtext, out):
    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "i.html").write_text(f'<html><body style="margin:0;background:transparent">{svgtext}</body></html>')
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--default-background-color=00000000", f"--window-size={S},{S}",
                    f"--screenshot={out}", f"file://{tmp/'i.html'}"], check=True, capture_output=True, timeout=120)
    shutil.rmtree(tmp)

def bbox(path):
    a = Image.open(path).convert("RGBA").getchannel("A")
    return a.point(lambda v: 255 if v > 8 else 0).getbbox()

def build(name):
    paths = SHAPES[name]()
    png = OUT / f"{name}.png"
    # 1回目：そのまま描いて外枠を測る → 外枠の長い辺を一辺の8割に、真ん中へ（線は太さ固定なので2回詰める）
    sc, ox, oy = 1.0, 12.0, 12.0
    for _ in range(3):
        render(svg(paths, f"translate({ox:.2f},{oy:.2f}) scale({sc:.5f})"), png)
        x0, y0, x1, y1 = bbox(png)
        k = S*CONTENT / max(x1-x0, y1-y0)
        cx, cy = (x0+x1)/2, (y0+y1)/2
        # 画面上の点 p = o + sc*q。外枠の中心を S/2 に、大きさを k 倍に
        sc2 = sc * k
        ox = S/2 - (cx - ox)*k
        oy = S/2 - (cy - oy)*k
        sc = sc2
    render(svg(paths, f"translate({ox:.2f},{oy:.2f}) scale({sc:.5f})"), png)
    bb = bbox(png)
    icns = OUT / f"{name}.icns"
    iset = pathlib.Path(tempfile.mkdtemp()) / "a.iconset"
    iset.mkdir()
    im = Image.open(png)
    for p in (16, 32, 128, 256, 512):
        im.resize((p, p), Image.LANCZOS).save(iset / f"icon_{p}x{p}.png")
        im.resize((p*2, p*2), Image.LANCZOS).save(iset / f"icon_{p}x{p}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iset), "-o", str(icns)], check=True)
    shutil.rmtree(iset.parent)
    mg = [bb[0], bb[1], S-bb[2], S-bb[3]]
    return {"名前": name, "外枠": bb, "余白_左上右下": mg}

def apply(name):
    app, png = APPS[name], OUT / f"{name}.png"
    swift = ('import AppKit\nlet a = CommandLine.arguments\n'
             'let ok = NSWorkspace.shared.setIcon(NSImage(contentsOfFile: a[1]), forFile: a[2], options: [])\n'
             'print(ok ? "OK" : "NG")\n')
    f = pathlib.Path(tempfile.mkdtemp()) / "seticon.swift"
    f.write_text(swift)
    r = subprocess.run(["swift", str(f), str(png), str(app)], capture_output=True, text=True)
    subprocess.run(["touch", str(app)])
    return r.stdout.strip() or r.stderr.strip()

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    for n in (only or SHAPES):
        info = build(n)
        if "--apply" in sys.argv:
            info["貼り付け"] = apply(n)
        print(json.dumps(info, ensure_ascii=False))
