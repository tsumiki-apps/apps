// つみきショット：メニューバーに常駐するスクショアプリ（自分専用）。
// ⌥⇧4 範囲 ／ ⌥⇧3 全画面 ／ ⌥⇧S スクロール（もう一度押すと完了）／ ⌥⇧W ウィンドウ ／ ⌥⇧T 文字を読む ／ ⌥⇧R 録画（もう一度で停止）
// 撮ったものは ~/Pictures/つみきショット に PNG で保存し、クリップボードにも入れる。
import AppKit
import Carbon
import ScreenCaptureKit
import ServiceManagement

let accent = NSColor(srgbRed: 0xd5 / 255.0, green: 0x9a / 255.0, blue: 0x4d / 255.0, alpha: 1)
let saveDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/つみきショット", isDirectory: true)

// MARK: - 選択した範囲（どの画面の、どこか）

struct Region {
    let screen: NSScreen
    let rect: CGRect          // 画面全体の座標（左下が原点・ポイント）

    var displayID: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    /// ScreenCaptureKit の sourceRect（その画面の左上が原点）
    var sourceRect: CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
    var scale: CGFloat { screen.backingScaleFactor }
}

// MARK: - 撮影（ScreenCaptureKit・自分のウィンドウは写さない）

final class Capturer {
    private(set) var filter: SCContentFilter?
    private let config = SCStreamConfiguration()
    let region: Region
    var includeSelf = false     // 通しテストだけ自分の窓も写す

    init(region: Region) { self.region = region }

    func prepare(_ done: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
            DispatchQueue.main.async {
                guard let content else { done(err ?? NSError(domain: "shot", code: 1)); return }
                // 画面が見つからないとき別の画面を撮らない（接続の変更直後など）
                guard let display = content.displays.first(where: { $0.displayID == self.region.displayID })
                else { done(NSError(domain: "shot", code: 2)); return }
                let me = self.includeSelf ? [] : content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                self.filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let s = self.region.scale
                self.config.sourceRect = self.region.sourceRect
                self.config.width = Int((self.region.rect.width * s).rounded())
                self.config.height = Int((self.region.rect.height * s).rounded())
                self.config.showsCursor = false
                self.config.scalesToFit = false
                if #available(macOS 14.0, *) { self.config.captureResolution = .best }
                done(nil)
            }
        }
    }

    func shot(_ done: @escaping (CGImage?) -> Void) {
        guard let filter else { done(nil); return }
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { img, _ in
            DispatchQueue.main.async { done(img) }
        }
    }
}

// MARK: - 範囲を選ぶ幕

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class SelectView: NSView {
    var start: NSPoint?
    var current: NSPoint?
    var onDone: ((CGRect?) -> Void)?
    let tracking: Bool

    init(frame: NSRect, tracking: Bool) { self.tracking = tracking; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    var selection: CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard let r = selection else { return }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        accent.setStroke()
        let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); p.lineWidth = 2; p.stroke()
        // 大きさの札
        let s = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let sz = s.size(withAttributes: attrs)
        var o = NSPoint(x: r.minX, y: r.minY - sz.height - 10)
        if o.y < 4 { o.y = r.minY + 6; o.x += 6 }
        let bg = NSRect(x: o.x, y: o.y, width: sz.width + 12, height: sz.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: o.x + 6, y: o.y + 3), withAttributes: attrs)
    }

    /// 画面の外に出たドラッグは画面の端で止める
    func point(_ e: NSEvent) -> NSPoint {
        let p = convert(e.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    override func mouseDown(with e: NSEvent) {
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self)   // どの画面でも Esc が届くように
        start = point(e); current = start; needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) { current = point(e); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        current = point(e)
        if let r = selection, r.width >= 8, r.height >= 8 { onDone?(r) } else { start = nil; current = nil; needsDisplay = true }
    }
    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onDone?(nil) } }   // Esc
}

final class RegionPicker {
    private var windows: [OverlayWindow] = []
    private var finished = false
    private let prevApp = NSWorkspace.shared.frontmostApplication

