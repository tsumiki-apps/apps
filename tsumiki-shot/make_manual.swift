// 説明書（PDF）を作る：swift make_manual.swift <出力.pdf> [見本の画像フォルダ]
// アイコンはアプリと同じ SF Symbols。色と書体は ~/制作物/DESIGN.md（紙・墨・黄土・Zen Maru Gothic）
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let paper = hex(0xf5f4f0), ink = hex(0x1d1a15), inkMid = hex(0x5b554a), line = hex(0xe2ded4)
let accent = hex(0xb06f26), accent2 = hex(0x8a5a24), wash = hex(0xf0e4d1), card = NSColor.white
let barBG = hex(0x2a2620), barInk = hex(0xefe8da), darkAccent = hex(0xd59a4d)

func font(_ size: CGFloat, _ w: String = "Medium") -> NSFont {
    NSFont(name: "ZenMaruGothic-\(w)", size: size) ?? .systemFont(ofSize: size)
}

let W: CGFloat = 595, H: CGFloat = 842, M: CGFloat = 48
var missing: [String] = []

// MARK: - 描く道具（左上原点）

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = ink,
          weight: String = "Medium", width: CGFloat = 1000, center: Bool = false) -> CGFloat {
    let ps = NSMutableParagraphStyle(); ps.lineSpacing = size * 0.35
    if center { ps.alignment = .center }
    let a = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color, .paragraphStyle: ps])
    let r = a.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin])
    a.draw(with: NSRect(x: x, y: y, width: width, height: ceil(r.height)), options: [.usesLineFragmentOrigin])
    return ceil(r.height)
}

func symbol(_ name: String, _ rect: NSRect, _ color: NSColor, weight: NSFont.Weight = .regular) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)) else { missing.append(name); return }
    // 枠の中に縦横比を保って真ん中に
    let s = img.size, k = min(rect.width / s.width, rect.height / s.height)
    let r = NSRect(x: rect.midX - s.width * k / 2, y: rect.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
    // PDF の上では色の差し替え（重ね方）が効かないので、8倍の細かさで色を付けた画像にしてから置く
    let scale: CGFloat = 8
    let pw = Int(ceil(r.width * scale)), ph = Int(ceil(r.height * scale))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph))
    color.setFill()
    NSRect(x: 0, y: 0, width: pw, height: ph).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    let tinted = NSImage(size: r.size); tinted.addRepresentation(rep)
    tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func round(_ r: NSRect, _ radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); p.fill() }
    if let stroke { stroke.setStroke(); p.lineWidth = 1; p.stroke() }
}

/// 洗い色の角丸にアイコン
func tile(_ name: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 34) {
    round(NSRect(x: x, y: y, width: size, height: size), size * 0.28, fill: wash)
    symbol(name, NSRect(x: x + size * 0.22, y: y + size * 0.22, width: size * 0.56, height: size * 0.56), accent2, weight: .medium)
}

/// キーの札
func keycap(_ s: String, right: CGFloat, _ y: CGFloat) {
    let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ink])
    let w = a.size().width + 18
    round(NSRect(x: right - w, y: y, width: w, height: 24), 6, fill: card, stroke: hex(0xd8d3c7))
    a.draw(at: NSPoint(x: right - w + 9, y: y + 4))
}

// MARK: - ページ

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "説明書.pdf"
var box = CGRect(x: 0, y: 0, width: W, height: H)
let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "つみきショット 説明書"] as CFDictionary)!
var pageNo = 0
var y: CGFloat = 0

func newPage(_ title: String, _ sym: String) {
    if pageNo > 0 { NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage() }
    pageNo += 1
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    paper.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    // 上の帯：アプリ名と番号
    symbol("camera.viewfinder", NSRect(x: M, y: 28, width: 14, height: 14), inkMid)
    _ = text("つみきショット", M + 20, 27, 10, inkMid)
    _ = text("\(pageNo)", W - M - 20, 27, 10, inkMid, width: 20)
    y = 64
    if !title.isEmpty {
        symbol(sym, NSRect(x: M, y: y + 2, width: 26, height: 26), accent, weight: .medium)
        _ = text(title, M + 36, y, 24, ink, weight: "Bold")
        y += 52
    }
}

func heading(_ s: String, _ sym: String) {
    y += 8
    symbol(sym, NSRect(x: M, y: y + 2, width: 16, height: 16), accent2, weight: .semibold)
    _ = text(s, M + 24, y, 15, ink, weight: "Bold")
    y += 30
}

