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
    /// Dock（Mission Control・Launchpad・App Exposé を描くアプリ）
    var dockPid: pid_t? = nil
    /// カーソルの下で実際にマウスを受けるアプリ（アクセシビリティの当たり判定）。要るときだけ読む
    var axOwnerAt: ((CGPoint) -> pid_t?)? = nil
}

enum Why: String {
    case raise = "前に出す"
    case paused = "休み中"
    case controlKey = "control"
    case mouseDown = "ボタンを押している"
    case menuOpen = "メニューが開いている"
    case spaceChanged = "デスクトップを切り替えた直後"
    case topEdge = "画面の上の縁"
    case noWindow = "窓がない（デスクトップ）"
    case missionControl = "Mission Control・Launchpad の最中"
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
    /// 動かしている途中でも、この時間その窓に乗っていたら出す（通り抜けで出さないための待ち）
    var delay: TimeInterval = 0.05
    /// カーソルを止めてからこの時間で出す（nil＝止めても早めない）。置いたらすぐ切り替えるための近道
    var restDelay: TimeInterval?
    var excluded: Set<String> = []
    var pausedUntil: TimeInterval = 0          // .infinity＝ずっと休む
    let selfPid: pid_t

    private var spaceChangedAt: TimeInterval = -1000
    private var mouseAtSpaceChange: CGPoint?
    private var candidate: CGWindowID?
    private var since: TimeInterval = 0
    private var raisedId: CGWindowID?
    private var raisedAt: TimeInterval = -1000
    private var lastMouse: CGPoint?
    private var stillSince: TimeInterval = 0
    /// Mission Control などの最中だったか（閉じたら、カーソルを動かすまで待つ）
    private var inMissionControl = false
    /// 出したのに前に来ない窓を、続けて何回出し直したか（間隔を倍々に延ばす。成功＝前に来たら 0）
    private var retryStreak = 0
    /// 出し直しを待つ間隔：1・2・4・8秒（上限）
    private var coolSpan: TimeInterval { min(8, pow(2, Double(min(retryStreak, 3)))) }
    /// 出すのに失敗（AX が通らない）を続けた回数（窓ごと）。3回で「許可の取り残し」の疑いとして知らせる
    private var axFails: [CGWindowID: Int] = [:]
    var needsAttention: Bool { axFails.values.contains { $0 >= 3 } }
    /// 判断の理由をログに出す先（HOVER_LOG のとき）
    var onNote: ((String) -> Void)?
    // 止まったままのカーソルで判断し直すための覚え
    private var baseline: (pid: pid_t, win: CGWindowID?)?
    private var held = false
    private static let transient: Set<Why> = [.menuOpen, .mouseDown, .controlKey, .topEdge, .stayApp, .missionControl]

    init(selfPid: pid_t) { self.selfPid = selfPid }

    func spaceChanged(now: TimeInterval, mouse: CGPoint) {
        spaceChangedAt = now; mouseAtSpaceChange = mouse; candidate = nil
    }

    /// 見張りが要るか（待っている窓がある、または出し直しの間隔が明けた）。出し直しを待っているあいだは重い読み直しをしない
    func needsStep(now: TimeInterval) -> Bool {
        if candidate != nil { return true }
        return cooling && now >= raisedAt + coolSpan
    }
    var waitingForCandidate: Bool { candidate != nil || cooling }
    private var cooling = false

    /// 窓を出した結果を受ける（AX が通ったか）。窓ごとに連続の失敗を数える
    func reportRaise(id: CGWindowID, ok: Bool, skipped: Bool = false) {
        // デスクトップを切り替えないために見送った＝許可の失敗ではない。出し直しは最初から長い間隔（8秒）で
        if skipped { axFails[id] = nil; if raisedId == id { retryStreak = max(retryStreak, 3) }; return }
        if ok { axFails[id] = nil; return }
        if axFails.count > 50 { axFails.removeAll() }
        axFails[id, default: 0] += 1
    }

    private static func front(_ s: Snapshot) -> (pid: pid_t, win: CGWindowID?) {
        (s.frontPid, s.windows.first(where: { $0.layer == 0 && $0.alpha > 0 })?.id)
    }

