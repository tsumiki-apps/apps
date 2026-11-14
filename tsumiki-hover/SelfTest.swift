// `--selftest`：判断（Brain）に架空の画面の様子を流して確かめる。許可は要らない・画面には触らない。
// 困りやすい場面（メニュー・ドラッグ・Alfred/Paste・つみきショットの範囲選び・デスクトップの切り替え・Mission Control）を1つずつ
import AppKit

enum SelfTest {
    static func run() -> Int32 {
        var ng = 0
        func check(_ ok: Bool, _ s: String) { print(ok ? "✓" : "✗", s); if !ok { ng += 1 } }

        // 架空の画面：前に Safari の窓（pid 10）、後ろに メモ の窓（pid 20）。カーソルはメモだけが見える所
        let bundles: [pid_t: String] = [10: "com.apple.Safari", 20: "com.apple.Notes", 30: "com.runningwithcrayons.Alfred",
                                        40: "com.wiheads.paste", 50: "com.tsumiki.shot", 60: "com.apple.dock", 90: "com.apple.finder", 99: "com.tsumiki.hover"]
        let safari = Win(id: 1, pid: 10, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 1)
        let notes = Win(id: 2, pid: 20, layer: 0, bounds: CGRect(x: 400, y: 100, width: 800, height: 600), alpha: 1)
        let menuBar = Win(id: 3, pid: 70, layer: Level.menuBar, bounds: CGRect(x: 0, y: 0, width: 1440, height: 24), alpha: 1)
        let p = CGPoint(x: 1000, y: 400)
        func snap(_ t: TimeInterval, windows: [Win]? = nil, front: pid_t = 10, mouse: CGPoint? = nil,
                  control: Bool = false, buttons: Bool = false, edge: Bool = false) -> Snapshot {
            Snapshot(mouse: mouse ?? p, windows: windows ?? [menuBar, safari, notes], frontPid: front,
                     bundleOf: { bundles[$0] }, controlDown: control, buttonsDown: buttons, topEdge: edge, now: t)
        }
        func fresh(_ delay: TimeInterval = 0.05) -> Brain {
            let b = Brain(selfPid: 99); b.delay = delay
            b.excluded = ["com.runningwithcrayons.Alfred", "com.wiheads.paste", "com.tsumiki.shot"]; return b
        }

        // 基本
        var b = fresh()
        check(b.step(snap(0)).0 == .waiting, "入った直後は待つ")
        let r = b.step(snap(0.05))
        check(r.0 == .raise && r.1?.id == 2, "待ち時間（50ms）のあとメモを出す")
        check(b.step(snap(0.3, windows: [menuBar, notes, safari], front: 20)).0 == .alreadyFront, "前に出たあとは何もしない")
        b = fresh(0)
        check(b.step(snap(0)).0 == .raise, "待ち時間0＝すぐ出す")
        b = fresh(0.3)
        _ = b.step(snap(0)); check(b.step(snap(0.2)).0 == .waiting, "300ms のときは 200ms ではまだ出さない")
        check(b.step(snap(0.31)).0 == .raise, "300ms で出す")
        // 出せないアプリに出し続けない
        b = fresh(0)
        _ = b.step(snap(0)); check(b.step(snap(0.1)).0 == .cooling, "出したのに前に来ないとき、1秒は出し直さない")
        check(b.waitingForCandidate, "出せなかったあいだも見張り続ける（カーソルが止まっていても）")
        check(!b.needsStep(now: 0.5), "W3：出し直しを待っているあいだは読み直さない（10msごとの重い読みをしない）")
        check(b.needsStep(now: 1.05), "W3：間隔が明けたら読み直す")
        check(b.step(snap(1.2)).0 == .raise, "1秒たったら出し直す")
        // W3：出し直しても前に来ないなら間隔を倍々に（2秒・4秒・8秒上限）。前に来たら元に戻る
        check(b.step(snap(2.5)).0 == .cooling, "W3：2回目の出し直しのあとは 2秒は出さない")
        check(b.step(snap(3.3)).0 == .raise, "W3：2秒たったら3回目")
        check(b.step(snap(6.0)).0 == .cooling && b.step(snap(7.4)).0 == .raise, "W3：その次は4秒")
        var t = 7.4; var spans: [Double] = []
        for _ in 0..<3 { let tt = t; while b.step(snap(t)).0 != .raise { t += 0.5 }; spans.append(t - tt) }
        check((spans.last ?? 0) > 7.9 && (spans.last ?? 99) < 8.6, "W3：間隔は 8秒で頭打ち")
        check(b.step(snap(t + 0.1, windows: [menuBar, notes, safari], front: 20)).0 == .alreadyFront, "W3：前に来たら")
        check(b.step(snap(t + 0.2, windows: [menuBar, safari, notes], front: 10, mouse: CGPoint(x: 1001, y: 400))).0 == .raise, "W3：成功のあとは間隔が 1秒に戻る（すぐまた出せる）")
        check(b.step(snap(t + 1.3, mouse: CGPoint(x: 1002, y: 400))).0 == .raise, "W3：戻ったあとの待ちは 1秒")
        // 窓を移るたびに待ち直す
        b = fresh()
        let third = Win(id: 12, pid: 80, layer: 0, bounds: CGRect(x: 1250, y: 100, width: 150, height: 600), alpha: 1)
        let three = [menuBar, safari, notes, third]
        _ = b.step(snap(0, windows: three)); _ = b.step(snap(0.03, windows: three, mouse: CGPoint(x: 1300, y: 400)))
        check(b.step(snap(0.06, windows: three)).0 == .waiting, "別の窓を通ったら待ち直す（通った窓も出す候補）")
        check(b.step(snap(0.12, windows: three)).0 == .raise, "待ち直したあと出す")

        // 感度：止めたらすぐ出す（速い＝動かしている途中は120ms・止めたら30ms）
        b = fresh(0.12); b.restDelay = 0.03
        _ = b.step(snap(0, mouse: CGPoint(x: 990, y: 400)))
        check(b.step(snap(0.01)).0 == .waiting, "感度：入って止めた直後はまだ")
        check(b.step(snap(0.04)).0 == .raise, "感度：止めて30msで出す（120ms 待たない）")
        b = fresh(0.12); b.restDelay = 0.03
        var x: CGFloat = 900
        var moving: Why = .waiting
        for t in stride(from: 0.0, through: 0.1, by: 0.01) { x += 3; moving = b.step(snap(t, mouse: CGPoint(x: x, y: 400))).0 }
        check(moving == .waiting, "感度：動かしているあいだは 120ms までは出さない（通り抜けで出さない）")
        x += 3; check(b.step(snap(0.13, mouse: CGPoint(x: x, y: 400))).0 == .raise, "感度：動かし続けても 120ms で出す")
        b = fresh(0.6); b.restDelay = 0.25
        _ = b.step(snap(0, mouse: CGPoint(x: 990, y: 400))); _ = b.step(snap(0.01))
        check(b.step(snap(0.2)).0 == .waiting, "感度：ゆっくりは止めても 250ms まで待つ")
        check(b.step(snap(0.27)).0 == .raise, "感度：ゆっくりは止めて 250ms で出す")

        // 止める場面
        b = fresh(0)
        check(b.step(snap(0, control: true)).0 == .controlKey, "control を押しているあいだは止まる")
        check(b.step(snap(0, buttons: true)).0 == .mouseDown, "ドラッグ中（ボタンを押している）は止まる")
        let menu = Win(id: 4, pid: 10, layer: Level.popUpMenu, bounds: CGRect(x: 100, y: 30, width: 200, height: 300), alpha: 1)
        check(b.step(snap(0, windows: [menu, menuBar, safari, notes])).0 == .menuOpen, "メニューを開いているあいだは止まる（前のアプリのメニューなら、カーソルがメニューの外でも）")
        // W5：遠くに出しっぱなしの101の窓（別のアプリ）では止まらない／近い・カーソルを含むなら止まる
        let farMenu = Win(id: 40, pid: 20, layer: Level.popUpMenu, bounds: CGRect(x: 0, y: 700, width: 200, height: 150), alpha: 1)
        check(fresh(0).step(snap(0, windows: [farMenu, menuBar, safari, notes])).0 == .raise, "W5：遠くにある別のアプリの101の窓では止まらない")
        let nearMenu = Win(id: 41, pid: 20, layer: Level.popUpMenu, bounds: CGRect(x: 900, y: 250, width: 100, height: 100), alpha: 1)
        check(b.step(snap(0, windows: [nearMenu, menuBar, safari, notes])).0 == .menuOpen, "W5：カーソルの近くの101の窓は「メニュー中」")
        let underMenu = Win(id: 42, pid: 20, layer: Level.popUpMenu, bounds: CGRect(x: 950, y: 350, width: 100, height: 100), alpha: 1)
        check(b.step(snap(0, windows: [underMenu, menuBar, safari, notes])).0 == .menuOpen, "W5：カーソルを含む101の窓は「メニュー中」")
        check(b.step(snap(0, mouse: CGPoint(x: 500, y: 10))).0 == .overlay, "メニューバーの上では何もしない")
        check(b.step(snap(0, edge: true)).0 == .topEdge, "画面の上の縁（隠れたメニューバーが出る所）では何もしない")
        let dock = Win(id: 5, pid: 60, layer: 20, bounds: CGRect(x: 300, y: 820, width: 900, height: 80), alpha: 1)
        check(b.step(snap(0, windows: [menuBar, dock, safari, notes], mouse: CGPoint(x: 900, y: 850))).0 == .overlay, "Dock の上では何もしない")
        // Alfred：前にいて、浮いた窓を出している
        let alfredWin = Win(id: 6, pid: 30, layer: 8, bounds: CGRect(x: 400, y: 200, width: 600, height: 80), alpha: 1)
        check(b.step(snap(0, windows: [alfredWin, menuBar, safari, notes], front: 30)).0 == .stayApp, "Alfred が出ているあいだは、外の窓に乗っても止まる")
        // Paste：前に出ない浮いた窓（前のアプリは Safari のまま）
        let pasteWin = Win(id: 7, pid: 40, layer: 9, bounds: CGRect(x: 0, y: 600, width: 1440, height: 300), alpha: 1)
        check(b.step(snap(0, windows: [pasteWin, menuBar, safari, notes])).0 == .stayApp, "Paste の窓が出ているあいだは止まる（Paste が前にいなくても）")
        // メニューバーに常駐しているだけ（ステータス項目）なら止めない
        let alfredStatus = Win(id: 8, pid: 30, layer: Level.statusItem, bounds: CGRect(x: 1200, y: 0, width: 24, height: 24), alpha: 1)
        check(b.step(snap(0, windows: [alfredStatus, menuBar, safari, notes])).0 == .raise, "除外アプリがメニューバーにいるだけなら動く")
        // つみきショットの範囲選び（画面いっぱいの幕＝スクリーンセーバーの高さ）
        let shotVeil = Win(id: 9, pid: 50, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 1)
        b = fresh(0)
        check(b.step(snap(0, windows: [shotVeil, menuBar, safari, notes])).0 == .stayApp, "つみきショットの範囲選びの幕が出ているあいだは止まる（既定の除外）")
        b = fresh(0); b.excluded.remove("com.tsumiki.shot")
        check(b.step(snap(0, windows: [shotVeil, menuBar, safari, notes])).0 == .overlay, "除外から外しても、幕の上では動かない（浮いた窓）")
        // 除外アプリの窓には乗っても出さない
        b = fresh(0); b.excluded.insert("com.apple.Notes")
        check(b.step(snap(0)).0 == .excluded, "除外アプリの窓は出さない")
        // 自分の窓
        let own = Win(id: 10, pid: 99, layer: 0, bounds: CGRect(x: 900, y: 300, width: 200, height: 200), alpha: 1)
        b = fresh(0)
        check(b.step(snap(0, windows: [menuBar, own, safari, notes])).0 == .ownApp, "自分の窓は出さない")
        // 透明な窓は通り抜ける
        let ghost = Win(id: 11, pid: 40, layer: 0, bounds: CGRect(x: 900, y: 300, width: 200, height: 200), alpha: 0)
        check(b.step(snap(0, windows: [menuBar, ghost, safari, notes])).0 == .raise, "透明な窓は通り抜けて下の窓を出す")
        // デスクトップの切り替え
        b = fresh(0)
        b.spaceChanged(now: 0, mouse: p)
        check(b.step(snap(0.1)).0 == .spaceChanged, "切り替えた直後は止まる")
        check(b.step(snap(0.2, mouse: CGPoint(x: 1050, y: 450))).0 == .spaceChanged, "切り替えて0.4秒以内は、動かしても止まる")
        check(b.step(snap(1.0)).0 == .spaceChanged, "切り替えたあと、カーソルを動かすまでは止まる")
        check(b.step(snap(1.1, mouse: CGPoint(x: 1010, y: 410))).0 == .raise, "動かしたら戻る")
        // 休む
        b = fresh(0); b.pausedUntil = 100
        check(b.step(snap(50)).0 == .paused, "休み中は止まる")
        check(b.step(snap(101)).0 == .raise, "休みが明けたら戻る")
        b.pausedUntil = .infinity
        check(b.step(snap(1e9)).0 == .paused, "オフはずっと止まる")
        // 窓がない（デスクトップ）＝何もしない（Finder を前に出さない。Finder の窓が別のデスクトップにあると、そこへ切り替わるため）
        let desk = CGPoint(x: 1400, y: 850)
        b = fresh(0)
        var deskWhys: [Why] = []
        for i in 0..<5 { let r = b.step(snap(Double(i) * 0.3, front: 10, mouse: CGPoint(x: desk.x + Double(i), y: desk.y))); deskWhys.append(r.0); if r.1 != nil { deskWhys.append(.raise) } }
        check(deskWhys.allSatisfy { $0 == .noWindow }, "S1：デスクトップの上では何も前に出さない（Finder も）（\(deskWhys.map(\.rawValue))）")
        b = fresh(0)
        check(b.step(snap(0, front: 90, mouse: desk)).0 == .noWindow, "S1：Finder が前でも、デスクトップの上では何もしない（クリックも送らない）")
        // デスクトップから窓へ戻れば、ふだんどおり出す
        check(b.step(snap(0.3, front: 90)).0 == .raise, "S1：デスクトップから窓の上へ戻ったら、その窓を出す")

        // Mission Control・Launchpad・App Exposé（Dock が画面を覆う窓を出している）＝何もしない
        let dockStrip = Win(id: 60, pid: 60, layer: 20, bounds: CGRect(x: 200, y: 830, width: 1000, height: 70), alpha: 1)
        let mcOverlay = Win(id: 61, pid: 60, layer: 20, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 1)
        func msnap(_ t: TimeInterval, _ wins: [Win], mouse: CGPoint? = nil) -> Snapshot { var x = snap(t, windows: wins, mouse: mouse); x.dockPid = 60; return x }
        b = fresh(0)
        check(b.step(msnap(0, [mcOverlay, menuBar, safari, notes])).0 == .missionControl, "S2：Mission Control の最中は何もしない")
        check(b.step(msnap(0.1, [mcOverlay, menuBar, safari, notes], mouse: CGPoint(x: 1100, y: 500))).0 == .missionControl, "S2：Mission Control の中でカーソルを動かしても何もしない")
        // 下の窓が先に並んでいても（並びの順に頼らない）
        b = fresh(0)
        check(b.step(msnap(0, [menuBar, safari, notes, mcOverlay])).0 == .missionControl, "S2：Dock の大きな窓が一覧のどこにあっても止まる")
        // 閉じたら、カーソルを動かすまで待つ（閉じた瞬間の位置の窓を勝手に出さない）
        b = fresh(0)
        _ = b.step(msnap(0, [mcOverlay, menuBar, safari, notes]))
        check(b.step(msnap(0.5, [menuBar, safari, notes])).0 == .spaceChanged, "S2：Mission Control を閉じた直後、カーソルが同じ所なら何もしない")
        check(b.step(msnap(0.6, [menuBar, safari, notes], mouse: CGPoint(x: 1010, y: 410))).0 == .raise, "S2：閉じたあとカーソルを動かしたら、ふだんどおり")
        // 止まったままの見直し：Mission Control の最中は止め続け、閉じても動かすまでは出さない
        b = fresh(0)
        _ = b.step(msnap(0, [mcOverlay, menuBar, safari, notes]))
        check(b.recheck(msnap(0.3, [mcOverlay, menuBar, safari, notes]))?.0 == .missionControl, "S2：止まったままの見直しでも、最中は何もしない")
        check(b.recheck(msnap(0.6, [menuBar, safari, notes]))?.0 == .spaceChanged, "S2：止まったままの見直しで閉じたのに気づいても、出さない")
        // いつもの Dock（細長い帯）は Mission Control と見なさない
        b = fresh(0)
        check(b.step(msnap(0, [dockStrip, menuBar, safari, notes])).0 == .raise, "S2：いつもの Dock の帯があっても、窓の上ならふだんどおり")
        let sideDock = Win(id: 62, pid: 60, layer: 20, bounds: CGRect(x: 0, y: 100, width: 80, height: 700), alpha: 1)
        check(Brain.missionControlShown(msnap(0, [sideDock, safari])) == false, "S2：横に置いた Dock（縦長の帯）も Mission Control と見なさない")
        check(Brain.missionControlShown(snap(0, windows: [mcOverlay, safari])) == false, "S2：Dock が分からないときは止めない（ほかのアプリの大きな窓で止まらない）")

        // S4：画面を覆う浮いた窓（通知センター）が素通しなら、下の窓を見る
        let ncOverlay = Win(id: 70, pid: 77, layer: 23, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 1)
        func nsnap(_ t: TimeInterval, owner: pid_t?, mouse: CGPoint? = nil, calls: UnsafeMutablePointer<Int>? = nil) -> Snapshot {
            var x = snap(t, windows: [ncOverlay, menuBar, safari, notes], mouse: mouse); x.axOwnerAt = { _ in calls?.pointee += 1; return owner }; return x
        }
        b = fresh(0)
        let nr = b.step(nsnap(0, owner: 20))
        check(nr.0 == .raise && nr.1?.id == 2, "S4：通知センターの全画面の窓が素通しなら、その下のメモを出す（\(nr.0.rawValue)）")
        b = fresh(0)
        check(b.step(nsnap(0, owner: 77)).0 == .overlay, "S4：通知そのものの上（持ち主が通知センター）なら何もしない")
        b = fresh(0)
        check(b.step(nsnap(0, owner: nil)).0 == .overlay, "S4：当たり判定が読めなければ、手前の窓を信じて何もしない")
        b = fresh(0)
        let ncCalls = UnsafeMutablePointer<Int>.allocate(capacity: 1); ncCalls.pointee = 0
        var sm = snap(0); sm.axOwnerAt = { _ in ncCalls.pointee += 1; return 20 }
        _ = b.step(sm)
        check(ncCalls.pointee == 0, "S4：大きな浮いた窓が無ければ、当たり判定は読まない（軽く）")
        _ = b.step(nsnap(0.1, owner: 20, calls: ncCalls))
        check(ncCalls.pointee == 1, "S4：当たり判定を読むのは1回の判断で1回だけ")
        ncCalls.deallocate()
        let shotOverlay = Win(id: 71, pid: 50, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 1)
        var ss = snap(0, windows: [shotOverlay, menuBar, safari, notes]); ss.axOwnerAt = { _ in 50 }
        b = fresh(0)
        let sr = b.step(ss).0
        check(sr == .stayApp || sr == .overlay, "S4：つみきショットの範囲選び（マウスを受けている）では何もしない")

        let lockOverlay = Win(id: 72, pid: 81, layer: 2000, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), alpha: 1)
        var ls = snap(0, windows: [lockOverlay, menuBar, safari, notes]); ls.axOwnerAt = { _ in 81 }
        b = fresh(0)
        check(b.step(ls).0 == .overlay, "S4：除外していない幕（つみきロックなど）がマウスを受けているなら、下の窓を出さない")
        // S5：見送り（デスクトップを切り替えないため）は許可の失敗と数えず、出し直しは 8 秒あける
        b = fresh(0)
        _ = b.step(snap(0)); b.reportRaise(id: 2, ok: true, skipped: true)
        check(!b.needsAttention, "S5：見送りは許可の失敗と数えない")
        check(b.step(snap(5)).0 == .cooling, "S5：見送った窓は 5 秒たっても出し直さない")
        check(b.step(snap(8.1)).0 == .raise, "S5：8 秒たったら出し直す")
        for _ in 0..<3 { b.reportRaise(id: 2, ok: true, skipped: true) }
        check(!b.needsAttention, "S5：見送りが続いても点は付けない")

