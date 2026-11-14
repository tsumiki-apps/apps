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
    private var allowed: [Int]?    // 向きが決まったら、試してよい向き
    let base: Int                  // 1回に送る量（画面の点）
    private(set) var step: Int
    private var still = 0, lost = 0          // 継いだ後（向きが決まった後）に数える
    // まだ継いでいない間の数え方（向きの試し方）
    private var stall = 0          // 今の向きにしてから、継げないまま送った回数
    private var grace = 0          // 向きを変えた直後、出発点へ戻るまでに要る回数（逆へ動いた分）
    private var lostRun = 0        // 続けて「見失った」回数
    private(set) var turns = 0     // 今の軸（上下／左右）で向きを変えた回数
    private var firstTurnByStill = false
    /// 継いだ後の「戻る」が続いて終えた（札に知らせる）
    private(set) var bounced = false
    static let stillToEnd = 9      // 継いだ後、これだけ合図を送っても動かなければ端（AutoDriver の間隔で約5秒＝続きの読み込みを待つ。3秒では足りないページがある）
    static let stillToTurn = 3     // まだ一度も継いでいないとき、これだけ動かなければ別の向きを試す（約1.8秒。早すぎると反応の遅いページで逆向きに決まる）
    /// 継いだ後に止まっている＝続きの読み込みを待っているかも（札に「待機」を出す）
    var waiting: Bool { locked && still >= 2 }

    init(viewLength: CGFloat) {
        base = max(20, Int(viewLength * 0.3))
        step = base
    }

    /// 自動を始めたときの最初の一送り
    func begin() -> Next { still = 0; stall = 0; return move(step) }

    private func move(_ k: Int) -> Next {
        let (x, y) = AutoPilot.dirs[dirIndex]
        return .scroll(dx: x * k, dy: y * k)
    }

    /// 向きが決まったら、それに合う向きだけを試す（縦に決まったのに横へ送らない）
    func axisDecided(_ a: ScrollAxis) {
        guard !locked else { return }
        let want = a == .vertical ? [0, 1] : [2, 3]
        if allowed == nil, !want.contains(dirIndex) { dirIndex = want[0] }
        allowed = want
    }

    /// まだ継いでいない間の向きの決め方（合図の正負はナチュラルスクロールやアプリで逆になりうる）：
    ///  ・ページが戻った（.back）／見失ったが2回続いた＝逆向きに動いている → すぐ同じ軸の逆向きへ（途中から始めたとき）
    ///  ・動かないが続いた＝端か、届かない → 逆向きへ（いちばん上から始めたとき）
    ///  ・逆向きにしても継げない → 最初の切り替えが「動いた」からなら誤検知かもしれないので1回だけ戻す。
    ///    「動かない」からなら、その向きは試し済み＝次の軸へ（決まっていれば終える）
    /// 逆へ動いた分は戻すのに同じ回数かかるので、そのあいだ（grace）は数えない
    private func turn(byStill: Bool) -> Next {
        let canTurn = turns == 0 || (turns == 1 && !firstTurnByStill)
        if canTurn {
            if turns == 0 { firstTurnByStill = byStill }
            grace = turns == 0 && byStill ? 0 : stall      // 動かなかった向きからなら、戻す分はない
            turns += 1
            stall = 0; lostRun = 0
            dirIndex ^= 1
            return move(step)
        }
        // この軸では動かない＝次の軸へ
        let nextIndex = (dirIndex / 2 + 1) * 2
        if nextIndex >= AutoPilot.dirs.count { return .finish }          // どの向きにも動かない
        if let w = allowed, !w.contains(nextIndex) { return .finish }    // 選んだ向き（上下／左右）の両方で動かない
        dirIndex = nextIndex
        turns = 0; grace = 0; stall = 0; lostRun = 0
        return move(step)
    }

    /// 戻った・見失ったときに向きを変えるか（最初の向きのときだけ）。変えないなら継げなかった1回として数える
    private func moved(back: Bool) -> Next {
        stall += 1
        if back { lostRun = 0 } else { lostRun += 1 }
        if turns == 0, back || lostRun >= 2 { return turn(byStill: false) }
        if stall >= grace + AutoPilot.stillToTurn { return turn(byStill: false) }
        return move(step)
    }

    /// 間合いの途中で継げた（その後に見失った・戻った）＝向きは合っている。最後の結果だけ渡されても向きを決めておく
    func markJoined() { locked = true }

    func next(after r: StepResult) -> Next {
        switch r {
        case .first:
            return move(step)
        case .added:
            locked = true; still = 0; lost = 0
            step = min(base, step + base / 4)       // 速すぎで落とした分を少しずつ戻す
            return move(step)
        case .still:
            if locked { still += 1; return still >= AutoPilot.stillToEnd ? .finish : move(step) }
            stall += 1; lostRun = 0
            if stall >= grace + AutoPilot.stillToTurn { return turn(byStill: true) }
            return move(step)
        case .back:
            if !locked { return moved(back: true) }
            // 継いだ後に戻った（端での跳ね返り・ページが勝手に戻った）＝そのまま進める。続けば終えて知らせる
            lost += 1
            if lost >= 6 { bounced = true; return .finish }
            return move(step)
        case .lost:
            // まだ継いでいない＝送りすぎではない（1回は画面の3割）。逆向きに動いて合わないことがある
            if !locked { return moved(back: false) }
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

/// 合図を送る間合いを決める。撮るコマ（0.12秒ごと）のたびに送ると速すぎ、
/// 「4コマ動かない＝端」だと続きを読み込むページで途中で止まる（ExtraTest の realRun で再現）。
/// そこで、合図は gap 秒以上あけ、ページが動いている間は止まるのを待ってから次を送る。
/// 端かどうかは「合図を送ったのに動かなかった回数」で数える（コマ数では数えない）。
final class AutoDriver {
    let pilot: AutoPilot
    static let gap = 0.6           // 合図と合図の間（秒）＝速さ
    static let settle = 1.5        // 動き続けていても、これだけ経てば次を送る
    private var lastPost = 0.0
    private var last: StepResult?     // 前の合図からいちばん最近の「継いだ／戻った／見失った」
    private var sawAdded = false      // 前の合図から1回でも継いだ

    init(pilot: AutoPilot) { self.pilot = pilot }

    func begin(now: Double) -> AutoPilot.Next { lastPost = now; last = nil; sawAdded = false; return pilot.begin() }

    /// 1コマ継ぐごとに呼ぶ。nil＝まだ待つ
    func frame(_ r: StepResult, now: Double) -> AutoPilot.Next? {
        switch r {
        case .full: return .finish
        case .added: last = r; sawAdded = true
        case .lost, .back: last = r
        default: break
        }
        let dt = now - lastPost
        if dt < Self.gap { return nil }
        if case .added = r, dt < Self.settle { return nil }      // まだ動いている＝止まるのを待つ
        // 最後が「見失った」なら送りすぎ＝戻して半分に（途中で継げていても、最後の状態で決める）
        let sum: StepResult = last ?? .still
        if sawAdded { pilot.markJoined() }
        last = nil; sawAdded = false; lastPost = now
        return pilot.next(after: sum)
    }
}

enum Wheel {
    /// アクセシビリティの許可（ask＝なければ許可の画面を出す）
    static func trusted(ask: Bool) -> Bool {
        #if APPSTORE
        if CGPreflightPostEventAccess() { return true }
        return ask ? CGRequestPostEventAccess() : false
        #endif
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: ask] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    /// 画面座標（左下原点の Cocoa）の点に、ホイールの合図を送る。dy<0 で下へのつもり。
    /// 実際の向きはナチュラルスクロールの設定やアプリで逆になりうるので、決め打ちせず AutoPilot が結果（戻った＝.back）を見て切り替える
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
