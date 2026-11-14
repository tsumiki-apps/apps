// つみきスナップの中身：寄せる先の計算・ウインドウを動かす（キーは Keys.swift・画面は main.swift）
import AppKit
import ApplicationServices
import Carbon.HIToolbox
enum Side: UInt32 {
    case left = 1, top = 2, right = 3
    case maximize = 4, center = 5, topLeft = 6, topRight = 7, bottomLeft = 8, bottomRight = 9

    var title: String {
        switch self {
        case .left: return "左に寄せる"
        case .top: return "上に寄せる"
        case .right: return "右に寄せる"
        case .maximize: return "最大化"
        case .center: return "中央"
        case .topLeft: return "左上"
        case .topRight: return "右上"
        case .bottomLeft: return "左下"
        case .bottomRight: return "右下"
        }
    }
    /// 右（または下）の端に合わせる寄せ先か（大きさを削られたとき、その端にそろえ直す）
    var anchorsRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var anchorsLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var anchorsBottom: Bool { self == .bottomLeft || self == .bottomRight }

    // Cocoa 座標（左下が原点）の visibleFrame から、寄せたあとの枠を出す。
    // size は「いまのウインドウの大きさ」で、中央だけが使う（大きさは変えず、入りきらないときだけ画面いっぱいに縮める）
    func target(in vf: NSRect, size: CGSize = .zero) -> NSRect {
        let hw = floor(vf.width / 2), hh = floor(vf.height / 2)
        switch self {
        case .left: return NSRect(x: vf.minX, y: vf.minY, width: hw, height: vf.height)
        case .right: return NSRect(x: vf.maxX - hw, y: vf.minY, width: hw, height: vf.height)
        case .top: return NSRect(x: vf.minX, y: vf.maxY - hh, width: vf.width, height: hh)
        case .maximize: return vf
        case .center:
            let w = min(size.width, vf.width), h = min(size.height, vf.height)
            return NSRect(x: vf.minX + floor((vf.width - w) / 2), y: vf.minY + floor((vf.height - h) / 2), width: w, height: h)
        case .topLeft: return NSRect(x: vf.minX, y: vf.maxY - hh, width: hw, height: hh)
        case .topRight: return NSRect(x: vf.maxX - hw, y: vf.maxY - hh, width: hw, height: hh)
        case .bottomLeft: return NSRect(x: vf.minX, y: vf.minY, width: hw, height: hh)
        case .bottomRight: return NSRect(x: vf.maxX - hw, y: vf.minY, width: hw, height: hh)
        }
    }
}

// MARK: - ウインドウを動かす

enum Snapper {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 動かせたら true
    @discardableResult
    static func snap(_ side: Side) -> Bool {
        guard let pid = targetPID else { return false }
        return snap(side, pid: pid)
    }

    /// 自分（つみきスナップ）以外で最後に手前にいたアプリ。案内を閉じたあとも、元のアプリを動かせるように
    static var lastOtherPID: pid_t?
    private static var targetPID: pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me { return app.processIdentifier }
        return lastOtherPID
    }

    @discardableResult
    static func snap(_ side: Side, pid: pid_t) -> Bool {
        guard trusted else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        // 固まったアプリが手前でも、こちらまで固まらないように
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let win = targetWindow(axApp) else { return false }
        AXUIElementSetMessagingTimeout(win, 0.5)
        // 全画面・最小化中は動かせない
        if bool(win, "AXFullScreen") || bool(win, kAXMinimizedAttribute) { return false }
        guard settable(win, kAXSizeAttribute) || settable(win, kAXPositionAttribute) else { return false }

        guard let primary = NSScreen.screens.first else { return false }
        let H = primary.frame.height

        // 今の位置（AX は左上が原点・下向きが正）→ 中心がある画面を選ぶ。どこにも入らなければマウスのある画面
        let mouse = NSEvent.mouseLocation
        let fallback = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? primary
        let before: CGRect? = { if let p = point(win), let s = size(win) { return CGRect(origin: p, size: s) }; return nil }()
        let screen: NSScreen
        if let b = before {
            let center = NSPoint(x: b.midX, y: H - b.midY)
            screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? fallback
        } else {
            screen = fallback
        }

        let vf = screen.visibleFrame
        let r = side.target(in: vf, size: before?.size ?? .zero)
        var sz = CGSize(width: r.width.rounded(), height: r.height.rounded())
        var origin = CGPoint(x: r.minX.rounded(), y: (H - r.maxY).rounded())

        // 大きさ→位置→大きさ の順にすると、画面の端で大きさを削られにくい
        setSize(win, &sz)
        setPoint(win, &origin)
        setSize(win, &sz)

        // 最小・最大の大きさがあるアプリは思った大きさにならない。実際の大きさで、寄せる側の端に合わせ直す
        if let got = size(win), abs(got.width - sz.width) > 1 || abs(got.height - sz.height) > 1 {
            let top = H - vf.maxY, bottom = H - vf.minY
            var x = origin.x, y = origin.y
            if side.anchorsRight { x = (vf.maxX - got.width).rounded() }
            if side.anchorsLeft { x = vf.minX }
            if side.anchorsBottom { y = (bottom - got.height).rounded() }
            if side == .center {
                x = (vf.minX + (vf.width - got.width) / 2).rounded(.down)
                y = (top + (vf.height - got.height) / 2).rounded(.down)
            }
            // 画面からはみ出さないように（入りきらないときは左上をそろえる）
            x = max(vf.minX, min(x, vf.maxX - got.width))
            y = max(top, min(y, bottom - got.height))
            var fixed = CGPoint(x: x.rounded(), y: y.rounded())
            setPoint(win, &fixed)
            origin = fixed
        }

        // 実際に寄ったか、読み戻して確かめる
        guard let p = point(win), let after = size(win) else { return false }
        let now = CGRect(origin: p, size: after)
        let atTarget = abs(p.x - origin.x) <= 2 && abs(p.y - origin.y) <= 2
        let moved = before.map { !$0.equalTo(now) } ?? true
        return atTarget && (moved || before.map { abs($0.width - sz.width) <= 2 && abs($0.height - sz.height) <= 2 } ?? true)
    }

    private static func setSize(_ w: AXUIElement, _ sz: inout CGSize) {
        if let v = AXValueCreate(.cgSize, &sz) { _ = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    private static func setPoint(_ w: AXUIElement, _ p: inout CGPoint) {
        if let v = AXValueCreate(.cgPoint, &p) { _ = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    /// 手前のふつうのウインドウ。シートやパネルが手前なら、その持ち主のウインドウ
    private static func targetWindow(_ axApp: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let w = element(axApp, attr) else { continue }
            if string(w, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String) { return w }
        }
        return nil
    }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func settable(_ e: AXUIElement, _ attr: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(e, attr as CFString, &b) == .success && b.boolValue
    }

    private static func point(_ w: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ w: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil
    }
}