        // S3：前に出す直前の確かめ（アプリのメインの窓が別のデスクトップにあるなら最前面にしない）
        let target = AXUIElementCreateApplication(101), other = AXUIElementCreateApplication(102)
        check(Raiser.mainIsOK(nil, target, onThisSpace: { _ in false }), "S3：メインの窓が無いなら、最前面にしてよい")
        check(Raiser.mainIsOK(target, target, onThisSpace: { _ in false }), "S3：乗せた窓がメインになったら、最前面にしてよい")
        check(!Raiser.mainIsOK(other, target, onThisSpace: { _ in false }), "S3：メインの窓が別のデスクトップにあるなら、最前面にしない（デスクトップを切り替えない）")
        check(Raiser.mainIsOK(other, target, onThisSpace: { _ in true }), "S3：メインの窓がいまのデスクトップにあるなら、最前面にしてよい")
        let cr = CGRect(x: 0, y: 25, width: 1440, height: 875)
        check(Raiser.onlyHere(frame: cr, among: [(cr, true)]), "S3：同じ枠の窓がいまのデスクトップの1枚だけなら、ここの窓とみなす")
        check(!Raiser.onlyHere(frame: cr, among: [(cr, true), (cr, false)]), "S3：別のデスクトップにも同じ枠の窓（最大化した窓など）があれば、見分けられないので最前面にしない")
        check(!Raiser.onlyHere(frame: cr, among: [(cr, false)]), "S3：その枠の窓が別のデスクトップにしかなければ、最前面にしない")
        check(Raiser.mainIsOK("文字" as CFString, target, onThisSpace: { _ in false }), "S3：窓でない値が返っても落ちない")
        let t0 = Date()
        _ = Raiser.mainSettles(app: AXUIElementCreateApplication(103), to: target, timeout: 0.05, onThisSpace: { _ in false })
        check(Date().timeIntervalSince(t0) < 0.2, "S3：メインの窓を待つのは長くても0.1秒ほど（止まったままにならない）")