    /// カーソルが止まったままのときの見直し（軽く数百msごとに呼ぶ）。次の2つのときだけ判断し直す：
    ///   ①止めていた理由（メニュー・ボタン・除外アプリなど）が消え、そのあいだに前の窓が変わっていない
    ///   ②前にいた窓が閉じた（消えた）
    /// ユーザー自身が別の窓・アプリを前にした場合（前の窓がまだある）は、勝手に戻さない
    func recheck(_ s: Snapshot) -> (Why, Win?)? {
        guard let base = baseline else { baseline = Brain.front(s); return nil }
        let cur = Brain.front(s)
        let closed = base.win != nil && !s.windows.contains { $0.id == base.win }
        let changed = cur.pid != base.pid || cur.win != base.win
        if closed { return step(s) }
        if changed { held = false; baseline = cur; return nil }
        if held { return step(s) }
        return nil
    }

    /// 1回分の判断。.raise のときだけ窓を返す
    func step(_ s: Snapshot) -> (Why, Win?) {
        let r = judge(s)
        if r.0 == .alreadyFront { raisedId = nil; retryStreak = 0 }
        held = Brain.transient.contains(r.0)
        baseline = Brain.front(s)
        return r
    }

    private func judge(_ s: Snapshot) -> (Why, Win?) {
        func stop(_ w: Why) -> (Why, Win?) { candidate = nil; cooling = false; return (w, nil) }
        // カーソルが止まっているか（前の回から 1pt 未満しか動いていない）
        if let m = lastMouse, hypot(m.x - s.mouse.x, m.y - s.mouse.y) < 1 {} else { stillSince = s.now }
        lastMouse = s.mouse
        if s.now < pausedUntil { return stop(.paused) }
        if s.controlDown { return stop(.controlKey) }
        if s.buttonsDown { return stop(.mouseDown) }
        // メニュー（101）：前のアプリのものか、カーソルの近く（120pt 以内）のときだけ。
        // 遠くにある101の窓（出しっぱなしの常駐アプリ）で、ずっと止まらないようにする
        if s.windows.contains(where: { $0.layer == Level.popUpMenu && $0.alpha > 0
            && ($0.pid == s.frontPid || $0.bounds.insetBy(dx: -120, dy: -120).contains(s.mouse)) }) { return stop(.menuOpen) }
        // Mission Control・Launchpad・App Exposé＝Dock が画面を覆う大きな窓を出している。
        // この最中に前に出すと、Mission Control を抜けて別のデスクトップへ移ることがあるので、何もしない。
        // 閉じたあとは、デスクトップを切り替えた直後と同じく、カーソルを動かすまで待つ
        if Brain.missionControlShown(s) { inMissionControl = true; return stop(.missionControl) }
        if inMissionControl { inMissionControl = false; spaceChanged(now: s.now - 0.4, mouse: s.mouse) }
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
        // 窓と窓のあいだ（デスクトップ）では何もしない。
        // Finder を前に出すと、Finder の窓が別のデスクトップにあるとき、そこへ切り替わってしまう（「アプリケーションの切り替えで…スペースに移動」が入っていると）
        guard let top = Brain.topWindow(s) else { return stop(.noWindow) }
        // 普通の窓（高さ0）以外＝Dock・メニューバー・浮いたパネル・つみきショットの範囲選び・つみきロックの幕
        if top.layer != 0 { return stop(.overlay) }
        if top.pid == selfPid { return stop(.ownApp) }
        if let b = s.bundleOf(top.pid), excluded.contains(b) { return stop(.excluded) }
        let firstNormal = s.windows.first(where: { $0.layer == 0 && $0.alpha > 0 })
        if firstNormal?.id == top.id && top.pid == s.frontPid { return stop(.alreadyFront) }
        return decide(top, s, why: .raise)
    }

