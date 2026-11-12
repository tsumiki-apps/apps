// 文字の読み取り（OCR）と、ウィンドウを選んで撮る部分。
import AppKit
import ScreenCaptureKit
import Vision

// MARK: - 文字の読み取り（Vision・日本語と英語・端末の中だけで完結）

enum OCR {
    /// 上の行から順に、1行ずつ改行でつないだ文字
    static func read(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja-JP", "en-US"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let obs = (req.results ?? []).sorted {
            // 同じ高さ（行の半分以内）なら左から、違えば上から
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) < min(a.height, b.height) / 2 { return a.minX < b.minX }
            return a.midY > b.midY
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - 短い知らせ（画面の下の真ん中に2秒）

enum Toast {
    static var panel: NSPanel?
    static func show(_ text: String, symbol: String = "checkmark.circle") {
        panel?.orderOut(nil)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = accent
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        let row = NSStackView(views: [icon, label]); row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let size = row.fittingSize
        let vf = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.minY + 60, width: size.width, height: size.height),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.ignoresMouseEvents = true
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = size.height / 2
        row.frame = fx.bounds
        fx.addSubview(row)
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if panel === p { p.orderOut(nil); panel = nil } }
    }
}

// MARK: - ウィンドウを選ぶ幕（指した窓を色で囲み、押したらその窓だけを撮る）

struct WinInfo { let id: CGWindowID; let frame: CGRect /* Cocoa 座標 */ }

/// 画面に出ている普通の窓（手前から順）。自分の窓は除く
func onScreenWindows() -> [WinInfo] {
    let me = ProcessInfo.processInfo.processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    return list.compactMap { d in
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              (d[kCGWindowOwnerPID as String] as? Int32) != me,
              (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let n = d[kCGWindowNumber as String] as? UInt32,
              let b = d[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 40, h > 40 else { return nil }
        return WinInfo(id: n, frame: CGRect(x: x, y: primaryH - y - h, width: w, height: h))   // 左上原点 → 左下原点
    }
}

final class WindowPickView: NSView {
    var hover: CGRect?        // この幕の座標
    var onMove: ((NSPoint) -> Void)?
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let r = hover else { return }
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        accent.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10); p.lineWidth = 3; p.stroke()
    }
    override func mouseMoved(with e: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func rightMouseDown(with e: NSEvent) { onCancel?() }
    var onEnter: (() -> Void)?
    // Esc＝やめる／Enter（テンキーの Enter も）＝いま囲んでいる窓を撮る
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onCancel?() } else if (e.keyCode == 36 || e.keyCode == 76), !e.isARepeat { onEnter?() }   // 押しっぱなしの連打は無視
    }
}

final class WindowPicker {
    private var views: [(NSWindow, WindowPickView)] = []
    private var wins: [WinInfo] = []
    private var current: WinInfo?
    private var finished = false
    private let prevApp = NSWorkspace.shared.frontmostApplication

    func pick(_ done: @escaping (CGWindowID?) -> Void) {
        wins = onScreenWindows()
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.acceptsMouseMovedEvents = true
            let v = WindowPickView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.onMove = { [weak self] p in self?.hover(p) }
            v.onClick = { [weak self] in self?.end(done, self?.current?.id) }
            v.onCancel = { [weak self] in self?.end(done, nil) }
            v.onEnter = { [weak self] in   // 囲んでいる窓が無いときは何もしない（やめるのは Esc）
                if let id = self?.current?.id { self?.end(done, id) } else { NSSound.beep() }
            }
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            views.append((w, v))
        }
        NSApp.activate(ignoringOtherApps: true)
        for (w, _) in views { w.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let key = views.first { $0.0.frame.contains(mouse) } ?? views.first
        key?.0.makeKeyAndOrderFront(nil); key?.0.makeFirstResponder(key?.1)
        NSCursor.pointingHand.set()
        hover(mouse)
    }

    private func hover(_ p: NSPoint) {
        current = wins.first { $0.frame.contains(p) }
        for (w, v) in views {
            v.hover = current.map { $0.frame.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY) }
            v.needsDisplay = true
        }
    }

    private func end(_ done: (CGWindowID?) -> Void, _ id: CGWindowID?) {
        guard !finished else { return }
        finished = true
        for (w, _) in views { w.orderOut(nil) }
        views.removeAll()
        prevApp?.activate()
        done(id)
    }
}

/// その窓だけを撮る（重なった他の窓は写らない・角の外は透明）
func captureWindow(_ id: CGWindowID, _ done: @escaping (CGImage?, CGFloat) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
        guard let w = content?.windows.first(where: { $0.windowID == id }) else { DispatchQueue.main.async { done(nil, 2) }; return }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let s = CGFloat(filter.pointPixelScale)
        cfg.width = Int(filter.contentRect.width * s); cfg.height = Int(filter.contentRect.height * s)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.scalesToFit = false
        cfg.ignoreShadowsSingleWindow = true     // 影を入れない＝窓の大きさそのまま（影入りを窓の大きさへ押し込んで縮むのを防ぐ）
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
            DispatchQueue.main.async { done(img, s) }
        }
    }
}
