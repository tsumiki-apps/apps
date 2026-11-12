// つみきショット：メニューバーに常駐するスクショアプリ（自分専用）。
// ⇧⌘4 範囲 ／ ⇧⌘3 全画面 ／ ⇧⌘5 スクロール（もう一度押すと完了）／ ⇧⌘6 録画（もう一度で停止）／ ⇧⌘7 注釈 ／ ⇧⌘8 ウィンドウ ／ ⇧⌘2 文字を読む
// 撮ったものは ~/Pictures/つみきショット に PNG で保存し、クリップボードにも入れる。
import AppKit
import Carbon
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

let accent = NSColor(srgbRed: 0xd5 / 255.0, green: 0x9a / 255.0, blue: 0x4d / 255.0, alpha: 1)
/// 保存先（設定で変えられる。選んだフォルダが無くなった・作れないときは既定に戻って保存する）
enum SaveFolder {
    /// 本当のホーム（App Store 版は箱の中のホームが返るので、利用者の情報から引く）
    static let home: URL = {
        if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: d), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    static let standard = home.appendingPathComponent("Pictures/つみきショット", isDirectory: true)
    static var isCustom: Bool { Shortcuts.defaults.string(forKey: "saveDir") != nil }
    #if APPSTORE
    /// App Store 版：選んだフォルダは「ブックマーク」で覚え、使う間だけ開ける（再起動しても書ける）
    private static var opened: URL?
    private static func openBookmark() {
        guard opened == nil, let d = Shortcuts.defaults.data(forKey: "saveDirBookmark") else { return }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if u.startAccessingSecurityScopedResource() { opened = u }
        if stale, let nd = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            Shortcuts.defaults.set(nd, forKey: "saveDirBookmark")
        }
    }
    #endif
    static var url: URL {
        guard let p = Shortcuts.defaults.string(forKey: "saveDir") else { return standard }
        #if APPSTORE
        openBookmark()
        #endif
        let u = URL(fileURLWithPath: p, isDirectory: true)
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue, FileManager.default.isWritableFile(atPath: p) { return u }
        return standard
    }
    /// nil＝既定に戻す
    static func set(_ u: URL?) {
        #if APPSTORE
        opened?.stopAccessingSecurityScopedResource(); opened = nil
        if let u, let d = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            Shortcuts.defaults.set(d, forKey: "saveDirBookmark")
        } else { Shortcuts.defaults.removeObject(forKey: "saveDirBookmark") }
        #endif
        if let u { Shortcuts.defaults.set(u.path, forKey: "saveDir") } else { Shortcuts.defaults.removeObject(forKey: "saveDir") }
    }
    /// 画面に出す短い形（ホームは ~）
    static var display: String { (url.path as NSString).abbreviatingWithTildeInPath }
    /// 選んだのに使えない（外付けを外した・消えた・書けない）
    static var isMissing: Bool { isCustom && url == standard }
    static var chosenDisplay: String { ((Shortcuts.defaults.string(forKey: "saveDir") ?? "") as NSString).abbreviatingWithTildeInPath }
}
var saveDir: URL { SaveFolder.url }

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
    var onSpace: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onDone?(nil) }                                     // Esc
        else if e.keyCode == 49, start == nil, let onSpace { onSpace() }        // スペース＝窓を選ぶ（Mac の ⇧⌘4 と同じ）
        else if e.keyCode == 36 || e.keyCode == 76, !e.isARepeat, start == nil, let onEnter { onEnter() }   // Enter＝ドラッグ前なら画面まるごと
    }
    var onEnter: (() -> Void)?
}

