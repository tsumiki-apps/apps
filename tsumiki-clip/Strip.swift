// 呼び出すと画面の下に出る帯。上に検索とピンボードの札、下に履歴のカードが横に並ぶ。
// 前のアプリを前に出したまま（nonactivating）キーだけ受ける＝Enter で前のアプリにそのまま貼れる。
import AppKit
import Carbon
import ImageIO

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 調べ用の記録（環境変数 TSUMIKI_CLIP_DEBUG=1 のときだけ。履歴の中身は書かない）
enum Debug {
    static let on = ProcessInfo.processInfo.environment["TSUMIKI_CLIP_DEBUG"] == "1"
    static func log(_ s: String) {
        guard on, let dir = ProcessInfo.processInfo.environment["TSUMIKI_CLIP_DIR"] else { return }
        let u = URL(fileURLWithPath: dir).appendingPathComponent("debug.log")
        let line = Data("\(Date().timeIntervalSince1970) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: u) }
    }
}

final class Flipped: NSView { override var isFlipped: Bool { true } }

final class Strip: NSObject, NSWindowDelegate {
    let store: Store
    var onPaste: ((Clip, PasteMode) -> Void)?
    var onSettings: (() -> Void)?
    let panel: KeyPanel
    let search = NSTextField()
    private let bar = Flipped()
    private let chips = NSStackView()
    private let scroll = NSScrollView()
    private let row = Flipped()
    private let empty = NSStackView()
    private let pauseMark = NSImageView()
    private(set) var board: UUID?
    private(set) var items: [Clip] = []
    private var cards: [Card] = []
    private(set) var sel = 0
    private var monitor: Any?
    private var modal = false
    /// 帯を出す前に手前にあったアプリ（閉じる・貼るときにそこへ戻す）
    private var prevApp: NSRunningApplication?
    static let height: CGFloat = 292
    static let cardW: CGFloat = 196
    static let gap: CGFloat = 12
    static let maxCards = 200

    init(store: Store) {
        self.store = store
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: Strip.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        build()
    }

    // MARK: 組み立て

    private func build() {
        let root = Flipped()
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]     // 上の2つの角だけ丸く
        root.layer?.borderWidth = 1
        panel.contentView = root

        search.placeholderString = "検索"
        search.font = .systemFont(ofSize: 16)
        search.focusRingType = .none
        search.isBezeled = false; search.drawsBackground = false
        search.cell?.usesSingleLineMode = true
        search.target = self; search.action = #selector(searchEnter)
        NotificationCenter.default.addObserver(self, selector: #selector(searchChanged), name: NSControl.textDidChangeNotification, object: search)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 9; bar.layer?.borderWidth = 1.5
        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "検索")!)
        glass.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        bar.addSubview(glass); bar.addSubview(search)
        glass.frame = NSRect(x: 9, y: 8, width: 18, height: 18)
        search.frame = NSRect(x: 32, y: 6, width: 200, height: 22)
        root.addSubview(bar)

        chips.orientation = .horizontal; chips.spacing = 6
        root.addSubview(chips)

