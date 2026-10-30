// まどわけの中身：寄せる先の計算・ウインドウを動かす・ショートカットの登録（画面は main.swift）
import AppKit
import ApplicationServices
import Carbon.HIToolbox
enum Side: UInt32 {
    case left = 1, top = 2, right = 3

    var title: String {
        switch self {
        case .left: return "左に寄せる"
        case .top: return "上に寄せる"
        case .right: return "右に寄せる"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .left: return UInt32(kVK_LeftArrow)
        case .top: return UInt32(kVK_UpArrow)
        case .right: return UInt32(kVK_RightArrow)
        }
    }
    var keyEquivalent: String {
        let c: Int
        switch self {
        case .left: c = NSLeftArrowFunctionKey
        case .top: c = NSUpArrowFunctionKey
        case .right: c = NSRightArrowFunctionKey
        }
        return String(Character(UnicodeScalar(c)!))
    }

    // Cocoa 座標（左下が原点）の visibleFrame から、寄せたあとの枠を出す
    func target(in vf: NSRect) -> NSRect {
        switch self {
        case .left: return NSRect(x: vf.minX, y: vf.minY, width: floor(vf.width / 2), height: vf.height)
        case .right:
            let w = floor(vf.width / 2)
            return NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height)
        case .top:
            let h = floor(vf.height / 2)
            return NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
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

    /// 自分（まどわけ）以外で最後に手前にいたアプリ。案内を閉じたあとも、元のアプリを動かせるように
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
        let r = side.target(in: vf)
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
            if side == .right { x = (vf.maxX - got.width).rounded() }
            if side == .left { x = vf.minX }
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

// MARK: - ショートカット（Carbon の全体ホットキー。これ自体に許可は要らない）

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private(set) var failed: [Side] = []
    var onPress: ((Side) -> Void)?

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let ctx, let side = Side(rawValue: id.id) {
                Unmanaged<HotKeys>.fromOpaque(ctx).takeUnretainedValue().onPress?(side)
            }
            return noErr
        }, 1, &spec, me, nil)

        for side in [Side.left, .top, .right] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x6D646B77), id: side.rawValue) // 'mdkw'
            let st = RegisterEventHotKey(side.keyCode, UInt32(cmdKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.append(side) }
        }
    }
}

