// 画面の端に出る棚（トレイ）と、しまったときの取っ手。
// 棚：ドロップを受ける・項目をドラッグで出す（いつも「コピー」＝元を動かさない）・スペースでのぞく。
import AppKit
import Quartz
import QuickLookThumbnailing

// MARK: - 色（DESIGN.md のトークン。ライト/ダークで自動で切り替わる）

enum Palette {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light) }
    }
    static let paper = pair(0xf5f4f0, 0x0f0d07)
    static let surface = pair(0xfffefb, 0x211d14)
    static let surface2 = pair(0xefece5, 0x2b2619)
    static let ink = pair(0x1d1a15, 0xefe8da)
    static let inkSoft = pair(0x666154, 0x9f988a)
    static let ghost = pair(0x887f70, 0x9f988a)
    static let line = pair(0xe2ded4, 0x36301f)
    static let line2 = pair(0xd6d1c4, 0x443d2b)
    static let accent = pair(0xb06f26, 0xd59a4d)
    static let accent2 = pair(0x8a5a24, 0xe0ab63)
    static let accentWash = pair(0xf0e4d1, 0x362a19)
}

func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// 色を付けた記号を rect の真ん中に描く
func drawSymbol(_ name: String, in r: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    guard let img = symbol(name, size, weight) else { return }
    let tinted = NSImage(size: img.size, flipped: false) { b in
        img.draw(in: b); color.set(); b.fill(using: .sourceAtop); return true
    }
    let s = img.size
    tinted.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
}

// MARK: - 縮小画像

final class Thumbs {
    static let shared = Thumbs()
    private var cache: [String: NSImage] = [:]
    private var asked: Set<String> = []

    /// すぐ返せるもの（キャッシュかファイルのアイコン）を返し、裏で本物の縮小画像を作って done を呼ぶ
    func image(for url: URL, size: CGFloat, done: @escaping () -> Void) -> NSImage {
        if let c = cache[url.path] { return c }
        if !asked.contains(url.path) {
            asked.insert(url.path)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                guard let rep else { return }
                DispatchQueue.main.async { self.cache[url.path] = rep.nsImage; done() }
            }
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func forget() { cache.removeAll(); asked.removeAll() }
}

// MARK: - 項目のひとつ

final class ItemCell: NSView, NSDraggingSource {
    static let size = NSSize(width: 136, height: 92)
    let item: TrayItem
    weak var shelf: Shelf?
    var selected = false { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true; closeButton.isHidden = !hover } }
    private var downAt: NSPoint?
    private let closeButton = NSButton()