        pauseMark.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "一時停止中")
        pauseMark.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        pauseMark.toolTip = "一時停止中（コピーを記録していない）"
        root.addSubview(pauseMark)
        let gear = HoverButton(symbol: "gearshape", tip: "設定") { [weak self] in self?.hide(restore: false); self?.onSettings?() }
        gear.identifier = .init("gear")
        root.addSubview(gear)

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        root.addSubview(scroll)

        let ei = NSImageView(image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)!)
        ei.symbolConfiguration = .init(pointSize: 30, weight: .light)
        let el = NSTextField(labelWithString: "なし")
        el.font = .systemFont(ofSize: 14)
        empty.orientation = .vertical; empty.spacing = 8
        empty.addArrangedSubview(ei); empty.addArrangedSubview(el)
        root.addSubview(empty)
        applyColors()
    }

    private func applyColors() {
        guard let root = panel.contentView else { return }
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = Palette.paper.cgColor
            root.layer?.borderColor = Palette.line2.cgColor
            bar.layer?.backgroundColor = Palette.surface.cgColor
            bar.layer?.borderColor = (search.currentEditor() != nil ? Palette.accent : Palette.line).cgColor
        }
        search.textColor = Palette.ink
        (bar.subviews.first as? NSImageView)?.contentTintColor = Palette.sub
        pauseMark.contentTintColor = Palette.warn
        for v in empty.arrangedSubviews { (v as? NSImageView)?.contentTintColor = Palette.sub; (v as? NSTextField)?.textColor = Palette.sub }
    }

    /// 幅に合わせて並べる（テストからも呼ぶ）
    func layout(width: CGFloat) {
        guard let root = panel.contentView else { return }
        let h = Strip.height
        root.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let pad: CGFloat = 20
        let searchW = min(280, max(180, width * 0.2))
        bar.frame = NSRect(x: pad, y: 14, width: searchW, height: 34)
        search.frame = NSRect(x: 32, y: 7, width: searchW - 40, height: 21)
        let gear = root.subviews.first { $0.identifier?.rawValue == "gear" }
        gear?.frame = NSRect(x: width - pad - 30, y: 16, width: 30, height: 30)
        pauseMark.frame = NSRect(x: width - pad - 64, y: 19, width: 24, height: 24)
        pauseMark.isHidden = !Prefs.paused
        let chipsX = bar.frame.maxX + 14
        chips.frame = NSRect(x: chipsX, y: 15, width: max(0, width - chipsX - pad - 72), height: 32)
        let top: CGFloat = 60
        scroll.frame = NSRect(x: 0, y: top, width: width, height: h - top - 6)
        let ch = scroll.frame.height - 14
        row.frame = NSRect(x: 0, y: 0, width: max(width, pad * 2 + CGFloat(cards.count) * (Strip.cardW + Strip.gap) - Strip.gap), height: scroll.frame.height)
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: pad + CGFloat(i) * (Strip.cardW + Strip.gap), y: 2, width: Strip.cardW, height: ch)
        }
        empty.frame = NSRect(x: 0, y: top + 40, width: width, height: 80)
        empty.isHidden = !cards.isEmpty
    }

    // MARK: 出す・しまう

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: Strip.height), display: false)
        board = board.flatMap { id in store.boards.contains { $0.id == id } ? id : nil }
        sel = 0
        reload()
        layout(width: vf.width)
        // 手前にしないまま出した帯は、キーを1つ押すと受け手を外される（実機で確認）。
        // だから自分を手前にして受け、閉じる・貼るときに元のアプリへ戻す
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != getpid() { prevApp = f }
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(search)
        applyColors()
        installMonitor()
        Debug.log("show key=\(panel.isKeyWindow) first=\(String(describing: panel.firstResponder.map { type(of: $0) }))")
    }

    /// restore: 元のアプリを手前に戻す（外をクリックして閉じたとき・設定を開くときは戻さない）
    func hide(restore: Bool = true) {
        Debug.log("hide restore=\(restore)")
        removeMonitor()
        panel.orderOut(nil)
        search.stringValue = ""
        if restore, let p = prevApp, !p.isTerminated {
            NSApp.yieldActivation(to: p)
            p.activate()
        }
        prevApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        Debug.log("resignKey")
        if !modal && isVisible { hide(restore: false) }
    }

    // MARK: 中身

    func reload() {
        items = Array(store.list(board: board, query: search.stringValue).prefix(Strip.maxCards))
        cards.forEach { $0.removeFromSuperview() }
        cards = items.enumerated().map { i, c in
            let card = Card(clip: c, store: store, number: i < 9 ? i + 1 : nil, boardColor: boardColor(c.board))
            card.onClick = { [weak self] n in self?.select(i); if n >= 2 { self?.pasteSelected(.normal) } }
            card.onMenu = { [weak self] e in self?.select(i); self?.showMenu(for: i, event: e) }
            row.addSubview(card)
            return card
        }
        sel = items.isEmpty ? 0 : min(sel, items.count - 1)
        rebuildChips()
        applyColors()
        layout(width: panel.contentView?.frame.width ?? panel.frame.width)
        updateSelection(scroll: false)
    }

    private func boardColor(_ id: UUID?) -> NSColor? {
        guard let id, let b = store.boards.first(where: { $0.id == id }) else { return nil }
        return Palette.pigments[b.color % Palette.pigments.count]
    }

    private func rebuildChips() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hist = Chip(title: "履歴", symbol: "clock", color: nil, on: board == nil) { [weak self] in self?.switchBoard(nil) }
        chips.addArrangedSubview(hist)
        for b in store.boards {
            let c = Chip(title: b.name, symbol: nil, color: Palette.pigments[b.color % Palette.pigments.count], on: board == b.id) { [weak self] in
                self?.switchBoard(b.id)
            }
            c.onMenu = { [weak self] e in self?.boardMenu(b, event: e) }
            chips.addArrangedSubview(c)
        }
        let add = HoverButton(symbol: "plus", tip: "ピンボードを作る") { [weak self] in self?.newBoard(pinning: nil) }
        chips.addArrangedSubview(add)
    }

    func switchBoard(_ id: UUID?) {
        board = id; sel = 0
        reload()
        panel.makeFirstResponder(search)
    }

    /// ⌘← ⌘→ で札を動かす
    func moveBoard(_ d: Int) {
        let ids: [UUID?] = [nil] + store.boards.map { Optional($0.id) }
        guard let i = ids.firstIndex(where: { $0 == board }) else { return }
        switchBoard(ids[(i + d + ids.count) % ids.count])
    }

    func select(_ i: Int) {
        guard !items.isEmpty else { return }
        sel = max(0, min(items.count - 1, i))
        updateSelection(scroll: true)
    }

    private func updateSelection(scroll doScroll: Bool) {
        for (i, c) in cards.enumerated() { c.selected = i == sel }
        if doScroll, sel < cards.count {
            let r = cards[sel].frame.insetBy(dx: -20, dy: 0)
            row.scrollToVisible(r)
        }
    }

    var selected: Clip? { items.indices.contains(sel) ? items[sel] : nil }

    func pasteSelected(_ mode: PasteMode) {
        Debug.log("pasteSelected sel=\(sel) n=\(items.count)")
        guard let c = selected else { NSSound.beep(); return }
        hide()
        onPaste?(c, mode)
    }

    @objc private func searchChanged() { sel = 0; reload() }
    @objc private func searchEnter() { }

    // MARK: キー

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            Debug.log("monitor key=\(e.keyCode) win=\(e.window === self?.panel) key=\(self?.panel.isKeyWindow ?? false)")
            guard let self, e.window === self.panel else { return e }
            // 日本語の変換中（未確定の文字がある間）は Enter・矢印・Esc を変換に渡す
            if let ed = self.panel.firstResponder as? NSTextView, ed.hasMarkedText() { return e }
            return self.handleKey(code: Int(e.keyCode), flags: e.modifierFlags) ? nil : e
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 帯の上で押されたキー。使ったら true（テストからも呼ぶ）
    @discardableResult
    func handleKey(code: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let f = flags.intersection([.command, .shift, .option, .control])
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        switch code {
        case kVK_Escape:
            if !search.stringValue.isEmpty { search.stringValue = ""; searchChanged() } else { hide() }
        case kVK_LeftArrow:
            if f.contains(.command) { moveBoard(-1) } else { select(sel - 1) }
        case kVK_RightArrow:
            if f.contains(.command) { moveBoard(1) } else { select(sel + 1) }
        case kVK_UpArrow, kVK_DownArrow:
            break
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pasteSelected(f.contains(.shift) ? .plain : .normal)
        case kVK_Delete where f == .command, kVK_ForwardDelete where f == .command:
            deleteSelected()
        case kVK_ANSI_Comma where f == .command:
            hide(restore: false); onSettings?()
        case kVK_ANSI_F where f == .command:
            panel.makeFirstResponder(search)
        case _ where f == .command && digits.contains(code):
            let n = digits.firstIndex(of: code)!
            guard n < items.count else { NSSound.beep(); return true }
            sel = n; pasteSelected(.normal)
        case _ where f == [.command, .shift] && digits.contains(code):
            let n = digits.firstIndex(of: code)!
            guard n < items.count else { NSSound.beep(); return true }
            sel = n; pasteSelected(.plain)
        default:
            return false
        }
        return true
    }

    func deleteSelected() {
        guard let c = selected else { return }
        store.remove(c.id)
        reload()
    }

    // MARK: 右クリック

    private func showMenu(for i: Int, event: NSEvent) {
        guard items.indices.contains(i) else { return }
        let m = menu(for: items[i])
        NSMenu.popUpContextMenu(m, with: event, for: cards[i])
    }

    /// カードの右クリックの中身（テストからも呼ぶ）
    func menu(for c: Clip) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func item(_ t: String, _ sym: String, _ f: @escaping () -> Void) -> NSMenuItem {
            let it = BlockItem(title: t, block: f)
            it.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            return it
        }
        m.addItem(item("貼る", "arrow.down.doc") { [weak self] in self?.pasteSelected(.normal) })
        if c.kind == .text || c.kind == .link {
            m.addItem(item("書式なしで貼る", "textformat") { [weak self] in self?.pasteSelected(.plain) })
            let tidy = NSMenuItem(title: "整えて貼る", action: nil, keyEquivalent: "")
            tidy.image = NSImage(systemSymbolName: "wand.and.rays", accessibilityDescription: nil)
            let sub = NSMenu()
            for t in Tidy.allCases {
                let it = item(t.name, t.symbol) { [weak self] in self?.pasteSelected(.tidy(t)) }
                it.isEnabled = t.apply(c.text) != c.text      // 変わらないものは押せない
                sub.addItem(it)
            }
            tidy.submenu = sub
            m.addItem(tidy)
        }
        m.addItem(.separator())
        let pin = NSMenuItem(title: "ピンボードへ", action: nil, keyEquivalent: "")
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        let sub = NSMenu()
        for b in store.boards where b.id != c.board {
            let it = item(b.name, "circle.fill") { [weak self] in self?.store.pin(c.id, to: b.id); self?.reload() }
            it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [Palette.pigments[b.color % Palette.pigments.count]]))
            sub.addItem(it)
        }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(item("新しいピンボード…", "plus") { [weak self] in self?.newBoard(pinning: c.id) })
        pin.submenu = sub
        m.addItem(pin)
        m.addItem(item("名前を付ける…", "character.cursor.ibeam") { [weak self] in self?.renameClip(c) })
        m.addItem(.separator())
        m.addItem(item(c.board == nil ? "消す" : "ピンボードから外す", "trash") { [weak self] in self?.store.remove(c.id); self?.reload() })
        return m
    }

    private func boardMenu(_ b: Board, event: NSEvent) {
        let m = NSMenu()
        let r = BlockItem(title: "名前を変える…") { [weak self] in
            guard let self, let name = self.ask("ピンボードの名前", b.name) else { return }
            self.store.renameBoard(b.id, name); self.reload()
        }
        r.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)
        let d = BlockItem(title: "消す") { [weak self] in
            guard let self else { return }
            if self.board == b.id { self.board = nil }
            self.store.removeBoard(b.id); self.reload()
        }
        d.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        m.addItem(r); m.addItem(.separator()); m.addItem(d)
        NSMenu.popUpContextMenu(m, with: event, for: chips)
    }

    private func newBoard(pinning id: UUID?) {
        guard let name = ask("ピンボードの名前", "") else { return }
        let b = store.addBoard(name)
        if let id { store.pin(id, to: b.id) }
        reload()
    }

    private func renameClip(_ c: Clip) {
        guard let t = ask("名前", c.title ?? "") else { return }
        store.rename(c.id, t); reload()
    }

    /// 名前を入れてもらう小さな窓（帯は閉じないでおく）
    private func ask(_ title: String, _ value: String) -> String? {
        modal = true
        defer { modal = false; panel.makeKey(); panel.makeFirstResponder(search) }
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "やめる")
        let f = NSTextField(string: value)
        f.font = .systemFont(ofSize: 16)
        f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = f
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return r == .alertFirstButtonReturn && !s.isEmpty ? s : nil
    }
}