final class RegionPicker {
    private var windows: [OverlayWindow] = []
    private var finished = false
    private let prevApp = NSWorkspace.shared.frontmostApplication
    /// 範囲選びの途中でスペース → これを呼んで幕を閉じる（nil なら何もしない）
    var onSpace: (() -> Void)?
    /// ドラッグ前の Enter で、マウスのある画面をまるごと選ぶ（範囲・文字を読むだけ。スクロール・録画では使わない）
    var enterTakesScreen = false

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
            if onSpace != nil {
                v.onSpace = { [weak self] in
                    guard let self, !self.finished else { return }
                    self.finished = true
                    self.close()
                    self.onSpace?()
                }
            }
            if enterTakesScreen {
                v.onEnter = { [weak self] in
                    guard let self, !self.finished else { return }
                    // キーを受けた画面ではなく、いまマウスのある画面
                    let m = NSEvent.mouseLocation
                    let target = NSScreen.screens.first { $0.frame.contains(m) } ?? screen
                    self.finished = true
                    self.close()
                    done(Region(screen: target, rect: target.frame))
                }
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

/// アイコンだけのボタン（説明は指を乗せると出る）。prominent＝色つきの主ボタン
func iconButton(_ name: String, _ tip: String, _ target: AnyObject, _ action: Selector, prominent: Bool = false) -> NSButton {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: tip)!
        .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))!
    let b = NSButton(image: img, target: target, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.imagePosition = .imageOnly
    b.toolTip = tip
    if prominent { b.bezelColor = accent; b.contentTintColor = .white }
    b.widthAnchor.constraint(equalToConstant: 40).isActive = true
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
    private var driver: AutoDriver?                 // 自動スクロール中だけ
    private let watcher = HandWatcher()
    private var autoButton: NSButton!
    /// 札の段階：①向きを選ぶ → ②撮影中（手でスクロールしても継ぐ・▶︎ 自動で撮る）→ ③自動で撮っている
    enum Phase { case direction, ready, auto }
    private(set) var phase: Phase = .direction
    private var dirButtons: [NSButton] = []
    private var doneButton: NSButton!
    private var cancelButton: NSButton!
    private var stack: NSStackView!
    private var fx: NSVisualEffectView!
    private var ended = false                       // 完了・取消は一度きり
    private let queue = DispatchQueue(label: "stitch")   // つなぐ処理はこの列だけで（画面を固めない）
    var onFinish: ((CGImage?, Bool) -> Void)?       // (画像, 撮れなかった)

    init(region: Region) {
        self.region = region
        capturer = Capturer(region: region)
        super.init()
    }

    /// 操作札の中身。--render でも使う
    /// ①向き：［↓ 縦］［→ 横］［×］ → ②撮影中：［↓］高さ［▶︎ 自動］［×］［✓］ → ③自動：［↓］自動 高さ［⏸ 停止］［×］［✓］
    func makeBar() -> NSStackView {
        let v = symbolButton("arrow.down", "縦", self, #selector(pickVertical))
        let h = symbolButton("arrow.right", "横", self, #selector(pickHorizontal))
        v.toolTip = "縦にスクロールするページ"; h.toolTip = "横にスクロールするページ"
        dirButtons = [v, h]
        doneButton = iconButton("checkmark", "完了（ショートカットをもう一度でも）", self, #selector(finish), prominent: true)
        cancelButton = iconButton("xmark", "取消", self, #selector(cancel))
        autoButton = symbolButton("play.fill", "自動", self, #selector(toggleAuto))
        autoButton.bezelColor = accent; autoButton.contentTintColor = .white
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        heightLabel.alignment = .right
        // 札の幅は最初に決まる＝数字が増えても切れないよう「120,000 px」ぶんの幅を取っておく
        heightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        let icon = arrowIcon
        icon.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "スクロール")
        icon.contentTintColor = accent
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        let stack = NSStackView(views: [icon, hintLabel, v, h, heightLabel, autoButton, cancelButton, doneButton])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        self.stack = stack
        setPhase(phase)
        return stack
    }

    /// 段階に合わせて札の部品を出し入れし、札の大きさを合わせる
    func setPhase(_ p: Phase) {
        phase = p
        let choosing = p == .direction
        dirButtons.forEach { $0.isHidden = !choosing }
        arrowIcon.isHidden = choosing
        heightLabel.isHidden = choosing
        autoButton?.isHidden = choosing
        doneButton?.isHidden = choosing
        if choosing { hintLabel.stringValue = "向き"; hintLabel.textColor = .secondaryLabelColor }
        else { showState(height: stitcher.length, lost: lostStreak >= 2 && driver == nil, auto: p == .auto) }
        placePanel()
    }

    /// 見た目の確認用：高さと「ゆっくり」の状態を直接入れる
    func showState(height: Int, lost: Bool, full: Bool = false, auto: Bool = false) {
        frameView.warn = lost || full
        hintLabel.stringValue = full ? "上限" : lost ? "ゆっくり" : auto ? "自動" : "スクロール"
        let sym = auto ? "pause.fill" : "play.fill"
        autoButton?.image = NSImage(systemSymbolName: sym, accessibilityDescription: auto ? "自動を止める" : "自動スクロール")
        autoButton?.title = auto ? "停止" : "自動"
        autoButton?.toolTip = auto ? "自動を止める（手で触っても止まる）" : "自動で端までスクロールして撮る（初回はアクセシビリティの許可）"
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

        // 操作札（範囲の下。入らなければ上）。まずは向きを選ぶ段階
        let stack = makeBar()
        let size = stack.fittingSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        self.fx = fx
        panel.contentView = fx
        placePanel()
        panel.orderFrontRegardless()
    }

    /// 札を今の中身の大きさにして、範囲の下（入らなければ上・どちらも無理なら内側）に置く
    private func placePanel() {
        guard let panel, let stack, let fx else { return }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let vf = region.screen.visibleFrame
        var origin = NSPoint(x: region.rect.midX - size.width / 2, y: region.rect.minY - size.height - 14)
        if origin.y < vf.minY + 4 { origin.y = region.rect.maxY + 14 }
        if origin.y + size.height > vf.maxY { origin.y = region.rect.minY + 14 }   // どちらも入らなければ内側
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        fx.frame = NSRect(origin: .zero, size: size)
        stack.frame = fx.bounds
    }

    @objc func pickVertical() { choose(.vertical) }
    @objc func pickHorizontal() { choose(.horizontal) }

    /// 向きを選んだら撮り始める（手でスクロールしても継ぐ。▶︎ 自動で端まで）
    private func choose(_ a: ScrollAxis) {
        guard phase == .direction, !ended else { return }
        stitcher.force(a)
        arrowIcon.image = NSImage(systemSymbolName: a == .horizontal ? "arrow.right" : "arrow.down",
                                  accessibilityDescription: a == .horizontal ? "横スクロール" : "縦スクロール")
        setPhase(.ready)
        update(nil, height: 0)
        capturer.prepare { [weak self] err in
            guard let self else { return }
            if err != nil { self.end(nil, failed: true); return }
            guard !self.ended else { return }            // 準備の間に完了・取消が押された
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
                    if r == .full { self.finish(); return }      // 上限に達したらそこで仕上げる
                    self.drive(r, axis: axis)
                }
            }
        }
    }

    private func update(_ r: StepResult?, height: Int) {
        if case .lost = r { lostStreak += 1 } else if r != nil, r != .still { lostStreak = 0 }
        guard phase != .direction else { return }
        if r == .full { showState(height: height, lost: false, full: true); return }
        showState(height: height, lost: lostStreak >= 2 && driver == nil, auto: driver != nil)
    }

    private var center: NSPoint { NSPoint(x: region.rect.midX, y: region.rect.midY) }

    /// 自動スクロールの入り切り
    @objc func toggleAuto() {
        if driver != nil { stopAuto(); return }
        guard !ended, phase != .direction else { return }
        guard Wheel.trusted(ask: true) else {
            Toast.show("アクセシビリティを許可してください", symbol: "hand.raised")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        let horizontal = stitcher.axis == .horizontal
        let p = AutoPilot(viewLength: horizontal ? region.rect.width : region.rect.height)
        if let a = stitcher.axis { p.axisDecided(a) }
        let d = AutoDriver(pilot: p)
        driver = d
        Wheel.moveMouse(to: center)            // 範囲の上で回したことにする（指している所に届くアプリが多い）
        watcher.start { [weak self] in self?.stopAuto() }
        setPhase(.auto)
        if case let .scroll(dx, dy) = d.begin(now: CACurrentMediaTime()) { Wheel.post(dx: dx, dy: dy, at: center) }
    }

    func stopAuto() {
        guard driver != nil else { return }
        driver = nil
        watcher.stop()
        setPhase(.ready)
    }

    /// 1コマ継ぐごとに、次の一送りを決めて送る
    private func drive(_ r: StepResult, axis: ScrollAxis?) {
        guard let d = driver, !ended else { return }
        if let axis { d.pilot.axisDecided(axis) }
        switch d.frame(r, now: CACurrentMediaTime()) {
        case nil: break                        // 間をあける・ページが止まるのを待つ
        case let .scroll(dx, dy)?: Wheel.post(dx: dx, dy: dy, at: center)
        case .finish?: finish()                // 端まで来た
        }
    }

    @objc func finish() {
        guard !ended else { return }
        if phase == .direction { cancel(); return }      // まだ撮っていない＝やめる
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
        watcher.stop(); driver = nil
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
    var onEdit: ((CGImage, URL, CGFloat) -> Void)?
    var onPin: ((CGImage, CGFloat) -> Void)?
    private var scale: CGFloat = 2              // 撮った画面の倍率（書き込みの太さ・ピンの大きさに使う）
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

        // ボタンはアイコンだけ（説明は指を乗せると出る）。主ボタン（編集・再生）だけ色つき
        let movie = url.pathExtension == "mp4"
        var views: [NSView] = [movie ? iconButton("play.fill", "再生", self, #selector(openFile), prominent: true)
                                     : iconButton("pencil.tip", "編集（矢印・四角・文字・モザイク）", self, #selector(edit), prominent: true)]
        if !movie { views.append(iconButton("pin", "画面に浮かべる", self, #selector(pin))) }
        views += [iconButton("folder", "Finder で表示", self, #selector(reveal)), iconButton("xmark", "閉じる", self, #selector(close))]
        let row = NSStackView(views: views); row.spacing = 8
        let size = NSSize(width: w + 20, height: h + 56)
        row.frame = NSRect(x: 10, y: 8, width: w, height: 32)
        row.distribution = .fill

        return ([iv, row], size)
    }

    func show(image: CGImage, url: URL, scale: CGFloat) {
        self.scale = scale
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
            if !p.frame.contains(NSEvent.mouseLocation) && NSEvent.pressedMouseButtons == 0 { self.close() }   // ドラッグ中も消さない   // 指を乗せている間は消さない
        }
    }

    @objc func openFile() { if let url { NSWorkspace.shared.open(url) }; close() }
    @objc func pin() { if let image { let s = scale; close(); onPin?(image, s) } }
    @objc func edit() { if let url, let image { let s = scale; close(); onEdit?(image, url, s) } }
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
            // 選んだ場所に書けなければ（アクセスの許可がない等）既定の場所に書く
            func write(in dir: URL) -> URL? {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var url = dir.appendingPathComponent("\(name).png")
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = dir.appendingPathComponent("\(name) \(n).png"); n += 1
                }
                return (try? (data as Data).write(to: url, options: .withoutOverwriting)) != nil ? url : nil
            }
            guard let url = write(in: saveDir) ?? (saveDir == SaveFolder.standard ? nil : write(in: SaveFolder.standard)) else { done(nil); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data as Data, forType: .png)
            done(url)
        }
    }
}

// MARK: - アプリ本体

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var picker: RegionPicker?
    var session: ScrollSession?
    let preview = PreviewPanel()
    var menu: NSMenu!
    var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = AppIcon.menuImage()
        let m = NSMenu()
        m.delegate = self
        let sels: [UInt32: Selector] = [1: #selector(captureArea), 2: #selector(captureScreen), 3: #selector(captureScroll),
                                        4: #selector(captureWindowMenu), 5: #selector(captureText), 6: #selector(captureMovie),
                                        7: #selector(openAnnotate)]
        for a in Shortcuts.actions {
            let i = NSMenuItem(title: a.name, action: sels[a.id], keyEquivalent: "")
            i.tag = Int(a.id)                       // ショートカットの番号と同じ
            i.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.name)
            i.target = self
            m.addItem(i)
        }
        m.addItem(.separator())
        let open = NSMenuItem(title: "保存先", action: #selector(openFolder), keyEquivalent: "")
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); open.target = self
        m.addItem(open)
        let set = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        set.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil); set.target = self
        m.addItem(set)
        m.addItem(.separator())
        let q = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        q.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        m.addItem(q)
        status.menu = m
        menu = m

        HotKeys.actions = [1: { [weak self] in self?.captureArea() }, 2: { [weak self] in self?.captureScreen() },
                           3: { [weak self] in self?.captureScroll() }, 4: { [weak self] in self?.captureWindowMenu() },
                           5: { [weak self] in self?.captureText() }, 6: { [weak self] in self?.captureMovie() },
                           7: { [weak self] in self?.openAnnotate() }]
        HotKeys.apply()
        refreshMenuKeys()
        // 許可の案内は最初の1回だけ（以後は撮ろうとして失敗したときに出す）
        preview.onEdit = { [weak self] img, url, s in self?.openEditor(img, url, scale: s) }
        preview.onPin = { [weak self] img, s in self?.pinImage(img, scale: s) }
        NSApp.mainMenu = editMenu()   // 常駐アプリにはメニューがない＝文字欄で ⌘C・⌘V などが効くように、見えない編集メニューを持つ
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
        askSystemKeys()
    }

    /// つみきショットのキーと Mac 標準のスクショのキーが重なっていたら、最初の1回だけ「止めますか」と聞く（設定でいつでも戻せる）
    func askSystemKeys() {
        #if APPSTORE
        return
        #endif
        let mine = Shortcuts.actions.compactMap { Shortcuts.combo($0.id) }
        let clash = mine.filter { SystemKeys.clashes($0) }
        guard !clash.isEmpty, !UserDefaults.standard.bool(forKey: "askedSystemKeys") else { return }
        UserDefaults.standard.set(true, forKey: "askedSystemKeys")
        let a = NSAlert()
        a.messageText = "Mac 標準のスクショのキーを止めますか？"
        a.informativeText = "\(clash.map(\.display).joined(separator: "・")) を Mac 標準が使っています。止めると、つみきショットで使えます。\n設定の「Mac 標準のスクショのキーを止める」でいつでも戻せます。"
        a.addButton(withTitle: "止める"); a.addButton(withTitle: "このまま")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            SystemKeys.setEnabled(false) { [weak self] in HotKeys.apply(); self?.refreshMenuKeys() }
        }
    }

    /// 録画中に終了したら、動画を閉じ終えてから終わる（途中で切ると再生できないファイルが残る）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = recorder else { return .terminateNow }
        let prev = r.onFinish
        r.onFinish = { a, b, c in prev?(a, b, c); NSApp.reply(toApplicationShouldTerminate: true) }
        r.finish()
        return .terminateLater
    }

    func editMenu() -> NSMenu {
        let main = NSMenu()
        let top = NSMenuItem(); main.addItem(top)
        let m = NSMenu(title: "編集"); top.submenu = m
        for (t, sel, k) in [("取り消す", Selector(("undo:")), "z"), ("カット", #selector(NSText.cut(_:)), "x"),
                            ("コピー", #selector(NSText.copy(_:)), "c"), ("ペースト", #selector(NSText.paste(_:)), "v"),
                            ("すべてを選択", #selector(NSText.selectAll(_:)), "a")] {
            m.addItem(NSMenuItem(title: t, action: sel, keyEquivalent: k))
        }
        return main
    }

    /// メニューのキー表示をいまの設定に合わせる（他のアプリが使っているキーは ⚠︎ を付けて外す）
    func refreshMenuKeys() {
        for a in Shortcuts.actions {
            guard let it = menu.items.first(where: { $0.tag == Int(a.id) }) else { continue }
            it.title = a.name
            if let c = Shortcuts.combo(a.id), !HotKeys.failed.contains(a.id) {
                (it.keyEquivalent, it.keyEquivalentModifierMask) = c.menuKey
            } else {
                it.keyEquivalent = ""
                if HotKeys.failed.contains(a.id) { it.title += "  ⚠︎" }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenuKeys() }

    @objc func openSettings() {
        if settings == nil {
            let w = SettingsWindow()
            w.loginState = { SMAppService.mainApp.status == .enabled }
            w.onLogin = { [weak self] on in if on != (SMAppService.mainApp.status == .enabled) { self?.toggleLogin() } }
            w.onKeysChanged = { [weak self] in self?.refreshMenuKeys() }
            settings = w
        }
        settings?.show()
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

    /// 範囲を選んで録画。もう一度 ⇧⌘6（か札の停止）で止める
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
                if let thumb { self.preview.show(image: thumb, url: out, scale: region.scale) }
            }
            self.recorder = r
            r.start()
        }
    }

    func pinImage(_ img: CGImage, scale: CGFloat) {
        let p = makePin(img, unit: scale) { [weak self] p in self?.pins.removeAll { $0 === p } }
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
            captureWindow(id) { img, scale in
                guard let img else { self.shooting -= 1; self.failed(); return }
                self.deliver(img, kind: "ウィンドウ", scale: scale) { self.shooting -= 1 }
            }
        }
    }

    /// 範囲を選んで、写っている文字をクリップボードへ（画像は保存しない）
    @objc func captureText() {
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() { failed(); return }
        let p = RegionPicker(); picker = p
        p.enterTakesScreen = true
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

    /// 注釈：保存先でいちばん新しい画像（直前のスクショ）を編集画面で開く。1枚も無ければ画像を選ぶ
    @objc func openAnnotate() {
        guard !busy else { return }
        if let url = Self.latestImage(in: saveDir) ?? Self.latestImage(in: SaveFolder.standard) { openImageInEditor(url); return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        p.directoryURL = saveDir
        p.message = "書き込む画像を選んでください"
        NSApp.activate(ignoringOtherApps: true)
        p.begin { [weak self] r in if r == .OK, let url = p.url { self?.openImageInEditor(url) } }
    }

    /// フォルダの中でいちばん新しい画像（動画は除く）
    static func latestImage(in dir: URL) -> URL? {
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { exts.contains($0.pathExtension.lowercased()) }.max { date($0) < date($1) }
    }

    func openImageInEditor(_ url: URL) {
        // 同じ画像をもう開いていれば、それを前に出す
        if let e = editors.first(where: { $0.url == url }) { e.show(); return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { NSSound.beep(); return }
        openEditor(img, url, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    func openEditor(_ img: CGImage, _ url: URL, scale: CGFloat) {
        let e = EditorWindow(image: img, url: url, unit: scale)
        // 閉じる処理の最中に自分が解放されないよう、外すのは次の周回で
        e.onClose = { [weak self, weak e] in DispatchQueue.main.async { self?.editors.removeAll { $0 === e } } }
        e.onSaved = { [weak self] img, url in NSSound(named: "Tink")?.play(); self?.preview.show(image: img, url: url, scale: scale) }
        editors.append(e)
        e.show()
    }

    @objc func captureArea() {
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() { failed(); return }
        let p = RegionPicker(); picker = p
        p.enterTakesScreen = true
        p.onSpace = { [weak self] in self?.picker = nil; self?.captureWindowMenu() }
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            self.shoot(region, kind: "スクショ")
        }
    }

    @objc func captureScreen() {
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() { failed(); return }
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
                self?.deliver(img, kind: kind, scale: region.scale) { self?.shooting -= 1 }
            }
        }
    }

    @objc func captureScroll() {
        if let s = session { s.finish(); return }        // 2回目の ⇧⌘5 は完了
        guard !busy else { return }                      // 録画中・ウィンドウ選択中などは始めない
        if !CGPreflightScreenCaptureAccess() { failed(); return }
        let p = RegionPicker(); picker = p
        p.pick { [weak self] region in
            self?.picker = nil
            guard let self, let region else { return }
            let s = ScrollSession(region: region)
            s.onFinish = { [weak self, weak s] img, failed in
                guard let self else { return }
                if self.session === s { self.session = nil }   // 別の新しいセッションは消さない
                if let img { self.deliver(img, kind: "スクロール", scale: region.scale) } else if failed { self.failed() }
            }
            self.session = s
            s.start()
        }
    }

    func deliver(_ img: CGImage, kind: String, scale: CGFloat, then: (() -> Void)? = nil) {
        output(img, kind: kind) { [weak self] url in
            then?()
            guard let self else { return }
            guard let url else { self.failed(); return }
            NSSound(named: "Tink")?.play()
            self.preview.show(image: img, url: url, scale: scale)
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
// 許可の状態をファイルに書いて終わる（open -n で起動すると、アプリ自身の許可として調べられる）
if let i = args.firstIndex(of: "--perm") {
    let s = "画面収録=\(CGPreflightScreenCaptureAccess() ? "OK" : "なし") アクセシビリティ=\(Wheel.trusted(ask: false) ? "OK" : "なし")\n"
    try? s.write(toFile: args[i + 1], atomically: true, encoding: .utf8); exit(0)
}
if let i = args.firstIndex(of: "--icons") { AppIcon.writeIconset(args[i + 1]); exit(0) }
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