        // W4：カーソルが止まったままの見直し
        b = fresh(0)
        _ = b.step(snap(0, control: true))
        let rc = b.recheck(snap(0.3))
        check(rc?.0 == .raise, "W4：止めていた理由（control）が消えたら、止まったままでも判断し直す")
        b = fresh(0)
        _ = b.step(snap(0, windows: [menu, menuBar, safari, notes]))
        check(b.recheck(snap(0.3, windows: [menuBar, safari, notes], front: 20)) == nil, "W4：止めているあいだにユーザーが別のアプリを前にしたら、勝手に戻さない")
        b = fresh(0)
        _ = b.step(snap(0, windows: [menu, menuBar, safari, notes]))
        check(b.recheck(snap(0.3)) != nil, "W4：メニューが閉じ、前の窓がそのままなら判断し直す")
        b = fresh(0)
        _ = b.step(snap(0, windows: [menuBar, notes, safari], front: 20))   // メモが前（もう前にいる）
        check(b.recheck(snap(0.3, windows: [menuBar, notes, safari], front: 20)) == nil, "W4：何も変わらなければ何もしない")
        check(b.recheck(snap(0.6, windows: [menuBar, notes, safari], front: 10)) == nil, "W4：Cmd+Tab などで自分で前を変えただけなら（前の窓は残っている）何もしない")
        b = fresh(0)
        _ = b.step(snap(0, windows: [menuBar, safari, notes], front: 10, mouse: CGPoint(x: 100, y: 100)))   // Safari が前＆カーソルも Safari
        let closedRc = b.recheck(snap(0.3, windows: [menuBar, notes], front: 20, mouse: CGPoint(x: 1000, y: 400)))
        check(closedRc == nil || closedRc?.0 == .alreadyFront, "W4：前の窓が閉じても、いまの前の窓の上ならそのまま")
        b = fresh(0)
        _ = b.step(snap(0, windows: [menuBar, safari, notes], front: 10, mouse: CGPoint(x: 100, y: 100)))
        let third2 = Win(id: 13, pid: 80, layer: 0, bounds: CGRect(x: 900, y: 300, width: 200, height: 200), alpha: 1)
        let closedRc2 = b.recheck(snap(0.3, windows: [menuBar, third2, notes], front: 20, mouse: CGPoint(x: 100, y: 100)))
        check(closedRc2 != nil, "W4：前の窓が閉じたら（カーソル下の窓が前でなくなったとき）判断し直す")

        // W2：出せなかった窓の連続失敗を数える（同じ窓で3回）／成功で戻る
        b = fresh(0)
        b.reportRaise(id: 2, ok: false); b.reportRaise(id: 2, ok: false)
        check(!b.needsAttention, "W2：2回の失敗ではまだ知らせない")
        b.reportRaise(id: 2, ok: false)
        check(b.needsAttention, "W2：同じ窓で3回続けて失敗したら知らせる")
        b.reportRaise(id: 2, ok: true)
        check(!b.needsAttention, "W2：成功したら戻る")
        b.reportRaise(id: 2, ok: false); b.reportRaise(id: 5, ok: false); b.reportRaise(id: 2, ok: false); b.reportRaise(id: 5, ok: false)
        check(!b.needsAttention, "W2：別々の窓の失敗は合算しない")

        // アイコン
        check(AppIcon.png(64).count > 500, "アプリのアイコンが描ける")
        check(AppIcon.menuImage(active: true).isTemplate, "メニューバーの絵はテンプレート")
        check(AppIcon.menuImage(active: true, warn: true).isTemplate, "W2：知らせの点つきの絵もテンプレート")
        print(ng == 0 ? "OK" : "NG \(ng)")
        return ng == 0 ? 0 : 1
    }
}