/// 行：アイコン・名前・キー・説明（カードの中）
func rows(_ items: [(sym: String, name: String, key: String?, note: String)]) {
    let rowH: CGFloat = 54
    round(NSRect(x: M, y: y, width: W - 2 * M, height: rowH * CGFloat(items.count)), 14, fill: card, stroke: line)
    for (i, it) in items.enumerated() {
        let top = y + rowH * CGFloat(i)
        if i > 0 { line.setFill(); NSRect(x: M + 62, y: top, width: W - 2 * M - 62, height: 1).fill() }
        tile(it.sym, M + 14, top + 10)
        _ = text(it.name, M + 62, top + 8, 13, ink, weight: "Bold")
        _ = text(it.note, M + 62, top + 28, 10.5, inkMid, width: W - 2 * M - 62 - 100)
        if let k = it.key { keycap(k, right: W - M - 14, top + 15) }
    }
    y += rowH * CGFloat(items.count) + 16
}

/// アプリの札のまね（暗い角丸にアイコン）＋下に名前
func bar(_ items: [(String, String, Bool)]) {
    let cell: CGFloat = 70, pad: CGFloat = 10
    let w = cell * CGFloat(items.count) + pad * 2
    let x0 = (W - w) / 2
    round(NSRect(x: x0, y: y, width: w, height: 48), 24, fill: barBG)
    for (i, (s, label, main)) in items.enumerated() {
        let cx = x0 + pad + cell * CGFloat(i) + cell / 2
        let b = NSRect(x: cx - 22, y: y + 8, width: 44, height: 32)
        round(b, 16, fill: main ? darkAccent : hex(0x433d33))
        symbol(s, b.insetBy(dx: 13, dy: 8), main ? ink : barInk, weight: .semibold)
        _ = text(label, cx - cell / 2, y + 56, 10.5, inkMid, width: cell, center: true)
    }
    y += 84
}

/// 番号つきの手順
func steps(_ items: [String]) {
    for (i, s) in items.enumerated() {
        round(NSRect(x: M, y: y, width: 22, height: 22), 11, fill: accent2)
        _ = text("\(i + 1)", M, y + 3, 12, paper, weight: "Bold", width: 22, center: true)
        let h = text(s, M + 32, y + 2, 12.5, ink, width: W - 2 * M - 32)
        y += max(30, h + 12)
    }
    y += 4
}

/// 小さな注記（アイコン＋一行）
func notes(_ items: [(String, String)]) {
    for (s, t) in items {
        symbol(s, NSRect(x: M + 2, y: y + 2, width: 14, height: 14), accent2, weight: .medium)
        let h = text(t, M + 24, y, 11.5, inkMid, width: W - 2 * M - 24)
        y += max(22, h + 8)
    }
    y += 6
}

// MARK: - 1 はじめに