    init(item: TrayItem, shelf: Shelf) {
        self.item = item; self.shelf = shelf
        super.init(frame: NSRect(origin: .zero, size: ItemCell.size))
        closeButton.image = symbol("xmark.circle.fill", 15)
        closeButton.contentTintColor = Palette.ghost
        closeButton.isBordered = false
        closeButton.frame = NSRect(x: ItemCell.size.width - 26, y: ItemCell.size.height - 26, width: 22, height: 22)
        closeButton.target = self; closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel("消す")
        closeButton.isHidden = true
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel(shelf.store.title(item))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func close() { shelf?.store.remove(item.id) }

    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func draw(_ dirty: NSRect) {
        guard let shelf else { return }
        let b = bounds.insetBy(dx: 2, dy: 2)
        if selected || hover {
            (selected ? Palette.accentWash : Palette.surface2).setFill()
            NSBezierPath(roundedRect: b, xRadius: 12, yRadius: 12).fill()
        }
        let missing = shelf.store.isMissing(item)
        let alpha: CGFloat = missing ? 0.35 : 1
        let art = NSRect(x: b.midX - 28, y: b.maxY - 64, width: 56, height: 56)
        let title = shelf.store.title(item)

        switch item.kind {
        case .files, .image:
            let urls = shelf.store.urls(item)
            if item.count > 1 {
                // 山：後ろに2枚の紙
                for k in [2, 1] {
                    let r = art.offsetBy(dx: CGFloat(k) * 4, dy: CGFloat(k) * 3).insetBy(dx: 4, dy: 4)
                    Palette.surface.setFill(); Palette.line2.setStroke()
                    let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8); p.fill(); p.lineWidth = 1; p.stroke()
                }
            }
            if let u = urls.compactMap({ $0 }).first {
                let img = Thumbs.shared.image(for: u, size: 112) { [weak self] in self?.needsDisplay = true }
                img.draw(in: fit(img.size, in: art), from: .zero, operation: .sourceOver, fraction: alpha)
            } else {
                drawSymbol("questionmark.folder", in: art, size: 30, color: Palette.ghost, weight: .light)
            }
            if item.count > 1 { badge("\(item.count)", near: art) }
        case .url:
            Palette.surface.setFill(); Palette.line.setStroke()
            let p = NSBezierPath(roundedRect: art.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12); p.fill(); p.stroke()
            drawSymbol("link", in: art, size: 24, color: Palette.inkSoft)
        case .text:
            let card = NSRect(x: b.minX + 10, y: b.minY + 22, width: b.width - 20, height: b.height - 30)
            Palette.surface.setFill(); Palette.line.setStroke()
            let p = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8); p.fill(); p.stroke()
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping; para.lineSpacing = 1
            let s = NSAttributedString(string: (item.text ?? "").replacingOccurrences(of: "\n", with: " "), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.ink, .paragraphStyle: para])
            s.draw(with: card.insetBy(dx: 7, dy: 6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if item.kind != .text {
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingMiddle
            NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.inkSoft.withAlphaComponent(missing ? 0.6 : 1),
                .paragraphStyle: para]).draw(in: NSRect(x: b.minX + 6, y: b.minY + 4, width: b.width - 12, height: 15))
        } else {
            drawSymbol("text.alignleft", in: NSRect(x: b.minX, y: b.minY + 2, width: b.width, height: 18), size: 11, color: Palette.ghost)
        }
    }

    private func fit(_ s: NSSize, in r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func badge(_ s: String, near art: NSRect) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                             .foregroundColor: Palette.paper])
        let w = max(20, str.size().width + 10)
        let r = NSRect(x: art.maxX - w / 2 + 2, y: art.minY - 2, width: w, height: 20)
        Palette.accent2.setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        str.draw(at: NSPoint(x: r.midX - str.size().width / 2, y: r.midY - str.size().height / 2))
    }

    // ── 操作 ──

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downAt = e.locationInWindow
        shelf?.select(item.id)
        if e.clickCount == 2 { shelf?.open(item); downAt = nil }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let shelf, let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let writers = shelf.writers(item)
        guard !writers.isEmpty else { NSSound.beep(); return }
        let snap = bitmapImageRepForCachingDisplay(in: bounds)
        if let snap { cacheDisplay(in: bounds, to: snap) }
        let pic = NSImage(size: bounds.size); if let snap { pic.addRepresentation(snap) }
        let items = writers.enumerated().map { k, w -> NSDraggingItem in
            let it = NSDraggingItem(pasteboardWriter: w)
            it.setDraggingFrame(bounds.offsetBy(dx: CGFloat(min(k, 3)) * 3, dy: CGFloat(min(k, 3)) * -3), contents: k == 0 ? pic : nil)
            return it
        }
        let s = beginDraggingSession(with: items, event: e, source: self)
        s.animatesToStartingPositionsOnCancelOrFail = true
        s.draggingFormation = .pile
    }

    override func mouseUp(with e: NSEvent) { downAt = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        shelf?.select(item.id)
        return shelf?.contextMenu(for: item)
    }

    // ── ドラッグの出し手 ──

    /// いつも「コピー」だけを許す＝同じディスクの Finder に落としても元は動かない。ゴミ箱にも捨てられない
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        Shelf.outgoingMask
    }
    func draggingSession(_ s: NSDraggingSession, willBeginAt p: NSPoint) { shelf?.draggingOut = true }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        shelf?.dragOutEnded(item, operation: operation)
    }
}

// MARK: - 棚の中身（ドロップを受ける）

final class TrayView: NSView {
    weak var shelf: Shelf?
    var dropping = false { didSet { needsDisplay = true } }
    let scroll = NSScrollView()
    let list = FlippedView()
    let trash = NSButton()