    /// カーソルの下のいちばん手前の窓。画面を覆う大きな浮いた窓（通知センターなど）は、
    /// その場所でマウスを受けていなければ（当たり判定の持ち主が別のアプリ）素通しとみなして、下の窓を見る
    static func topWindow(_ s: Snapshot) -> Win? {
        var owner: pid_t?? = nil   // 読むのは1回だけ
        for w in s.windows where w.alpha > 0 && w.bounds.contains(s.mouse) {
            if w.layer > 0 && w.layer != Level.menuBar && w.layer != Level.statusItem && min(w.bounds.width, w.bounds.height) >= 300 {
                if owner == nil { owner = .some(s.axOwnerAt?(s.mouse)) }
                if let o = owner!, o != w.pid { continue }
            }
            return w
        }
        return nil
    }

    /// Dock が画面を覆う大きな窓（短い辺 300pt 以上）を出しているか＝Mission Control・Launchpad・App Exposé の最中。
    /// いつもの Dock は細長い帯なので当たらない
    static func missionControlShown(_ s: Snapshot) -> Bool {
        guard let d = s.dockPid else { return false }
        return s.windows.contains { $0.pid == d && $0.alpha > 0 && min($0.bounds.width, $0.bounds.height) >= 300 }
    }

    /// 待ち時間・出したばかりを見て、出すかどうかを決める
    private func decide(_ top: Win, _ s: Snapshot, why: Why) -> (Why, Win?) {
        // 出したばかりの窓が前に来ないとき（出せないアプリ）に、出し続けない
        if raisedId == top.id && s.now - raisedAt < coolSpan { cooling = true; return (.cooling, nil) }
        cooling = false
        if candidate != top.id { candidate = top.id; since = s.now }
        let onLongEnough = s.now - since + 0.0001 >= delay
        // 止めた近道：その窓に入ってから、かつ止めてから restDelay たったら出す
        let restedLongEnough = restDelay.map { s.now - max(since, stillSince) + 0.0001 >= $0 } ?? false
        if !onLongEnough && !restedLongEnough { return (.waiting, nil) }
        candidate = nil
        // 前に出した同じ窓をまた出す＝前の回は効かなかった → 次の間隔を倍に
        if raisedId == top.id { retryStreak += 1 } else { retryStreak = 0 }
        raisedId = top.id; raisedAt = s.now
        return (why, top)
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

    /// そのアプリの普通の窓すべて（別のデスクトップ・しまった窓も）。いまのデスクトップに見えているかつき
    static func allWindows(of pid: pid_t) -> [(bounds: CGRect, onScreen: Bool)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard d[kCGWindowOwnerPID as String] as? pid_t == pid, d[kCGWindowLayer as String] as? Int == 0,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd) else { return nil }
            return (r, d[kCGWindowIsOnscreen as String] as? Bool ?? false)
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
                 topEdge: atTopEdge(), now: now,
                 dockPid: dockPid(),
                 axOwnerAt: { axOwnerCached(at: $0) })
    }

    /// その位置で実際にマウスを受けるアプリ（読めなければ nil＝手前の窓をそのまま信じる）
    private static var ownerCache: (at: TimeInterval, pid: pid_t?)?
    /// 動かしているあいだ毎回読まないよう、0.05 秒は前の答えを使う（毎秒20回まで）
    static func axOwnerCached(at p: CGPoint) -> pid_t? {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = ownerCache, now - c.at < 0.05 { return c.pid }
        let r = axOwner(at: p); ownerCache = (now, r); return r
    }

    static func axOwner(at p: CGPoint) -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let e = el else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(e, &pid) == .success && pid > 0 ? pid : nil
    }

    private static var dockCache: pid_t?
    static func dockPid() -> pid_t? {
        if let p = dockCache, NSRunningApplication(processIdentifier: p) != nil { return p }
        dockCache = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        return dockCache
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
        let found: AXUIElement?
        if let win = attr(e, kAXWindowAttribute) { found = (win as! AXUIElement) }
        else { found = (attr(e, kAXRoleAttribute) as? String) == kAXWindowRole ? e : nil }
        // 持ち主が違う窓（別のアプリの窓が間に入っていた）は使わない
        guard let f = found else { return nil }
        var owner: pid_t = 0
        return AXUIElementGetPid(f, &owner) == .success && owner == w.pid ? f : nil
    }

    /// 直近の失敗・見送りの理由（HOVER_LOG で出す）
    static var lastNote: String?
    /// 直近の raise が「別のデスクトップへ移るおそれがあるので見送った」か（許可の失敗とは数えない）
    static var lastSkipped = false

    /// その窓だけを前に出し、操作の対象にする。
    /// アプリを最前面にすると（公開の仕組みでは）そのアプリの窓が全部前に出るので、
    /// もともと間にあったほかのアプリの窓を、奥から順に元の高さへ戻す
    static var generation = 0
    @discardableResult
    static func raise(_ w: Win, at point: CGPoint?, before: [Win]? = nil) -> Bool {
        lastNote = nil; lastSkipped = false
        guard let ax = axWindow(for: w, at: point) else { lastNote = "出せなかった：アクセシビリティの窓が見つからない（pid \(w.pid)）"; return false }
        return bringFront(pid: w.pid, keep: w.id, ax: ax, before: before)
    }

    /// 最前面にしてもデスクトップが切り替わらないか＝アプリのメインの窓が target・なし・いまのデスクトップにある窓のどれか。
    /// AXRaise が遅れて効くアプリのために約 0.1 秒待つ（固まったアプリでは1回の読みが最大 0.15 秒かかる）
    static func mainSettles(app: AXUIElement, to target: AXUIElement, timeout: TimeInterval = 0.1,
                            onThisSpace: (AXUIElement) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if mainIsOK(attr(app, kAXMainWindowAttribute), target, onThisSpace: onThisSpace) { return true }
            if Date() >= end { return false }
            usleep(10_000)
        }
    }

    static func mainIsOK(_ main: CFTypeRef?, _ target: AXUIElement, onThisSpace: (AXUIElement) -> Bool) -> Bool {
        guard let m = main, CFGetTypeID(m) == AXUIElementGetTypeID() else { return true }
        if CFEqual(m, target) { return true }
        return onThisSpace(m as! AXUIElement)
    }

    /// その枠の窓が「いまのデスクトップに見えている1枚だけ」か。別のデスクトップに同じ枠の窓（最大化した窓など）があれば、見分けられないので false
    static func onlyHere(frame f: CGRect, among mine: [(bounds: CGRect, onScreen: Bool)]) -> Bool {
        let same = mine.filter { sameFrame($0.bounds, f) }
        return same.count == 1 && same[0].onScreen
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// アプリを最前面にして、keep 以外の同じアプリの窓より手前にいたほかのアプリの窓を元の並びに戻す
    private static func bringFront(pid: pid_t, keep: CGWindowID, ax: AXUIElement, before: [Win]?) -> Bool {
        let w = Win(id: keep, pid: pid, layer: 0, bounds: .zero, alpha: 1)
        let app = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let order = (before ?? Screen.windows()).filter { $0.layer == 0 && $0.alpha > 0 }
        do {
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            // アプリを最前面にすると、そのアプリの「メインの窓」のあるデスクトップへ切り替わることがある。
            // メインの窓が「乗せた窓・なし・いまのデスクトップにある窓」のどれかになったのを見てから最前面にする。別のデスクトップの窓のままなら見送る
            let mine = Screen.allWindows(of: pid)
            guard mainSettles(app: app, to: ax, onThisSpace: { m in frame(m).map { Raiser.onlyHere(frame: $0, among: mine) } ?? false }) else {
                lastSkipped = true
                lastNote = "見送り：そのアプリのメインの窓が別のデスクトップにある（か見分けられない）（pid \(pid)）。最前面にするとそこへ移るので出さない"
                return true
            }
        }
        let fr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard fr == .success else {
            lastNote = "出せなかった：アプリを最前面にできない（pid \(pid)・AX エラー \(fr.rawValue)）" + (fr == .apiDisabled ? "。許可の取り残しの疑い＝システム設定＞プライバシーとセキュリティ＞アクセシビリティで一度外して付け直す" : "")
            return false
        }
        // 同じアプリのほかの窓（何枚あっても）より手前にいたほかのアプリの窓を、元の並びのまま上に積み直す。
        // 最前面への切り替えは少し遅れて効くので、抜かれたのを見てから（最大1秒）奥から順に AXRaise する
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
            } else if Date().timeIntervalSince(start) < 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { restoreWhenPassed() }
            }
        }
        restoreWhenPassed()
        return true
    }
}