    func pick(_ done: @escaping (Region?) -> Void) {
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = SelectView(frame: NSRect(origin: .zero, size: screen.frame.size), tracking: true)
            v.onDone = { [weak self] r in
                guard let self, !self.finished else { return }
                self.finished = true
                self.close()
                if let r { done(Region(screen: screen, rect: r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))) }
                else { done(nil) }
            }
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
        NSCursor.crosshair.set()
    }

    func close() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        // 撮る相手のアプリを前に戻す（スクロールが届くように）
        prevApp?.activate()
    }
}

// MARK: - スクロール中の枠と操作札

final class FrameView: NSView {
    var warn = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (warn ? NSColor.systemRed : accent).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3
        p.setLineDash([10, 6], count: 2, phase: 0)
        p.stroke()
    }
}

func symbolButton(_ name: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: label)!
    let b = NSButton(title: label, image: img, target: target, action: action)
    b.imagePosition = .imageLeading
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.toolTip = label
    return b
}

final class ScrollSession: NSObject {
    let region: Region
    let capturer: Capturer
    let stitcher = AutoStitcher()
    private let arrowIcon = NSImageView()
    private var frameWin: NSWindow!
    private var frameView = FrameView()
    private var panel: NSPanel!
    private let heightLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var busy = false
    private var lostStreak = 0
    private var ended = false                       // 完了・取消は一度きり
    private let queue = DispatchQueue(label: "stitch")   // つなぐ処理はこの列だけで（画面を固めない）
    var onFinish: ((CGImage?, Bool) -> Void)?       // (画像, 撮れなかった)

    init(region: Region) {
        self.region = region
        capturer = Capturer(region: region)
        super.init()
    }