    init(frame: NSRect, shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.frame = NSRect(x: 6, y: 38, width: frame.width - 12, height: frame.height - 44)
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        trash.image = symbol("trash", 14); trash.contentTintColor = Palette.ghost
        trash.isBordered = false
        trash.frame = NSRect(x: frame.width / 2 - 22, y: 4, width: 44, height: 30)
        trash.target = self; trash.action = #selector(clearAll)
        trash.setAccessibilityLabel("全部消す"); trash.toolTip = "全部消す"
        addSubview(trash)
        registerForDraggedTypes(Intake.acceptedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clearAll() { shelf?.store.removeAll() }

    func reload(selected: UUID?) {
        guard let shelf else { return }
        list.subviews.forEach { $0.removeFromSuperview() }
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        for it in shelf.store.items {
            let c = ItemCell(item: it, shelf: shelf)
            c.frame.origin = NSPoint(x: (w - ItemCell.size.width) / 2, y: y)
            c.selected = it.id == selected
            list.addSubview(c); y += ItemCell.size.height + 4
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
        trash.isHidden = shelf.store.items.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: b, xRadius: 16, yRadius: 16)
        Palette.paper.setFill(); p.fill()
        (dropping ? Palette.accent : Palette.line2).setStroke()
        p.lineWidth = dropping ? 2 : 1; p.stroke()
        if shelf?.store.items.isEmpty ?? true {
            // 空：置けることが分かる線画ひとつ
            let r = NSRect(x: 14, y: 14, width: bounds.width - 28, height: bounds.height - 28)
            let d = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            d.setLineDash([6, 5], count: 2, phase: 0); d.lineWidth = 1.5
            (dropping ? Palette.accent : Palette.line2).setStroke(); d.stroke()
            drawSymbol("tray.and.arrow.down", in: r, size: 30, color: dropping ? Palette.accent2 : Palette.ghost, weight: .light)
        }
    }

    // ── ドロップの受け手 ──

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if s.draggingSource is ItemCell { return [] }        // 自分の棚から出したものは受けない（二重にしない）
        dropping = true; shelf?.dragHovering = true
        return Intake.operation(s.draggingSourceOperationMask)
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        s.draggingSource is ItemCell ? [] : Intake.operation(s.draggingSourceOperationMask)
    }
    override func draggingExited(_ s: NSDraggingInfo?) { dropping = false; shelf?.dragHovering = false }
    override func draggingEnded(_ s: NSDraggingInfo) { dropping = false; shelf?.dragHovering = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dropping = false
        guard !(s.draggingSource is ItemCell), let shelf else { return false }
        return shelf.take(s.draggingPasteboard)
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// しまったときの取っ手（端に細く残る）。触れる・ドラッグが来ると棚が出る
final class TabView: NSView {
    weak var shelf: Shelf?
    var right = true
    init(frame: NSRect, shelf: Shelf) {
        self.shelf = shelf
        super.init(frame: frame)
        registerForDraggedTypes(Intake.acceptedTypes)
        setAccessibilityRole(.button); setAccessibilityLabel("トレイ")
        // 見張りの間隔を待たず、マウスが入ったらすぐ出す
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { shelf?.show() }
    required init?(coder: NSCoder) { fatalError() }

    /// 入った知らせ：アクセントの色で2回またたく（棚は出さない＝作業のじゃまをしない）
    private(set) var lit = false
    private var blinks: Timer?
    func pulse() {
        blinks?.invalidate()
        var n = 0
        lit = true; needsDisplay = true
        blinks = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n += 1; self.lit = n < 3 && n % 2 == 0; self.needsDisplay = true
            if n >= 3 { t.invalidate(); self.blinks = nil }
        }
        setAccessibilityValue("入りました")
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func draw(_ dirty: NSRect) {
        let b = bounds
        let r = NSRect(x: right ? b.minX : b.minX - 10, y: b.minY, width: b.width + 10, height: b.height)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (lit ? Palette.accentWash : Palette.paper).setFill(); p.fill()
        (lit ? Palette.accent : Palette.line2).setStroke(); p.lineWidth = 1; p.stroke()
        // つまみ（縦の短い線2本）
        (lit ? Palette.accent : Palette.ghost).setStroke()
        for dx in [-2.0, 2.0] {
            let g = NSBezierPath(); g.lineWidth = 1.5; g.lineCapStyle = .round
            g.move(to: NSPoint(x: b.midX + dx, y: b.midY - 9)); g.line(to: NSPoint(x: b.midX + dx, y: b.midY + 9)); g.stroke()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { shelf?.show() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { shelf?.show(); return Intake.operation(s.draggingSourceOperationMask) }
}

/// 鍵になれる（スペース・削除キーを受ける）が、アプリを前に出さない板
final class TrayPanel: NSPanel {
    weak var shelf: Shelf?
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49: shelf?.togglePreview()                 // スペース
        case 51, 117: shelf?.removeSelected()           // 削除
        case 53: shelf?.hide()                          // Esc
        case 125: shelf?.moveSelection(1)               // ↓
        case 126: shelf?.moveSelection(-1)              // ↑
        default: super.keyDown(with: e)
        }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = shelf; panel.delegate = shelf }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

// MARK: - 棚の出し入れ

final class Shelf: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let outgoingMask: NSDragOperation = .copy
    static let size = NSSize(width: 156, height: 3 * (ItemCell.size.height + 4) + 50)   // 3つ見える高さ
    static let tabSize = NSSize(width: 14, height: 72)

    enum State { case hidden, shown, tucked }
    let store: Store
    private(set) var state: State = .hidden
    private var panel: TrayPanel!
    private var tabPanel: NSPanel!
    private var view: TrayView!
    private var tab: TabView!
    var tabLit: Bool { tab.lit }    // 自己テスト用
    private var selected: UUID?
    private var ticker: Timer?
    private var outsideSince: Date?
    var draggingOut = false
    var dragHovering = false
    var systemDragActive = false
    var onDragOutEnded: (() -> Void)?

    // 設定（メニューから）
    var side: String { UserDefaults.standard.string(forKey: "side") ?? "right" }
    var removeAfterDrag: Bool { UserDefaults.standard.object(forKey: "removeAfterDrag") as? Bool ?? true }
    var autoTuck: Bool { UserDefaults.standard.object(forKey: "autoTuck") as? Bool ?? true }

    init(store: Store) {
        self.store = store
        super.init()
        panel = TrayPanel(contentRect: NSRect(origin: .zero, size: Shelf.size),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.shelf = self
        view = TrayView(frame: NSRect(origin: .zero, size: Shelf.size), shelf: self)
        setup(panel, view)
        panel.becomesKeyOnlyIfNeeded = true
        tabPanel = NSPanel(contentRect: NSRect(origin: .zero, size: Shelf.tabSize),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        tab = TabView(frame: NSRect(origin: .zero, size: Shelf.tabSize), shelf: self)
        setup(tabPanel, tab)
        store.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func setup(_ p: NSPanel, _ v: NSView) {
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.isMovable = false
        p.contentView = v
    }

    func reload() {
        if let s = selected, !store.items.contains(where: { $0.id == s }) { selected = nil }
        view.reload(selected: selected)
        if store.items.isEmpty && state == .tucked { hide() }
    }

    // ── 位置（画面の端・縦の真ん中） ──

    /// 出ている位置と、しまった位置（画面の外）
    static func frames(screen vf: NSRect, right: Bool, size: NSSize = Shelf.size) -> (shown: NSRect, away: NSRect, tab: NSRect) {
        let y = (vf.midY - size.height / 2).rounded()
        let shown = NSRect(x: right ? vf.maxX - size.width - 8 : vf.minX + 8, y: y, width: size.width, height: size.height)
        let away = NSRect(x: right ? vf.maxX + 2 : vf.minX - size.width - 2, y: y, width: size.width, height: size.height)
        let t = Shelf.tabSize
        let tab = NSRect(x: right ? vf.maxX - t.width : vf.minX, y: (vf.midY - t.height / 2).rounded(), width: t.width, height: t.height)
        return (shown, away, tab)
    }

    private var currentScreen: NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func animate(_ p: NSPanel, to r: NSRect, done: (() -> Void)? = nil) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduce ? 0 : 0.2
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            p.animator().setFrame(r, display: true)
        }, completionHandler: done)
    }

    func show() {
        let f = Shelf.frames(screen: currentScreen.visibleFrame, right: side == "right")
        tabPanel.orderOut(nil)
        if state != .shown {
            Thumbs.shared.forget()
            view.reload(selected: selected)            // 元が動いた・消えたを映し直す
            panel.setFrame(f.away, display: false)
            panel.orderFrontRegardless()
            animate(panel, to: f.shown)
        }
        state = .shown; outsideSince = nil
        startTicker()
    }

    func hide() {
        guard state != .hidden else { return }
        let f = Shelf.frames(screen: panel.screen?.visibleFrame ?? currentScreen.visibleFrame, right: side == "right")
        if state == .shown { animate(panel, to: f.away) { [weak self] in if self?.state != .shown { self?.panel.orderOut(nil) } } }
        tabPanel.orderOut(nil)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        state = .hidden; stopTicker()
    }

    /// 端にしまう（取っ手だけ残す）
    func tuck() {
        guard !store.items.isEmpty else { hide(); return }
        let f = Shelf.frames(screen: panel.screen?.visibleFrame ?? currentScreen.visibleFrame, right: side == "right")
        if state == .shown { animate(panel, to: f.away) { [weak self] in if self?.state != .shown { self?.panel.orderOut(nil) } } }
        tab.right = side == "right"; tab.needsDisplay = true
        tabPanel.setFrame(f.tab, display: true)
        tabPanel.orderFrontRegardless()
        state = .tucked
        startTicker()
    }

    /// 棚を出していないときに中身が入った（ショットの「トレイへ」・このアプリで開く）：取っ手を出してまたたかせる
    func announceAdded() {
        if state == .shown { return }
        tuck()
        tab.pulse()
    }

    func toggle() { state == .shown ? (store.items.isEmpty ? hide() : (autoTuck ? tuck() : hide())) : show() }

    /// 起動したとき：置いてある物があれば取っ手を出す
    func restore() { if !store.items.isEmpty { autoTuck ? tuck() : show() } }

    // ── ドラッグの始まり・終わり（DragWatcher から） ──

    func systemDragBegan() { systemDragActive = true; show() }

    func systemDragEnded() {
        systemDragActive = false
        // 落とした直後の取り込み（約束のファイルは少し遅れる）を待ってから決める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.systemDragActive, self.state == .shown else { return }
            if self.store.items.isEmpty { self.hide() } else { self.outsideSince = Date() }
        }
    }

    // ── 見張り（マウスが棚から離れて少したったら端にしまう） ──

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        let m = NSEvent.mouseLocation
        switch state {
        case .tucked:
            if NSMouseInRect(m, tabPanel.frame.insetBy(dx: -2, dy: 0), false) { show() }
        case .shown:
            let inside = NSMouseInRect(m, panel.frame.insetBy(dx: -12, dy: -12), false)
            let ql = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            if inside || systemDragActive || draggingOut || dragHovering || ql { outsideSince = nil; return }
            if outsideSince == nil { outsideSince = Date() }
            if Date().timeIntervalSince(outsideSince!) > 1.2 {
                if store.items.isEmpty { hide() } else if autoTuck { tuck() }
                outsideSince = nil
            }
        case .hidden: stopTicker()
        }
    }

    // ── 受け取り ──

    /// ドロップ・ファイルを開く・貼り付けで受けた中身をトレイに入れる
    @discardableResult
    func take(_ pb: NSPasteboard) -> Bool {
        switch Intake.read(pb) {
        case .files(let us): return store.addFiles(us) != nil
        case .promises:
            let rs = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
            receive(rs); return true
        case .image(let d): return store.addImage(png: d) != nil
        case .url(let u): store.addURL(u); return true
        case .text(let s): store.addText(s); return true
        case .none: return false
        }
    }

    private let promiseQueue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInitiated; return q }()

    /// 写真アプリなど「あとでファイルを渡す」ドラッグ：アプリの中に受け取る（元が無いので中身を持つ）
    private func receive(_ rs: [NSFilePromiseReceiver]) {
        let id = UUID(), dir = store.ownedDir(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 受け取りの知らせは1ファイルごとに来る。最後の知らせから少し静かになったら1つの項目にまとめる
        var generation = 0
        var added = false
        func settle() {
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, g == generation, !added else { return }
                let got = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                guard !got.isEmpty else { return }
                added = true
                self.store.addOwnedFiles(id: id, names: got)
            }
        }
        for r in rs {
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { _, _ in
                DispatchQueue.main.async { settle() }
            }
        }
        // 1つも届かなかったら空のフォルダを片付ける
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !added, !self.store.items.contains(where: { $0.id == id }) else { return }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // ── 出す ──

    func writers(_ it: TrayItem) -> [NSPasteboardWriting] {
        switch it.kind {
        case .files, .image: return store.urls(it).compactMap { $0.map { $0 as NSURL } }
        case .url: return URL(string: it.text ?? "").map { [$0 as NSURL] } ?? []
        case .text: return [(it.text ?? "") as NSString]
        }
    }

    func dragOutEnded(_ it: TrayItem, operation: NSDragOperation) {
        draggingOut = false
        onDragOutEnded?()
        if !operation.isEmpty && removeAfterDrag { store.remove(it.id) }
    }

    // ── 選ぶ・開く・のぞく ──

    func select(_ id: UUID) {
        selected = id
        for case let c as ItemCell in view.list.subviews { c.selected = c.item.id == id }
        panel.makeKey()
    }

    func moveSelection(_ d: Int) {
        guard !store.items.isEmpty else { return }
        let i = store.items.firstIndex { $0.id == selected } ?? -d
        let n = max(0, min(store.items.count - 1, i + d))
        select(store.items[n].id)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    var selectedItem: TrayItem? { store.items.first { $0.id == selected } }

    func removeSelected() { if let s = selected { store.remove(s) } }

    func open(_ it: TrayItem) {
        switch it.kind {
        case .files, .image: store.urls(it).compactMap { $0 }.forEach { NSWorkspace.shared.open($0) }
        case .url: if let u = URL(string: it.text ?? "") { NSWorkspace.shared.open(u) }
        case .text: togglePreview()
        }
    }

    func reveal(_ it: TrayItem) {
        let us = store.urls(it).compactMap { $0 }
        if !us.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(us) }
    }

    func copy(_ it: TrayItem) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.writeObjects(writers(it))
    }

    func togglePreview() {
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil); return }
        guard selectedItem != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        ql.makeKeyAndOrderFront(nil)
    }

