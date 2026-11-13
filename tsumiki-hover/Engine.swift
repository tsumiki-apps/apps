// 判断と実行。
//   Brain：画面の様子（Snapshot）を受けて「前に出す／出さない（理由）」を決める。画面には触らない＝自己テストで架空の様子を流せる
//   Screen：いまの様子を読む（窓の一覧は CGWindowList・公開の仕組みだけ）
//   Raiser：アクセシビリティで窓を前に出す（公開の仕組みだけ。非公開の関数は使わない）
import AppKit
import ApplicationServices

/// 画面に出ている窓1枚（手前から奥の順に並ぶ）。座標は左上原点（CGWindowList と同じ）
struct Win: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

/// ある瞬間の画面の様子
struct Snapshot {
    var mouse: CGPoint                 // 左上原点
    var windows: [Win]                 // 手前から奥
    var frontPid: pid_t
    var bundleOf: (pid_t) -> String?
    var controlDown: Bool
    var buttonsDown: Bool
    var topEdge: Bool                  // カーソルが画面の上の縁（隠れたメニューバーが出てくる所）
    var now: TimeInterval
}

enum Why: String {
    case raise = "前に出す"
    case paused = "休み中"
    case controlKey = "control"
    case mouseDown = "ボタンを押している"
    case menuOpen = "メニューが開いている"
    case spaceChanged = "デスクトップを切り替えた直後"
    case topEdge = "画面の上の縁"
    case noWindow = "窓がない"
    case overlay = "浮いている窓の上"
    case stayApp = "除外アプリが前にいる"
    case ownApp = "自分の窓"
    case excluded = "除外アプリ"
    case alreadyFront = "もう前にいる"
    case waiting = "待っている"
    case cooling = "出したばかり"
}

/// 窓の高さ（CGWindowLevel）。メニュー＝101、メニューバー＝24・25
enum Level {
    static let menuBar = 24, statusItem = 25, popUpMenu = 101
}

final class Brain {
    var delay: TimeInterval = 0.05
    var excluded: Set<String> = []
    var pausedUntil: TimeInterval = 0          // .infinity＝ずっと休む
    let selfPid: pid_t

    private var spaceChangedAt: TimeInterval = -1000
    private var mouseAtSpaceChange: CGPoint?
    private var candidate: CGWindowID?
    private var since: TimeInterval = 0
    private var raisedId: CGWindowID?
    private var raisedAt: TimeInterval = -1000

    init(selfPid: pid_t) { self.selfPid = selfPid }

    func spaceChanged(now: TimeInterval, mouse: CGPoint) {
        spaceChangedAt = now; mouseAtSpaceChange = mouse; candidate = nil
    }

    var waitingForCandidate: Bool { candidate != nil || cooling }
    private var cooling = false

    /// 1回分の判断。.raise のときだけ窓を返す
    func step(_ s: Snapshot) -> (Why, Win?) {
        func stop(_ w: Why) -> (Why, Win?) { candidate = nil; cooling = false; return (w, nil) }
        if s.now < pausedUntil { return stop(.paused) }
        if s.controlDown { return stop(.controlKey) }
        if s.buttonsDown { return stop(.mouseDown) }
        if s.windows.contains(where: { $0.layer == Level.popUpMenu && $0.alpha > 0 }) { return stop(.menuOpen) }
        if let m = mouseAtSpaceChange {
            // 切り替えた直後の 0.4 秒と、そのあとカーソルを動かすまでは何もしない
            if s.now - spaceChangedAt < 0.4 || hypot(m.x - s.mouse.x, m.y - s.mouse.y) < 2 { return stop(.spaceChanged) }
            mouseAtSpaceChange = nil
        }
        if s.topEdge { return stop(.topEdge) }
        // 除外アプリ（Alfred・Paste など）が前にいる、または浮いた窓を出しているあいだは、操作を奪わない
        let front = s.bundleOf(s.frontPid)
        if let f = front, excluded.contains(f) { return stop(.stayApp) }
        if s.windows.contains(where: { w in
            w.layer > 0 && w.layer != Level.menuBar && w.layer != Level.statusItem && w.alpha > 0
                && (s.bundleOf(w.pid).map { excluded.contains($0) } ?? false)
        }) { return stop(.stayApp) }
        guard let top = s.windows.first(where: { $0.alpha > 0 && $0.bounds.contains(s.mouse) }) else { return stop(.noWindow) }
        // 普通の窓（高さ0）以外＝Dock・メニューバー・浮いたパネル・つみきショットの範囲選び・つみきロックの幕
        if top.layer != 0 { return stop(.overlay) }
        if top.pid == selfPid { return stop(.ownApp) }
        if let b = s.bundleOf(top.pid), excluded.contains(b) { return stop(.excluded) }
        let firstNormal = s.windows.first(where: { $0.layer == 0 && $0.alpha > 0 })
        if firstNormal?.id == top.id && top.pid == s.frontPid { return stop(.alreadyFront) }
        // 出したばかりの窓が前に来ないとき（出せないアプリ）に、出し続けない
        if raisedId == top.id && s.now - raisedAt < 1.0 { cooling = true; return (.cooling, nil) }
        cooling = false
        if candidate != top.id { candidate = top.id; since = s.now }
        if s.now - since + 0.0001 < delay { return (.waiting, nil) }
        candidate = nil; raisedId = top.id; raisedAt = s.now
        return (.raise, top)
    }
}

