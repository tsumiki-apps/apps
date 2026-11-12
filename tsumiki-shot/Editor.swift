// 撮った画像に書き込む（矢印・四角・文字・モザイク）。
// 書き込みは画像の画素の座標（左上が原点）で持ち、画面の表示と書き出しで同じ描き方を使う。
// 保存は元の画像を残し「〜 編集.png」を横に作る（＋クリップボード）。
import AppKit

enum Mark: Equatable {
    case arrow(CGPoint, CGPoint)
    case box(CGRect)
    case text(CGPoint, String)       // 文字の左上
    case mosaic(CGRect)
}

let markColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)

enum Annotate {
    /// 左上原点の座標系（ctx は上下反転済み）に、画像を正しい向きで置く
    static func put(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// 範囲を粗いマス目にする（元の画素は残らない）
    static func pixelate(_ base: CGImage, _ r: CGRect, block: Int) -> CGImage? {
        let r = r.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 1, r.height >= 1, let part = base.cropping(to: r) else { return nil }
        let sw = max(1, Int(r.width) / block), sh = max(1, Int(r.height) / block)
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,   // 元と同じ色空間（P3 の色がずれない）
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(part, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return small.makeImage()
    }

    static func font(_ unit: CGFloat) -> NSFont { .systemFont(ofSize: 20 * unit, weight: .bold) }

    static func textAttrs(_ unit: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(unit), .foregroundColor: markColor, .strokeColor: NSColor.white, .strokeWidth: -3.0]
    }

    /// ctx は「画像の画素・左上原点」。画面表示では外側で縮尺をかけてから呼ぶ
    static func draw(_ marks: [Mark], base: CGImage, unit: CGFloat, in ctx: CGContext) {
        let line = 3 * unit
        for m in marks {
            switch m {
            case .mosaic(let r):
                let rr = r.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
                if let p = pixelate(base, rr, block: Int(8 * unit)) {
                    ctx.saveGState(); ctx.interpolationQuality = .none
                    put(p, in: rr, ctx)
                    ctx.restoreGState()
                }
            case .box(let r):
                ctx.setStrokeColor(markColor.cgColor); ctx.setLineWidth(line)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil))
                ctx.strokePath()
            case .arrow(let a, let b):
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 1 else { continue }
                let ang = atan2(b.y - a.y, b.x - a.x)
                let head = min(len * 0.6, 16 * unit)
                let base = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
                ctx.setStrokeColor(markColor.cgColor); ctx.setFillColor(markColor.cgColor)
                ctx.setLineWidth(line); ctx.setLineCap(.round)
                ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(ang - 0.45) * head, y: b.y - sin(ang - 0.45) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(ang + 0.45) * head, y: b.y - sin(ang + 0.45) * head))
                ctx.closePath(); ctx.fillPath()
            case .text(let p, let s):
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                (s as NSString).draw(at: p, withAttributes: textAttrs(unit))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// 書き込みを焼き込んだ1枚
    static func flatten(_ base: CGImage, _ marks: [Mark], unit: CGFloat) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        draw(marks, base: base, unit: unit, in: ctx)
        return ctx.makeImage()
    }
}

enum Tool: Int { case arrow, box, text, mosaic }

/// 画像と書き込みを表示し、ドラッグで書き込む面（左上原点）
final class CanvasView: NSView, NSTextFieldDelegate {
    let base: CGImage
    let unit: CGFloat
    var marks: [Mark] = [] { didSet { needsDisplay = true; onChange?() } }
    var draft: Mark? { didSet { needsDisplay = true } }
    var tool: Tool = .arrow
    var onChange: (() -> Void)?
    private var downAt: CGPoint?
    private var field: NSTextField?
    /// 表示用に一度だけ縮めた画像（大きな縦長でも、描き直すたびに元の大きさを縮めない）
    private let shown: CGImage

    init(base: CGImage, unit: CGFloat, width: CGFloat) {
        self.base = base; self.unit = unit
        let s = width / CGFloat(base.width)
        shown = CanvasView.shrink(base, toWidth: Int(width * 2)) ?? base
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(base.height) * s))
    }

    static func shrink(_ img: CGImage, toWidth w: Int) -> CGImage? {
        guard img.width > w else { return img }
        let h = max(1, Int(Double(img.height) * Double(w) / Double(img.width)))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var viewScale: CGFloat { bounds.width / CGFloat(base.width) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = .high
        Annotate.put(shown, in: CGRect(x: 0, y: 0, width: base.width, height: base.height), ctx)
        Annotate.draw(marks + (draft.map { [$0] } ?? []), base: base, unit: unit, in: ctx)
        ctx.restoreGState()
    }

    func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width) / viewScale, y: min(max(p.y, 0), bounds.height) / viewScale)
    }

    private func make(_ a: CGPoint, _ b: CGPoint) -> Mark {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        switch tool {
        case .arrow: return .arrow(a, b)
        case .box: return .box(r)
        case .mosaic: return .mosaic(r)
        case .text: return .text(a, "")
        }
    }

    override func mouseDown(with e: NSEvent) {
        commitText()
        let p = imagePoint(e)
        if tool == .text { beginText(at: p); return }
        downAt = p
    }
    override func mouseDragged(with e: NSEvent) {
        guard let a = downAt else { return }
        draft = make(a, imagePoint(e))
    }
    override func mouseUp(with e: NSEvent) {
        guard let a = downAt else { return }
        downAt = nil; draft = nil
        let b = imagePoint(e)
        if hypot(b.x - a.x, b.y - a.y) * viewScale >= 6 { marks.append(make(a, b)) }
    }

    // 文字：押した所に入力欄を出し、Enter か他を押したら確定
    private var textAt: CGPoint = .zero
    func beginText(at p: CGPoint) {
        textAt = p
        let f = NSTextField(frame: NSRect(x: p.x * viewScale, y: p.y * viewScale, width: 220, height: 18 * unit * viewScale + 10))
        f.font = .systemFont(ofSize: max(13, 18 * unit * viewScale), weight: .bold)
        f.textColor = markColor
        f.placeholderString = "文字"
        f.delegate = self
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
    }
    func commitText() {
        guard let f = field else { return }
        field = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        if !s.isEmpty { marks.append(.text(textAt, s)) }
        window?.makeFirstResponder(self)
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { field?.stringValue = ""; commitText(); return true }
        return false
    }

    /// 文字を打っている最中の ⌘Z は、その文字の取り消し（確定済みの書き込みは消さない）
    func undo() {
        if let f = field {
            if let um = f.currentEditor()?.undoManager, um.canUndo { um.undo(); return }
            f.stringValue = ""; commitText(); return
        }
        if !marks.isEmpty { marks.removeLast() }
    }
    override var acceptsFirstResponder: Bool { true }
}