    private var previewURLs: [URL] {
        guard let it = selectedItem else { return [] }
        switch it.kind {
        case .files, .image: return store.urls(it).compactMap { $0 }
        case .text, .url:
            // 文字はのぞく用に一時ファイルへ（トレイの中身ではない）
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("tsumiki-tray-preview.txt")
            try? (it.text ?? "").write(to: u, atomically: true, encoding: .utf8)
            return [u]
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, [125, 126].contains(event.keyCode) { moveSelection(event.keyCode == 125 ? 1 : -1); return true }
        return false
    }

    func contextMenu(for it: TrayItem) -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ sym: String, _ f: @escaping () -> Void) {
            let x = ClosureItem(title: t, f); x.image = symbol(sym, 13); m.addItem(x)
        }
        add("のぞく", "eye") { [weak self] in self?.togglePreview() }
        add("開く", "arrow.up.forward.app") { [weak self] in self?.open(it) }
        if it.kind == .files || it.kind == .image { add("Finder で表示", "folder") { [weak self] in self?.reveal(it) } }
        add("コピー", "doc.on.doc") { [weak self] in self?.copy(it) }
        if it.kind == .files && it.count > 1 { add("ばらす", "square.stack.3d.down.right") { [weak self] in self?.store.split(it.id) } }
        m.addItem(.separator())
        add("消す", "xmark") { [weak self] in self?.store.remove(it.id) }
        return m
    }

    // 自己テスト・見本の絵用
    var trayView: TrayView { view }
    var tabView: TabView { tab }
}

/// 押すと closure を呼ぶメニュー項目
final class ClosureItem: NSMenuItem {
    private let f: () -> Void
    init(title: String, key: String = "", _ f: @escaping () -> Void) {
        self.f = f
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { f() }
}
