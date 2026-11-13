// `--selftest`：許可なしで確かめられる決まりごと（build.sh が毎回通す）。
// `--e2e <結果.txt>`：アクセシビリティを許可したアプリの中で、本物の口に作り物の入力を流し、捨てられたかを数える。
//   流すのは無害なもの（F19・キーボードの明かり切り替え・10番ボタン・その場の移動）。15秒で必ず終わる。
import AppKit
import ApplicationServices

enum SelfTest {
    static var fails = 0
    static var lines: [String] = []
    static func check(_ ok: Bool, _ name: String) {
        let l = (ok ? "✓ " : "✗ ") + name
        print(l); lines.append(l)
        if !ok { fails += 1 }
    }

    static func run() -> Bool {
        // 止める種類
        let m = Core.mask
        for (t, n) in [(10, "キーを押す"), (11, "キーを離す"), (12, "修飾キー"), (14, "メディアキー"),
                       (1, "左クリック"), (3, "右クリック"), (5, "移動"), (6, "ドラッグ"), (22, "スクロール"),
                       (25, "ほかのボタン"), (29, "手の動き"), (31, "スワイプ"), (30, "拡大"), (18, "回転"), (34, "強く押す")] {
            check(m & (CGEventMask(1) << CGEventMask(t)) != 0, "口が \(n)（\(t)）を受け取る")
        }
        check(m & 1 == 0, "口は「空の入力（0）」を受け取らない")
        check(Set(Core.allTypes).count == Core.allTypes.count, "種類に重なりがない")
        check(Core.downTypes.isSubset(of: Set(Core.pointerTypes)) && Core.upTypes.isSubset(of: Set(Core.pointerTypes)),
              "押し続けの判定に使う種類も止めている")

        // 時間
        check(Core.clamp(0) == 120 && Core.clamp(-5) == 120, "時間が無い・負なら既定の2分")
        check(Core.clamp(99999) == 600, "時間は10分を超えない")
        check(Core.clamp(60) == 60, "1分はそのまま")
        check(Core.durations.allSatisfy { Core.clamp($0) == $0 }, "選択肢はすべて上限の内")
        check(Core.mmss(120) == "2:00" && Core.mmss(4.2) == "0:05" && Core.mmss(-1) == "0:00" && Core.mmss(600) == "10:00", "残り時間の表示")

        // 押し続け
        var h = Hold()
        check(h.progress(5) == 0 && !h.done(5), "押していなければ解除しない")
        h.down(10)
        check(abs(h.progress(11.5) - 0.5) < 1e-9, "1.5秒で半分")
        h.down(11, 1)
        check(h.since == 10, "押したまま別のボタンを押しても数え直さない")
        check(!h.done(12.9) && h.done(13.0), "3秒で解除")
        h.up(0)
        check(h.since == 10, "片方を離しても、もう片方を押していれば続く")
        h.up(1)
        check(h.progress(20) == 0, "全部離したら数えを捨てる")

        // 口の働き（本物の口は作らず、1件ごとの扱いだけ）
        let b = Blocker()
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 0x50, keyDown: true)!
        check(b.handle(.keyDown, key) == nil, "キーは捨てる")
        check(b.handle(.otherMouseDown, key) == nil && b.hold.since != nil, "ボタンを押すと捨てて数え始める")
        check(b.handle(.otherMouseUp, key) == nil && b.hold.since == nil, "離すと捨てて数えを捨てる")
        check(b.handle(.tapDisabledByTimeout, key) != nil, "口を止められた知らせは通す（開け直す）")
        check(!b.isOn, "口を作っていなければ止めていない")

        // 自動で始めるか
        check(Core.shouldAutoStart(pref: true, loginLaunch: false), "開いたら始める")
        check(!Core.shouldAutoStart(pref: true, loginLaunch: true), "ログイン時に開かれたら始めない")
        check(!Core.shouldAutoStart(pref: false, loginLaunch: false), "設定を切れば始めない")
        check(!Core.shouldAutoStart(pref: true, loginLaunch: false, uptime: 60), "Mac の起動直後（3分以内）は始めない")
        check(Core.shouldAutoStart(pref: true, loginLaunch: false, uptime: 200), "起動から3分たてば始める")

        // 見張り
        let fired = DispatchSemaphore(value: 0)
        var count = 0
        let w = Watchdog { count += 1; fired.signal() }
        w.arm(after: 0.2)
        check(fired.wait(timeout: .now() + 2) == .success && count == 1, "見張りは時間が来たら発火する")
        let w2 = Watchdog { count += 1; fired.signal() }
        w2.arm(after: 0.2); w2.disarm()
        check(fired.wait(timeout: .now() + 0.6) == .timedOut, "解除したら見張りは発火しない")
        let w3 = Watchdog { count += 1; fired.signal() }
        w3.arm(after: 0.2); w3.arm(after: 0.5)
        _ = fired.wait(timeout: .now() + 1.2)
        check(fired.wait(timeout: .now() + 0.3) == .timedOut && count == 2, "掛け直したら古い見張りは発火しない")

        // 絵
        check(AppIcon.png(64).count > 200, "アイコンを描ける")
        check(AppIcon.menuImage().size == NSSize(width: 18, height: 18), "メニューバーの絵は18pt")
        check(CurtainLook.png(400, 300, remain: 90, hold: 0.4).count > 500, "幕を描ける")

        print(fails == 0 ? "自己テスト OK" : "自己テスト ✗ \(fails)件")
        return fails == 0
    }

    /// 本物の口で確かめる（許可が要る）。結果はファイルにも書く
    static func e2e(out: String) -> Bool {
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        let guardDog = Watchdog { try? "✗ 15秒で終わらなかった\n".write(toFile: out, atomically: true, encoding: .utf8); exit(3) }
        guardDog.arm(after: 15)
        guard AXIsProcessTrusted() else {
            // 許可の一覧に載せる（macOS の確認が出る）。入りは本人が「アクセシビリティ」で入れる
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            check(false, "アクセシビリティの許可がない"); return false
        }
        let b = Blocker()
        guard b.start() else { check(false, "口を作れない"); return false }
        check(b.isOn, "口が開いた")
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let pos = CGEvent(source: nil)?.location ?? .zero
        func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); spin(0.15) }
        func media(_ down: Bool) -> CGEvent? {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: (23 << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)?.cgEvent
        }
        post(CGEvent(keyboardEventSource: nil, virtualKey: 0x50, keyDown: true))
        post(CGEvent(keyboardEventSource: nil, virtualKey: 0x50, keyDown: false))
        post(media(true)); post(media(false))
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left))
        post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        let btn = CGMouseButton(rawValue: 10)!
        post(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: pos, mouseButton: btn))
        spin(3.2)
        check(b.hold.done(ProcessInfo.processInfo.systemUptime), "ボタンを3秒押し続けると解除の条件がそろう")
        post(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: pos, mouseButton: btn))
        let d = b.dropped
        check(d[10] == 1 && d[11] == 1, "キー（F19）を捨てた")
        check(d[14] == 2, "メディアキーを捨てた")
        check(d[5] == 1, "移動を捨てた")
        check(d[22] == 1, "スクロールを捨てた")
        check(d[25] == 1 && d[26] == 1, "ボタンを捨てた")
        b.stop()
        check(!b.isOn && b.tap == nil, "解除したら口が閉じた")
        print(fails == 0 ? "e2e OK" : "e2e ✗ \(fails)件")
        return fails == 0
    }
}