// MARK: - 部品

final class BlockItem: NSMenuItem {
    let block: () -> Void
    init(title: String, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func run() { block() }
}

/// 線画アイコンだけのボタン（指を乗せると説明）
final class HoverButton: NSButton {
    let block: () -> Void
    init(symbol: String, tip: String, block: @escaping () -> Void) {
        self.block = block
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        symbolConfiguration = .init(pointSize: 15, weight: .regular)
        isBordered = false; bezelStyle = .regularSquare
        contentTintColor = Palette.inkMid
        toolTip = tip
        target = self; action = #selector(run)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func run() { block() }
}

/// 上の札（履歴・ピンボード）
final class Chip: NSView {
    let block: () -> Void
    var onMenu: ((NSEvent) -> Void)?
    private let label: NSTextField
    private let on: Bool

    init(title: String, symbol: String?, color: NSColor?, on: Bool, block: @escaping () -> Void) {
        self.block = block; self.on = on
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15; layer?.borderWidth = 1.5
        label.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = []
        if let symbol {
            let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            i.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            i.contentTintColor = on ? Palette.paper : Palette.inkMid
            views.append(i)
        }
        if let color {
            let dot = NSView(); dot.wantsLayer = true
            dot.layer?.cornerRadius = 4; dot.layer?.backgroundColor = color.cgColor
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            views.append(dot)
        }
        views.append(label)
        let s = NSStackView(views: views); s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (on ? Palette.ink : Palette.surface).cgColor
        layer?.borderColor = (on ? Palette.ink : Palette.line).cgColor
        label.textColor = on ? Palette.paper : Palette.ink
    }
    override var wantsUpdateLayer: Bool { true }
    override func mouseDown(with event: NSEvent) { block() }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

/// 履歴のカード1枚
final class Card: NSView {
    let clip: Clip
    var onClick: ((Int) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var selected = false { didSet { needsDisplay = true; updateLayer() } }
    private let boardColor: NSColor?
    static let thumbs = NSCache<NSString, NSImage>()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(clip: Clip, store: Store, number: Int?, boardColor: NSColor?) {
        self.clip = clip; self.boardColor = boardColor
        super.init(frame: NSRect(x: 0, y: 0, width: Strip.cardW, height: 210))
        wantsLayer = true
        layer?.cornerRadius = 11
        build(store: store, number: number)
    }
    required init?(coder: NSCoder) { fatalError() }

    static let kindInfo: [Kind: (String, String)] = [.text: ("文字", "text.alignleft"), .link: ("リンク", "link"),
                                                     .image: ("画像", "photo"), .file: ("ファイル", "doc")]

    private func build(store: Store, number: Int?) {
        let (kname, ksym) = Card.kindInfo[clip.kind]!
        // 上：種類（名前を付けたら名前）とアプリのアイコン
        let icon = NSImageView(image: NSImage(systemSymbolName: ksym, accessibilityDescription: kname)!)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = boardColor ?? Palette.inkMid
        icon.frame = NSRect(x: 11, y: 9, width: 16, height: 16)
        addSubview(icon)
        let head = NSTextField(labelWithString: clip.title ?? kname)
        head.font = .systemFont(ofSize: 12, weight: clip.title == nil ? .regular : .semibold)
        head.textColor = clip.title == nil ? Palette.sub : Palette.ink
        head.lineBreakMode = .byTruncatingTail
        head.frame = NSRect(x: 31, y: 8, width: Strip.cardW - 64, height: 17)
        addSubview(head)
        if let b = clip.app, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            let ai = NSImageView(image: NSWorkspace.shared.icon(forFile: u.path))
            ai.frame = NSRect(x: Strip.cardW - 28, y: 7, width: 18, height: 18)
            ai.toolTip = clip.appName
            addSubview(ai)
        }
        // 下：いつ・⌘番号
        let when = NSTextField(labelWithString: Card.ago(clip.date))
        when.font = .systemFont(ofSize: 11); when.textColor = Palette.sub
        when.identifier = .init("when")
        addSubview(when)
        if let number {
            let n = NSTextField(labelWithString: "⌘\(number)")
            n.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); n.textColor = Palette.sub
            n.alignment = .right
            n.identifier = .init("num")
            addSubview(n)
        }
        // 中身
        let body: NSView
        switch clip.kind {
        case .text:
            let t = NSTextField(wrappingLabelWithString: String(clip.text.prefix(600)))
            t.font = .systemFont(ofSize: 13); t.textColor = Palette.ink
            t.maximumNumberOfLines = 0
            t.lineBreakMode = .byCharWrapping
            body = t
        case .link:
            let u = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
            let host = NSTextField(labelWithString: u?.host() ?? clip.text)
            host.font = .systemFont(ofSize: 14, weight: .semibold); host.textColor = Palette.ink
            host.lineBreakMode = .byTruncatingTail
            let full = NSTextField(wrappingLabelWithString: clip.text)
            full.font = .systemFont(ofSize: 11); full.textColor = Palette.accent
            full.lineBreakMode = .byCharWrapping
            let s = NSStackView(views: [host, full]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
            body = s
        case .image:
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true; iv.layer?.cornerRadius = 6
            if let u = store.imageURL(clip) { iv.image = Card.thumb(u) }
            if let w = clip.width, let h = clip.height { iv.toolTip = "\(w)×\(h)" }
            body = iv
        case .file:
            let fs = clip.files
            let iv = NSImageView(image: NSWorkspace.shared.icon(forFile: fs.first?.path ?? "/"))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.widthAnchor.constraint(equalToConstant: 56).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 56).isActive = true
            let name = NSTextField(wrappingLabelWithString: fs.first?.lastPathComponent ?? "")
            name.font = .systemFont(ofSize: 13); name.textColor = Palette.ink; name.alignment = .center
            name.maximumNumberOfLines = 2; name.lineBreakMode = .byTruncatingMiddle
            var vs: [NSView] = [iv, name]
            if fs.count > 1 {
                let more = NSTextField(labelWithString: "ほか \(fs.count - 1)")
                more.font = .systemFont(ofSize: 11); more.textColor = Palette.sub
                vs.append(more)
            }
            let s = NSStackView(views: vs); s.orientation = .vertical; s.spacing = 6
            body = s
        }
        body.identifier = .init("body")
        addSubview(body)
        toolTip = clip.kind == .text ? String(clip.text.prefix(300)) : nil
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        for v in subviews {
            switch v.identifier?.rawValue {
            case "body":
                let area = NSRect(x: 12, y: 32, width: w - 24, height: h - 32 - 28)
                if let st = v as? NSStackView {
                    // 文字の折り返しの幅を決めてから高さを測る（リンクは上・ファイルは真ん中に置く）
                    for case let t as NSTextField in st.arrangedSubviews { t.preferredMaxLayoutWidth = area.width }
                    let fh = min(area.height, st.fittingSize.height)
                    let y = clip.kind == .file ? area.minY + (area.height - fh) / 2 : area.minY
                    v.frame = NSRect(x: area.minX, y: y, width: area.width, height: fh)
                } else { v.frame = area }
            case "when": v.frame = NSRect(x: 12, y: h - 23, width: w / 2, height: 15)
            case "num": v.frame = NSRect(x: w / 2, y: h - 23, width: w / 2 - 12, height: 15)
            default: break
            }
        }
        if let s = subviews.first(where: { $0.identifier?.rawValue == "body" }) as? NSStackView, clip.kind == .file {
            s.alignment = .centerX
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = (selected ? Palette.accentWash : Palette.surface).cgColor
        layer?.borderColor = (selected ? Palette.accent : Palette.line).cgColor
        layer?.borderWidth = selected ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    /// ドラッグで他のアプリへ（文字・画像・ファイル）
    override func mouseDragged(with event: NSEvent) {
        let item: NSDraggingItem
        switch clip.kind {
        case .text, .link: item = NSDraggingItem(pasteboardWriter: clip.text as NSString)
        case .file: guard let u = clip.files.first else { return }; item = NSDraggingItem(pasteboardWriter: u as NSURL)
        case .image:
            guard let iv = subviews.first(where: { $0.identifier?.rawValue == "body" }) as? NSImageView, let img = iv.image else { return }
            item = NSDraggingItem(pasteboardWriter: img)
        }
        let snap = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: rep); snap.addRepresentation(rep) }
        item.setDraggingFrame(bounds, contents: snap)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    static func thumb(_ u: URL) -> NSImage? {
        if let c = thumbs.object(forKey: u.path as NSString) { return c }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs.setObject(img, forKey: u.path as NSString)
        return img
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "今" }
        if s < 3600 { return "\(Int(s / 60))分前" }
        if s < 86400 { return "\(Int(s / 3600))時間前" }
        if s < 86400 * 7 { return "\(Int(s / 86400))日前" }
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

extension Card: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: - 順番に貼るの札（画面の上の真ん中に小さく）

final class StackBadge {
    let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(); v.wantsLayer = true
        v.layer?.cornerRadius = 20
        let icon = NSImageView(image: NSImage(systemSymbolName: "list.number", accessibilityDescription: "順番に貼る")!)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let s = NSStackView(views: [icon, label]); s.spacing = 8
        s.frame = NSRect(x: 16, y: 8, width: 100, height: 24)
        v.addSubview(s)
        panel.contentView = v
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            v.layer?.backgroundColor = Palette.ink.cgColor
        }
        icon.contentTintColor = Palette.paper; label.textColor = Palette.paper
    }

    /// 例「2 / 5」＝貼った数 / 集めた数
    func update(on: Bool, pasted: Int, total: Int) {
        guard on else { panel.orderOut(nil); return }
        label.stringValue = "\(pasted) / \(total)"
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - 60, y: vf.maxY - 52, width: 120, height: 40), display: true)
        panel.orderFrontRegardless()
    }
}