enum Screen {
    /// 画面に出ている窓（手前から奥）。名前・中身は読まない＝画面収録の許可は要らない
    static func windows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { return nil }
            return Win(id: id, pid: pid, layer: layer, bounds: r, alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// カーソルの位置（左上原点）
    static func mouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    /// カーソルがどこかの画面の上の縁（4pt）にいるか
    static func atTopEdge() -> Bool {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.contains { s in s.frame.contains(p) && s.frame.maxY - p.y < 4 }
    }

    static var bundleCache: [pid_t: String] = [:]
    static func bundle(_ pid: pid_t) -> String? {
        if let b = bundleCache[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if let b { bundleCache[pid] = b }
        return b
    }

    static func snapshot(now: TimeInterval) -> Snapshot {
        Snapshot(mouse: mouse(), windows: windows(),
                 frontPid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                 bundleOf: bundle,
                 controlDown: NSEvent.modifierFlags.contains(.control),
                 buttonsDown: NSEvent.pressedMouseButtons != 0,
                 topEdge: atTopEdge(), now: now)
    }
}

enum Raiser {
    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// CGWindowList の窓に当たるアクセシビリティの窓を探す（位置と大きさで照らし合わせる。だめならカーソルの下から上へたどる）
    static func axWindow(for w: Win, at point: CGPoint?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let hit = list.first(where: { frame($0).map { abs($0.minX - w.bounds.minX) < 2 && abs($0.minY - w.bounds.minY) < 2 && abs($0.width - w.bounds.width) < 2 && abs($0.height - w.bounds.height) < 2 } ?? false }) {
            return hit
        }
        guard let p = point else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let e = el else { return nil }
        if let win = attr(e, kAXWindowAttribute) { return (win as! AXUIElement) }
        return (attr(e, kAXRoleAttribute) as? String) == kAXWindowRole ? e : nil
    }

    /// その窓だけを前に出し、操作の対象にする。
    /// アプリを最前面にすると（公開の仕組みでは）そのアプリの窓が全部前に出るので、
    /// もともと間にあったほかのアプリの窓を、奥から順に元の高さへ戻す
    static var generation = 0
    @discardableResult
    static func raise(_ w: Win, at point: CGPoint?, before: [Win]? = nil) -> Bool {
        guard let ax = axWindow(for: w, at: point) else { return false }
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let order = (before ?? Screen.windows()).filter { $0.layer == 0 && $0.alpha > 0 }
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        // 同じアプリのほかの窓（何枚あっても）より手前にいたほかのアプリの窓を、元の並びのまま上に積み直す。
        // 最前面への切り替えは少し遅れて効くので、抜かれたのを見てから（最大0.4秒）奥から順に AXRaise する
        guard let lastSibling = order.lastIndex(where: { $0.pid == w.pid && $0.id != w.id }) else { return true }
        let prefix = order[...lastSibling].filter { $0.id != w.id }
        let siblings = prefix.filter { $0.pid == w.pid }
        let passed = prefix.filter { $0.pid != w.pid }
        guard !passed.isEmpty else { return true }
        // もとの並びで「ほかのアプリの窓 p が、同じアプリの窓 q より手前」だった組
        let pairs = passed.flatMap { p in siblings.filter { q in
            (order.firstIndex(of: p) ?? 0) < (order.firstIndex(of: q) ?? 0) }.map { (p.id, $0.id) } }
        generation += 1; let gen = generation
        let start = Date()
        func restoreWhenPassed() {
            guard gen == generation else { return }   // 次の窓を出したら、古い戻しはやめる
            let now = Screen.windows().filter { $0.layer == 0 }
            func at(_ id: CGWindowID) -> Int? { now.firstIndex { $0.id == id } }
            let overtaken = pairs.contains { (p, q) in
                guard let ip = at(p), let iq = at(q) else { return false }   // 閉じた・しまった窓は見ない
                return ip > iq
            }
            if overtaken {
                // 戻すのはほかのアプリの窓だけ（同じアプリの窓に AXRaise すると、また全部が前に出る）
                for o in passed.reversed() where at(o.id) != nil {
                    if let e = axWindow(for: o, at: nil) { AXUIElementPerformAction(e, kAXRaiseAction as CFString) }
                }
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            } else if Date().timeIntervalSince(start) < 0.4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { restoreWhenPassed() }
            }
        }
        restoreWhenPassed()
        return true
    }
}
