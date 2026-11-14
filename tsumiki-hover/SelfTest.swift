// `--selftest`：判断（Brain）に架空の画面の様子を流して確かめる。許可は要らない・画面には触らない。
// 困りやすい場面（メニュー・ドラッグ・Alfred/Paste・つみきショットの範囲選び・デスクトップの切り替え）を1つずつ
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
        check(b.step(snap(1.2)).0 == .raise, "1秒たったら出し直す")
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
        check(b.step(snap(0, windows: [menu, menuBar, safari, notes])).0 == .menuOpen, "メニューを開いているあいだは止まる（カーソルがメニューの外でも）")
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
        // 窓がない（デスクトップ）
        b = fresh(0)
        check(b.step(snap(0, mouse: CGPoint(x: 1400, y: 850))).0 == .noWindow, "Finder が分からないときはデスクトップの上で何もしない")
        // デスクトップ（窓と窓のあいだ）＝Finder を前に
        let desk = CGPoint(x: 1400, y: 850)
        func dsnap(_ t: TimeInterval, front: pid_t = 10) -> Snapshot { var x = snap(t, front: front, mouse: desk); x.finderPid = 90; return x }
        b = fresh(0.05)
        check(b.step(dsnap(0)).0 == .waiting, "デスクトップ：乗せた直後は待つ")
        let dr = b.step(dsnap(0.05))
        check(dr.0 == .desktop && dr.1?.pid == 90, "デスクトップ：待ち時間のあと Finder を前に")
        check(b.step(dsnap(0.3, front: 90)).0 == .alreadyFront, "デスクトップ：Finder が前ならそのまま")
        b = fresh(0); b.excluded.insert("com.apple.finder")
        check(b.step(dsnap(0)).0 == .noWindow, "デスクトップ：Finder を除外していたら何もしない")
        b = fresh(0.12); b.restDelay = 0.03
        _ = b.step(dsnap(0)); check(b.step(dsnap(0.04)).0 == .desktop, "デスクトップ：止めたら感度どおりすぐ")

        // アイコン
        check(AppIcon.png(64).count > 500, "アプリのアイコンが描ける")
        check(AppIcon.menuImage(active: true).isTemplate, "メニューバーの絵はテンプレート")
        print(ng == 0 ? "OK" : "NG \(ng)")
        return ng == 0 ? 0 : 1
    }
}
