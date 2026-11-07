// 自動スクロール：範囲の真ん中に「ホイールを回した」合図を送り、1コマ継ぐごとに少しずつ送る。
// 端まで行って動かなくなったら仕上げる。手でマウスやキーを触ったら自動をやめて手動に戻す。
// 合図を送るにはアクセシビリティの許可が要る（手で回す方式は許可なしのまま使える）。
import AppKit
import ApplicationServices

/// 次にどうするか（つなぎの結果だけから決める＝画面なしで確かめられる）
final class AutoPilot {
    enum Next: Equatable { case scroll(dx: Int, dy: Int), finish }

    /// 試す向き（縦の下・上・横の右・左）。合図の正負と見た目の向きは設定（ナチュラル）やアプリで変わりうるので、
    /// 動かなければ次の向きを試し、一度継げたらその向きに決める
    static let dirs: [(Int, Int)] = [(0, -1), (0, 1), (-1, 0), (1, 0)]
    private(set) var dirIndex = 0
    private(set) var locked = false
    let base: Int                  // 1回に送る量（画面の点）
    private(set) var step: Int
    private var still = 0, lost = 0
    static let stillToEnd = 4      // 継いだ後、これだけ続けて動かなければ端
    static let stillToTurn = 2     // まだ一度も継いでいないとき、これだけ動かなければ別の向きを試す

    init(viewLength: CGFloat) {
        base = max(20, Int(viewLength * 0.3))
        step = base
    }

    /// 自動を始めたときの最初の一送り
    func begin() -> Next { still = 0; return move(step) }

    private func move(_ k: Int) -> Next {
        let (x, y) = AutoPilot.dirs[dirIndex]
        return .scroll(dx: x * k, dy: y * k)
    }

    /// 向きが決まったら、それに合う向きだけを試す（縦に決まったのに横へ送らない）
    func axisDecided(_ a: ScrollAxis) {
        guard !locked else { return }
        let want = a == .vertical ? [0, 1] : [2, 3]
        if !want.contains(dirIndex) { dirIndex = want[0] }
    }

    func next(after r: StepResult) -> Next {
        switch r {
        case .first:
            return move(step)
        case .added:
            locked = true; still = 0; lost = 0
            step = min(base, step + base / 4)       // 速すぎで落とした分を少しずつ戻す
            return move(step)
        case .still:
            still += 1
            if locked { return still >= AutoPilot.stillToEnd ? .finish : move(step) }
            if still >= AutoPilot.stillToTurn {
                still = 0
                dirIndex += 1
                if dirIndex >= AutoPilot.dirs.count { return .finish }   // どの向きにも動かない
            }
            return move(step)
        case .lost:
            // 送りすぎ＝少し戻して、送る量を半分に（比べる相手は最後に継いだコマ）
            lost += 1
            if lost >= 6 { return .finish }
            let back = step / 2
            step = max(8, step / 2)
            return move(-back)
        case .full:
            return .finish
        }
    }
}

enum Wheel {
    /// アクセシビリティの許可（ask＝なければ許可の画面を出す）
    static func trusted(ask: Bool) -> Bool {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: ask] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    /// 画面座標（左下原点の Cocoa）の点に、ホイールの合図を送る。dy<0 で下へ（ふつうの向き）
    static func post(dx: Int, dy: Int, at p: NSPoint) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: p.x, y: primaryH - p.y)
        // 大きな量は小分けにする（一度に大きく送ると、アプリによっては無視・加速される）
        var left = (dx, dy)
        while left != (0, 0) {
            let sx = max(-60, min(60, left.0)), sy = max(-60, min(60, left.1))
            left = (left.0 - sx, left.1 - sy)
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(sy), wheel2: Int32(sx), wheel3: 0) else { return }
            e.location = cg
            e.post(tap: .cghidEventTap)
        }
    }

    static func moveMouse(to p: NSPoint) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: primaryH - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// 自分以外が起こした入力（手のスクロール・クリック・キー）を見張る。自分が送った合図は数えない
final class HandWatcher {
    private var monitor: Any?
    func start(_ onHand: @escaping () -> Void) {
        let me = Int64(ProcessInfo.processInfo.processIdentifier)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { e in
            if let cg = e.cgEvent, cg.getIntegerValueField(.eventSourceUnixProcessID) == me { return }
            onHand()
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