    /// 操作札の中身（矢印・案内・高さ・取消・完了）。--render でも使う
    func makeBar() -> NSStackView {
        let done = symbolButton("checkmark", "完了", self, #selector(finish))
        let cancel = symbolButton("xmark", "取消", self, #selector(cancel))
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        heightLabel.alignment = .right
        // 札の幅は最初に決まる＝数字が増えても切れないよう「120,000 px」ぶんの幅を取っておく
        heightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        let icon = arrowIcon
        icon.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "スクロール")
        icon.contentTintColor = accent
        let stack = NSStackView(views: [icon, hintLabel, heightLabel, cancel, done])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        return stack
    }

    /// 見た目の確認用：高さと「ゆっくり」の状態を直接入れる
    func showState(height: Int, lost: Bool, full: Bool = false) {
        frameView.warn = lost || full
        hintLabel.stringValue = full ? "上限" : lost ? "ゆっくり" : "スクロール"
        hintLabel.textColor = lost || full ? .systemRed : .secondaryLabelColor
        heightLabel.stringValue = height > 0 ? "\(height.formatted()) px" : "—"
    }

    func start() {
        // 枠（範囲の外側に描く＝写らない。マウスは素通り）
        let fr = region.rect.insetBy(dx: -4, dy: -4)
        frameWin = NSWindow(contentRect: fr, styleMask: .borderless, backing: .buffered, defer: false)
        frameWin.isOpaque = false; frameWin.backgroundColor = .clear
        frameWin.ignoresMouseEvents = true
        frameWin.level = .statusBar
        frameWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        frameWin.contentView = frameView
        frameWin.orderFrontRegardless()

        // 操作札（範囲の下。入らなければ上）
        let stack = makeBar()
        let size = stack.fittingSize
        let vf = region.screen.visibleFrame
        var origin = NSPoint(x: region.rect.midX - size.width / 2, y: region.rect.minY - size.height - 14)
        if origin.y < vf.minY + 4 { origin.y = region.rect.maxY + 14 }
        if origin.y + size.height > vf.maxY { origin.y = region.rect.minY + 14 }   // どちらも入らなければ内側
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        stack.frame = fx.bounds
        fx.addSubview(stack)
        panel.contentView = fx
        panel.orderFrontRegardless()
        update(nil, height: 0)

        capturer.prepare { [weak self] err in
            guard let self else { return }
            if err != nil { self.end(nil, failed: true); return }
            self.tick()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        guard !busy, !ended else { return }
        busy = true
        capturer.shot { [weak self] img in
            guard let self else { return }
            guard let img, !self.ended else { self.busy = false; return }
            self.queue.async {
                let r = self.stitcher.add(img)
                let h = self.stitcher.length
                let axis = self.stitcher.axis
                DispatchQueue.main.async {
                    self.busy = false
                    // 向きが決まったら矢印もそちらに（縦↓・横→）
                    if axis == .horizontal { self.arrowIcon.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "横スクロール") }
                    self.update(r, height: h)
                    if r == .full { self.finish() }      // 上限に達したらそこで仕上げる
                }
            }
        }
    }

    private func update(_ r: StepResult?, height: Int) {
        if case .lost = r { lostStreak += 1 } else if r != nil, r != .still { lostStreak = 0 }
        if r == .full { showState(height: height, lost: false, full: true); return }
        showState(height: height, lost: lostStreak >= 2)
    }

    @objc func finish() {
        guard !ended else { return }
        ended = true
        timer?.invalidate(); timer = nil
        // 撮りかけのコマを待ち、最後の1コマを足してから仕上げる
        func last() {
            if busy { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { last() }; return }
            capturer.shot { [weak self] img in
                guard let self else { return }
                self.queue.async {
                    if let img, !self.stitcher.isFull { self.stitcher.add(img) }
                    let out = self.stitcher.compose()
                    DispatchQueue.main.async { self.end(out, failed: out == nil) }
                }
            }
        }
        last()
    }

    @objc func cancel() {
        guard !ended else { return }
        ended = true
        timer?.invalidate(); timer = nil
        end(nil, failed: false)
    }

    private var delivered = false
    private func end(_ img: CGImage?, failed: Bool) {
        guard !delivered else { return }
        delivered = true; ended = true
        timer?.invalidate(); timer = nil
        stop()
        onFinish?(img, failed)
    }

    private func stop() {
        frameWin?.orderOut(nil); panel?.orderOut(nil)
    }
}

// MARK: - 撮った直後の小窓

final class DragImageView: NSImageView, NSDraggingSource {
    var fileURL: URL?
    var onClick: (() -> Void)?
    private var downAt: NSPoint?

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let url = fileURL, let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    override func mouseUp(with e: NSEvent) { if downAt != nil { onClick?() }; downAt = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class PreviewPanel: NSObject {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var url: URL?
    private var image: CGImage?
    var onEdit: ((CGImage, URL) -> Void)?
    var onPin: ((CGImage) -> Void)?
    private var isMovie = false

    /// 小窓の中身（縮小画像と2つのボタン）。--render でも使う
    func makeContent(image: CGImage, url: URL) -> ([NSView], NSSize) {
        let w: CGFloat = 220
        let scaleH = CGFloat(image.height) / CGFloat(image.width) * w
        let h = min(max(scaleH, 40), 280)
        // 縦長は上の部分だけ見せる
        var shown = image
        if scaleH > h, let c = image.cropping(to: CGRect(x: 0, y: 0, width: image.width,
                                                          height: Int(CGFloat(image.width) * h / w))) { shown = c }
        let iv = DragImageView(frame: NSRect(x: 10, y: 46, width: w, height: h))
        iv.image = NSImage(cgImage: shown, size: NSSize(width: w, height: h))
        iv.imageScaling = scaleH < 40 ? .scaleProportionallyUpOrDown : .scaleAxesIndependently   // 極端な横長はひずませない
        iv.wantsLayer = true; iv.layer?.cornerRadius = 8; iv.layer?.masksToBounds = true
        iv.fileURL = url
        iv.onClick = { [weak self] in NSWorkspace.shared.open(url); self?.close() }
        iv.toolTip = "\(image.width) × \(image.height)"

        func icon(_ sym: String, _ tip: String, _ a: Selector) -> NSButton {
            let b = symbolButton(sym, "", self, a); b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            return b
        }
        let movie = url.pathExtension == "mp4"
        let edit = symbolButton(movie ? "play.fill" : "pencil.tip", movie ? "再生" : "編集", self, movie ? #selector(openFile) : #selector(edit))
        var views: [NSView] = [edit]
        if !movie { views.append(icon("pin", "画面に浮かべる", #selector(pin))) }
        views += [icon("folder", "場所", #selector(reveal)), icon("xmark", "閉じる", #selector(close))]
        let row = NSStackView(views: views); row.spacing = 6
        let size = NSSize(width: w + 20, height: h + 56)
        row.frame = NSRect(x: 10, y: 8, width: w, height: 32)
        row.distribution = .fill

        return ([iv, row], size)
    }

    func show(image: CGImage, url: URL) {
        close()
        self.url = url; self.image = image
        let (views, size) = makeContent(image: image, url: url)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: vf.minX + 20, y: vf.minY + 20, width: size.width, height: size.height),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14
        views.forEach { fx.addSubview($0) }
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        hideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            if !p.frame.contains(NSEvent.mouseLocation) { self.close() }   // 指を乗せている間は消さない
        }
    }

    @objc func openFile() { if let url { NSWorkspace.shared.open(url) }; close() }
    @objc func pin() { if let image { close(); onPin?(image) } }
    @objc func edit() { if let url, let image { close(); onEdit?(image, url) } }
    @objc func reveal() { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }; close() }
    @objc func close() { hideTimer?.invalidate(); hideTimer = nil; panel?.orderOut(nil); panel = nil }
}

// MARK: - 保存とクリップボード

func stamp() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return f.string(from: Date())
}

/// PNG にして保存し、クリップボードにも入れる。重いので裏の列で行い、終わったら main で done
func output(_ img: CGImage, kind: String, _ done: @escaping (URL?) -> Void) {
    let name = "\(kind) \(stamp())"
    DispatchQueue.global(qos: .userInitiated).async {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            DispatchQueue.main.async { done(nil) }; return
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { DispatchQueue.main.async { done(nil) }; return }
        DispatchQueue.main.async {
            // 名前決めと書き込みは main の1本だけ＝同時に撮っても同じ名前にならない
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            var url = saveDir.appendingPathComponent("\(name).png")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = saveDir.appendingPathComponent("\(name) \(n).png"); n += 1
            }
            do { try (data as Data).write(to: url, options: .withoutOverwriting) } catch { done(nil); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data as Data, forType: .png)
            done(url)
        }
    }
}

// MARK: - グローバルショートカット（Carbon）

var hotKeyActions: [UInt32: () -> Void] = [:]
var hotKeyRefs: [EventHotKeyRef?] = []

/// 登録できなかった（他のアプリが使っている）キーの番号を返す
@discardableResult
func installHotKeys(_ list: [(UInt32, Int, () -> Void)]) -> [UInt32] {
    var failed: [UInt32] = []
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
        var hid = EventHotKeyID()
        GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
        let id = hid.id
        DispatchQueue.main.async { hotKeyActions[id]?() }
        return noErr
    }, 1, &spec, nil, nil)
    for (id, key, fn) in list {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(key), UInt32(optionKey | shiftKey),
                                     EventHotKeyID(signature: OSType(0x54534854), id: id), GetApplicationEventTarget(), 0, &ref)
        if st != noErr { failed.append(id); continue }
        hotKeyRefs.append(ref)
        hotKeyActions[id] = fn
    }
    return failed
}

// MARK: - アプリ本体

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var picker: RegionPicker?
    var session: ScrollSession?
    let preview = PreviewPanel()
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "つみきショット")
        let m = NSMenu()
        m.delegate = self
        func item(_ t: String, _ sym: String, _ a: Selector, _ key: String) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key)
            i.keyEquivalentModifierMask = [.option, .shift]
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: t)
            i.target = self
            return i
        }
        m.addItem(item("範囲", "rectangle.dashed", #selector(captureArea), "4"))
        m.addItem(item("全画面", "macwindow", #selector(captureScreen), "3"))
        m.addItem(item("スクロール", "arrow.down.to.line.compact", #selector(captureScroll), "s"))
        m.addItem(item("ウィンドウ", "macwindow.on.rectangle", #selector(captureWindowMenu), "w"))
        m.addItem(item("文字を読む", "text.viewfinder", #selector(captureText), "t"))
        m.addItem(item("録画", "record.circle", #selector(captureMovie), "r"))
        m.addItem(.separator())
        let open = NSMenuItem(title: "保存先", action: #selector(openFolder), keyEquivalent: "")
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); open.target = self
        m.addItem(open)
        loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        m.addItem(loginItem)
        m.addItem(.separator())
        let q = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); m.addItem(q)
        status.menu = m

        let failedKeys = installHotKeys([
            (1, kVK_ANSI_4, { [weak self] in self?.captureArea() }),
            (2, kVK_ANSI_3, { [weak self] in self?.captureScreen() }),
            (3, kVK_ANSI_S, { [weak self] in self?.captureScroll() }),
            (4, kVK_ANSI_W, { [weak self] in self?.captureWindowMenu() }),
            (5, kVK_ANSI_T, { [weak self] in self?.captureText() }),
            (6, kVK_ANSI_R, { [weak self] in self?.captureMovie() }),
        ])
        // 他のアプリが使っているキーは、メニューの項目からキー表示を外して知らせる
        for id in failedKeys {
            let it = m.items[Int(id) - 1]
            it.keyEquivalent = ""
            it.title += "（キーは使用中）"
        }
        // 許可の案内は最初の1回だけ（以後は撮ろうとして失敗したときに出す）
        preview.onEdit = { [weak self] img, url in self?.openEditor(img, url) }
        preview.onPin = { [weak self] img in self?.pinImage(img) }
        // 文字読みの初回は仕組みの読み込みで20秒ほどかかる＝起動時に裏で1回済ませておく
        DispatchQueue.global(qos: .utility).async {
            let c = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            _ = OCR.read(c.makeImage()!)
        }
        if !CGPreflightScreenCaptureAccess() && !UserDefaults.standard.bool(forKey: "askedPermission") {
            UserDefaults.standard.set(true, forKey: "askedPermission")
            askPermission()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func askPermission() {
        CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "画面収録の許可"
        a.informativeText = "システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で「つみきショット」をオンにしてください。"
        a.addButton(withTitle: "設定を開く"); a.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    var winPicker: WindowPicker?
    var editors: [EditorWindow] = []
    var recorder: Recorder?
    var pins: [NSPanel] = []
    var shooting = 0                        // 撮っている最中の数（範囲・全画面）
    var busy: Bool { picker != nil || winPicker != nil || session != nil || recorder != nil || shooting > 0 }

    /// 範囲を選んで録画。もう一度 ⌥⇧R（か札の停止）で止める
    @objc func captureMovie() {
        if let r = recorder { r.finish(); return }
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() { failed(); return }
        let p = RegionPicker(); picker = p
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            var url = saveDir.appendingPathComponent("録画 \(stamp()).mp4")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) { url = saveDir.appendingPathComponent("録画 \(stamp()) \(n).mp4"); n += 1 }
            let r = Recorder(region: region, url: url)
            r.onFinish = { [weak self, weak r] out, thumb, failed in
                guard let self else { return }
                if self.recorder === r { self.recorder = nil }
                guard let out else { if failed { self.failed() }; return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([out as NSURL])      // ファイルとして貼れる
                NSSound(named: "Tink")?.play()
                if let thumb { self.preview.show(image: thumb, url: out) }
            }
            self.recorder = r
            r.start()
        }
    }

    func pinImage(_ img: CGImage) {
        let p = makePin(img, unit: NSScreen.main?.backingScaleFactor ?? 2) { [weak self] p in self?.pins.removeAll { $0 === p } }
        pins.append(p)
        p.orderFrontRegardless()
    }

    @objc func captureWindowMenu() {
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() { failed(); return }
        let p = WindowPicker(); winPicker = p
        p.pick { [weak self] id in
            self?.winPicker = nil
            guard let self, let id else { return }
            self.shooting += 1
            captureWindow(id) { img in
                guard let img else { self.shooting -= 1; self.failed(); return }
                self.deliver(img, kind: "ウィンドウ") { self.shooting -= 1 }
            }
        }
    }

    /// 範囲を選んで、写っている文字をクリップボードへ（画像は保存しない）
    @objc func captureText() {
        guard !busy else { return }
        let p = RegionPicker(); picker = p
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            self.shooting += 1
            let c = Capturer(region: region)
            c.prepare { err in
                guard err == nil else { self.shooting -= 1; self.failed(); return }
                c.shot { img in
                    guard let img else { self.shooting -= 1; self.failed(); return }
                    Toast.show("読み取り中", symbol: "text.viewfinder")
                    DispatchQueue.global(qos: .userInitiated).async {
                        let text = OCR.read(img)
                        DispatchQueue.main.async {
                            self.shooting -= 1
                            if text.isEmpty { Toast.show("文字なし", symbol: "exclamationmark.circle"); return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            Toast.show("\(text.count)文字をコピー", symbol: "doc.on.clipboard")
                        }
                    }
                }
            }
        }
    }

    func openEditor(_ img: CGImage, _ url: URL) {
        let e = EditorWindow(image: img, url: url, unit: NSScreen.main?.backingScaleFactor ?? 2)
        e.onClose = { [weak self, weak e] in self?.editors.removeAll { $0 === e } }
        e.onSaved = { [weak self] img, url in NSSound(named: "Tink")?.play(); self?.preview.show(image: img, url: url) }
        editors.append(e)
        e.show()
    }

    @objc func captureArea() {
        guard !busy else { return }
        let p = RegionPicker(); picker = p
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            self.shoot(region, kind: "スクショ")
        }
    }

    @objc func captureScreen() {
        guard !busy else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        shoot(Region(screen: screen, rect: screen.frame), kind: "スクショ")
    }

    func shoot(_ region: Region, kind: String) {
        shooting += 1
        let c = Capturer(region: region)
        c.prepare { [weak self] err in
            guard err == nil else { self?.shooting -= 1; self?.failed(); return }
            c.shot { img in
                guard let img else { self?.shooting -= 1; self?.failed(); return }
                self?.deliver(img, kind: kind) { self?.shooting -= 1 }
            }
        }
    }

    @objc func captureScroll() {
        if let s = session { s.finish(); return }        // 2回目の ⌥⇧S は完了
        guard picker == nil, shooting == 0 else { return }
        let p = RegionPicker(); picker = p
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            let s = ScrollSession(region: region)
            s.onFinish = { [weak self, weak s] img, failed in
                guard let self else { return }
                if self.session === s { self.session = nil }   // 別の新しいセッションは消さない
                if let img { self.deliver(img, kind: "スクロール") } else if failed { self.failed() }
            }
            self.session = s
            s.start()
        }
    }

    func deliver(_ img: CGImage, kind: String, then: (() -> Void)? = nil) {
        output(img, kind: kind) { [weak self] url in
            then?()
            guard let self else { return }
            guard let url else { self.failed(); return }
            NSSound(named: "Tink")?.play()
            self.preview.show(image: img, url: url)
        }
    }

    func failed() {
        if !CGPreflightScreenCaptureAccess() { askPermission(); return }
        NSSound.beep()
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveDir)
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { NSSound.beep() }
        // 「ログイン項目」で本人の承認が要るときは、その画面を開く
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

// MARK: - 起動

let args = CommandLine.arguments
if args.contains("--selftest") {
    let i = args.firstIndex(of: "--selftest")!
    let dir = args.count > i + 1 ? args[i + 1] : nil
    exit(SelfTest.run(outDir: dir) ? 0 : 1)
}
if args.contains("--extratest") { exit(ExtraTest.run(outDir: args.last!.hasPrefix("--") ? nil : args.last) ? 0 : 1) }
if let i = args.firstIndex(of: "--render") {
    Render.run(out: args.count > i + 1 ? args[i + 1] : NSTemporaryDirectory() + "render.png")
}
if let i = args.firstIndex(of: "--probe") {
    Probe.run(out: args.count > i + 1 ? args[i + 1] : NSTemporaryDirectory() + "probe.png")
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