final class EditorWindow: NSWindowController, NSWindowDelegate {
    let url: URL
    let canvas: CanvasView
    let tools = NSSegmentedControl()
    var onClose: (() -> Void)?
    var onSaved: ((CGImage, URL) -> Void)?

    init(image: CGImage, url: URL, unit: CGFloat) {
        self.url = url
        // 窓の幅：画像の見た目の幅（画素÷倍率）と画面の8割の小さいほう
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let natural = CGFloat(image.width) / unit
        let width = max(360, min(natural, vf.width * 0.8))
        canvas = CanvasView(base: image, unit: unit, width: width)
        let barH: CGFloat = 52
        let height = min(canvas.frame.height, vf.height * 0.8 - barH)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + barH),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        win.title = url.deletingPathExtension().lastPathComponent
        super.init(window: win)
        win.delegate = self
        win.isReleasedWhenClosed = false

        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sv.hasVerticalScroller = canvas.frame.height > height
        sv.documentView = canvas
        sv.autoresizingMask = [.width, .height]
        canvas.scroll(.zero)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + barH))
        root.addSubview(sv)
        let bar = makeBar()
        bar.frame = NSRect(x: 12, y: height + 10, width: width - 24, height: 32)
        bar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(bar)
        win.contentView = root
        win.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func makeBar() -> NSStackView {
        let syms = [("arrow.up.right", "矢印"), ("rectangle", "四角"), ("textformat", "文字"), ("square.grid.3x3.fill", "モザイク")]
        tools.segmentCount = syms.count
        tools.trackingMode = .selectOne
        for (i, (s, l)) in syms.enumerated() {
            tools.setImage(NSImage(systemSymbolName: s, accessibilityDescription: l), forSegment: i)
            tools.setToolTip(l, forSegment: i)
            tools.setWidth(40, forSegment: i)
        }
        tools.selectedSegment = 0
        tools.target = self; tools.action = #selector(pickTool)
        let undo = iconButton("arrow.uturn.backward", "戻す（⌘Z）", self, #selector(undoMark))
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command
        let save = iconButton("square.and.arrow.down", "保存（⌘S）＝元は残して「〜 編集.png」を作る", self, #selector(save), prominent: true)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let row = NSStackView()
        row.spacing = 8
        row.addView(tools, in: .leading)
        row.addView(undo, in: .trailing)
        row.addView(save, in: .trailing)
        return row
    }

    @objc func pickTool() { canvas.commitText(); canvas.tool = Tool(rawValue: tools.selectedSegment) ?? .arrow }
    @objc func undoMark() { canvas.undo() }

    /// 「〜 編集.png」として横に保存（元は残す）
    private var saving = false

    @objc func save() {
        canvas.commitText()
        guard !saving else { return }
        saving = true
        let base = canvas.base, marks = canvas.marks, unit = canvas.unit
        window?.title = "保存中…"
        // 大きな画像でも画面が固まらないよう、焼き込みと PNG 化は裏で
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Annotate.flatten(base, marks, unit: unit)
            let data = NSMutableData()
            var ok = false
            if let img, let d = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil); ok = CGImageDestinationFinalize(d)
            }
            DispatchQueue.main.async { self.finishSave(ok ? img : nil, data as Data) }
        }
    }

    private func finishSave(_ img: CGImage?, _ data: Data) {
        saving = false
        window?.title = url.deletingPathExtension().lastPathComponent
        guard let img else { failAlert("画像を作れませんでした（大きすぎる可能性があります）"); return }
        let stem = url.deletingPathExtension().lastPathComponent
        // 元の画像の隣に保存。書けない場所（App Store 版で選んだ別のフォルダの画像など）なら保存先に
        func write(in dir: URL) -> URL? {
            var out = dir.appendingPathComponent("\(stem) 編集.png")
            var n = 2
            while FileManager.default.fileExists(atPath: out.path) {
                out = dir.appendingPathComponent("\(stem) 編集 \(n).png"); n += 1
            }
            return (try? data.write(to: out, options: .withoutOverwriting)) != nil ? out : nil
        }
        guard let out = write(in: url.deletingLastPathComponent()) ?? write(in: saveDir) else {
            failAlert("保存できませんでした（保存先に書き込めません）"); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        let cb = onSaved                      // 閉じると自分が外されるので、先に控える
        window?.close()
        cb?(img, out)
    }

    private func failAlert(_ why: String) {
        guard let w = window else { NSSound.beep(); return }
        let a = NSAlert(); a.messageText = "保存できませんでした"; a.informativeText = why
        a.beginSheetModal(for: w)
    }

    func show() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func windowWillClose(_ n: Notification) { onClose?() }
}