newPage("", "")
y = 120
// アプリのアイコン（./build.sh が書き出したもの。なければ記号で代わり）
if let icon = NSImage(contentsOfFile: "build/AppIcon.iconset/icon_512x512.png") {
    icon.draw(in: NSRect(x: (W - 116) / 2, y: y - 10, width: 116, height: 116), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
} else {
    round(NSRect(x: (W - 96) / 2, y: y, width: 96, height: 96), 28, fill: wash)
    symbol("camera.viewfinder", NSRect(x: (W - 56) / 2, y: y + 20, width: 56, height: 56), accent2, weight: .medium)
}
y += 120
_ = text("つみきショット", 0, y, 34, ink, weight: "Bold", width: W, center: true)
y += 50
_ = text("説明書", 0, y, 15, inkMid, width: W, center: true)
y += 70

heading("はじめに", "sparkles")
steps(["メニューバーの 積み木 から、またはキーで撮る",
       "撮れたら画面の左下に小窓が出る（押すと開く・ドラッグで貼れる）",
       "画像は保存＋クリップボードへ。そのまま貼れる"])

heading("許可", "lock.shield")
rows([("rectangle.dashed.badge.record", "画面収録", "必須", "撮るのに要る。システム設定 → プライバシー"),
      ("accessibility", "アクセシビリティ", "自動だけ", "自動スクロールを使うときだけ。初回に案内が出る")])

heading("保存先", "folder")
notes([("folder", "既定は ~/Pictures/つみきショット/（PNG・録画は MP4）"),
       ("gearshape", "「設定…」の 保存先 →「変更…」で好きなフォルダに"),
       ("doc.on.clipboard", "クリップボードにも入る")])

// MARK: - 2 撮る

newPage("撮る", "camera.viewfinder")
rows([("rectangle.dashed", "範囲", "⇧⌘4", "ドラッグで選ぶ。スペースで窓に→Enter で撮る"),
      ("macwindow", "全画面", "⇧⌘3", "マウスのある画面"),
      ("arrow.down.to.line.compact", "スクロール", "⇧⌘5", "長いページを1枚に（縦も横も）→ 3ページ"),
      ("record.circle", "録画", "⇧⌘6", "範囲を MP4 に。もう一度押すと停止"),
      ("pencil.tip", "注釈", "⇧⌘7", "直前のスクショを編集画面で開く"),
      ("macwindow.on.rectangle", "ウィンドウ", "⇧⌘8", "窓を指して Enter かクリックでその窓だけ"),
      ("text.viewfinder", "文字を読む", "⇧⌘2", "範囲の文字をコピー（日本語・英語）")])
notes([("gearshape", "キーは「設定…」で好きなものに変えられる → 5ページ"),
       ("menubar.rectangle", "メニューバーの 積み木 からも同じ操作ができる")])

heading("録画中", "record.circle")
bar([("stop.fill", "停止", true)])
notes([("rectangle.dashed", "撮っている範囲は赤い枠・経過時間つき"),
       ("film", "できた動画はファイルのまま他のアプリへ貼れる")])

// MARK: - 3 スクロール

newPage("スクロール", "arrow.down.to.line.compact")
steps(["⇧⌘5 で範囲を選ぶ",
       "手でゆっくりスクロール。または ▶︎ で自動",
       "端まで来たら ✓（もう一度 ⇧⌘5 でも）"])

heading("札のボタン", "slider.horizontal.3")
bar([("arrow.down", "向き", false), ("play.fill", "自動", false), ("pause.fill", "自動を止める", false),
     ("xmark", "取消", false), ("checkmark", "完了", true)])

heading("自動スクロール", "play.circle")
notes([("arrow.down", "少しずつ送って継ぐ。動かなければ向きを試し直す"),
       ("flag.checkered", "端で止まったら自動で仕上げる"),
       ("hand.raised", "手でスクロール・クリック・キーを触ると手動に戻る"),
       ("accessibility", "初回だけアクセシビリティの許可が要る")])

heading("うまく継ぐコツ", "lightbulb")
notes([("tortoise", "「ゆっくり」と出たら速すぎ。少し戻してゆっくり"),
       ("arrow.left.and.right", "横スクロールも可。最初に動いた向きに決まる"),
       ("rectangle.topthird.inset.filled", "上下に固定された見出し・帯は自動で外す")])

// MARK: - 4 撮ったあと

newPage("撮ったあと", "photo")
heading("小窓", "rectangle.bottomhalf.inset.filled")
bar([("pencil.tip", "編集", true), ("pin", "ピン", false), ("folder", "Finder", false), ("xmark", "閉じる", false)])
notes([("hand.point.up.left", "画像を押すと開く・ドラッグで他のアプリへ"),
       ("timer", "8秒で消える（指を乗せている間は残る）"),
       ("play.fill", "録画のときは 鉛筆 の代わりに 再生")])

heading("ピン", "pin")
notes([("arrow.up.and.down.and.arrow.left.and.right", "画面に浮かべる。ドラッグで移動"),
       ("xmark.circle", "ダブルクリックか esc で閉じる"),
       ("doc.on.clipboard", "右クリックでコピー")])

heading("編集", "pencil.tip")
rows([("arrow.up.right", "矢印", nil, "ドラッグで引く"),
      ("rectangle", "四角", nil, "囲んで目立たせる"),
      ("textformat", "文字", nil, "押した所に書く"),
      ("square.grid.3x3.fill", "モザイク", nil, "見せたくない所を隠す"),
      ("arrow.uturn.backward", "戻す", "⌘Z", "ひとつ前に"),
      ("square.and.arrow.down", "保存", "⌘S", "元は残して「〜 編集.png」を横に作る")])

// MARK: - 5 設定・困ったとき

newPage("設定", "gearshape")
notes([("menubar.rectangle", "メニューバーの 積み木 →「設定…」（⌘,）")])
heading("ショートカットを変える", "keyboard")
steps(["変えたい操作の欄を押す",
       "使いたいキーを押す（⌘ ⌃ ⌥ のどれかと一緒に。F キーは単独でも可）"])
rows([("delete.left", "なしにする", "delete", "その操作のキーを外す"),
      ("escape", "やめる", "esc", "覚えるのをやめて元のまま"),
      ("exclamationmark.triangle", "使用中", nil, "他のアプリが使っているキー。別のキーに")])
notes([("arrow.triangle.2.circlepath", "同じキーを2つに付けると、前のほうは「なし」になる"),
       ("arrow.counterclockwise", "既定に戻す（1つずつ・すべて）。「ログイン時に起動」もここで")])

heading("困ったとき", "questionmark.circle")
rows([("rectangle.dashed.badge.record", "真っ黒・何も写らない", nil, "画面収録を許可して、アプリを開き直す"),
      ("accessibility", "自動で動かない", nil, "アクセシビリティを許可する"),
      ("exclamationmark.triangle", "キーが効かない", nil, "⚠︎ が付いていたら設定で別のキーに"),
      ("macbook", "Mac 標準のスクショが出る", nil, "設定の「Mac 標準のスクショのキーを止める」をオン"),
      ("text.viewfinder", "「文字なし」と出る", nil, "範囲を広めに選び直す")])

NSGraphicsContext.restoreGraphicsState()
ctx.endPDFPage()
ctx.closePDF()
if !missing.isEmpty { print("見つからないアイコン：\(Set(missing).sorted())"); exit(1) }
print("OK \(out)（\(pageNo)ページ）")
