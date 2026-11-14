// `--selftest`：キーの設定・止める・Mac 標準のキーとの重なりを確かめる。
// 本物の設定（UserDefaults・com.apple.symbolichotkeys）は触らず、別の名前の置き場で試す。
import AppKit
import Carbon

enum SelfTest {
    static var ok = true
    static func check(_ name: String, _ cond: Bool, _ note: String = "") {
        print((cond ? "✓ " : "✗ ") + name + (note.isEmpty ? "" : "（\(note)）"))
        if !cond { ok = false }
    }

    /// Carbon のホットキーを受けるあいだ、アプリのイベントを回す
    static func pump(_ sec: Double) {
        let end = Date().addingTimeInterval(sec)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
        }
    }

    static func run() -> Bool {
        let suite = "tsumikisnap.selftest"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        Shortcuts.defaults = ud
        SystemKeys.domain = "tsumikisnap.selftest.symbolichotkeys" as CFString
        SystemKeys.applyNow = false
        HotKeys.signature = OSType(0x6D647374)   // 'mdst'（本物のつみきスナップと分ける）
        func fake(_ t: [String: Any]?) {
            CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, t as CFDictionary?, SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        func on(_ id: String) -> Bool { SystemKeys.isEnabled(id, SystemKeys.table()) }
        defer {
            fake(nil)
            ud.removePersistentDomain(forName: suite)
            HotKeys.suspend()
            removeFiles([suite, SystemKeys.domain as String])
        }
        let ctrl = UInt32(controlKey)
        let ctrlLeft = KeyCombo(code: UInt32(kVK_LeftArrow), mods: ctrl, char: "←")
        let ctrlRight = KeyCombo(code: UInt32(kVK_RightArrow), mods: ctrl, char: "→")

        // 1. 既定のキー
        let defs = Shortcuts.sides.map { Shortcuts.combo($0)?.display ?? "-" }
        check("既定は ⌥⌘← ⌥⌘↑ ⌥⌘→ ⌃⌥↩ ⌃⌥C ⌃⌥U ⌃⌥I ⌃⌥J ⌃⌥K",
              defs == ["⌥⌘←", "⌥⌘↑", "⌥⌘→", "⌃⌥↩", "⌃⌥C", "⌃⌥U", "⌃⌥I", "⌃⌥J", "⌃⌥K"], defs.joined(separator: " "))
        check("既定のキーに重複がない", Set(Shortcuts.sides.map { $0.def.display }).count == Shortcuts.sides.count)
        check("全部の項目にアイコンがある", Shortcuts.sides.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil },
              Shortcuts.sides.filter { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) == nil }.map { $0.symbol }.joined(separator: ","))

        // 1b. 寄せ先の計算（Cocoa 座標・左下が原点）。メニューバーと Dock を除いた領域 vf
        let vf = NSRect(x: 0, y: 70, width: 1440, height: 801)       // 高さが奇数でも切り捨て
        func eq(_ r: NSRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Bool { r == NSRect(x: x, y: y, width: w, height: h) }
        check("最大化は visibleFrame いっぱい", eq(Side.maximize.target(in: vf), 0, 70, 1440, 801))
        check("左上", eq(Side.topLeft.target(in: vf), 0, 871 - 400, 720, 400))
        check("右上", eq(Side.topRight.target(in: vf), 720, 871 - 400, 720, 400))
        check("左下", eq(Side.bottomLeft.target(in: vf), 0, 70, 720, 400))
        check("右下", eq(Side.bottomRight.target(in: vf), 720, 70, 720, 400))
        check("左・右・上は今までどおり", eq(Side.left.target(in: vf), 0, 70, 720, 801) && eq(Side.right.target(in: vf), 720, 70, 720, 801) && eq(Side.top.target(in: vf), 0, 471, 1440, 400))
        check("中央は大きさを変えない", eq(Side.center.target(in: vf, size: CGSize(width: 800, height: 600)), 320, 70 + 100, 800, 600))
        check("中央：奇数の余りは切り捨て", eq(Side.center.target(in: vf, size: CGSize(width: 801, height: 601)), 319, 170, 801, 601))
        check("中央：画面より大きいときは画面に収める", eq(Side.center.target(in: vf, size: CGSize(width: 2000, height: 1000)), 0, 70, 1440, 801))
        // 2つ目の画面（左にある・位置が負、Dock なし）でも、その画面の vf で計算される
        let vf2 = NSRect(x: -1920, y: 100, width: 1920, height: 1055)
        check("別の画面の左上・右下", eq(Side.topLeft.target(in: vf2), -1920, 1155 - 527, 960, 527) && eq(Side.bottomRight.target(in: vf2), -960, 100, 960, 527))
        check("別の画面の中央", eq(Side.center.target(in: vf2, size: CGSize(width: 1000, height: 700)), -1460, 100 + 177, 1000, 700))
        check("四隅は寄せる端の指定が合う", Side.topLeft.anchorsLeft && !Side.topLeft.anchorsBottom && Side.bottomRight.anchorsRight && Side.bottomRight.anchorsBottom && !Side.maximize.anchorsLeft)
        check("既定は Mac 標準と重ならない", SystemKeys.clashesNow().isEmpty)

        // 2. 変える・同じキーは片方だけ
        Shortcuts.set(.left, ctrlLeft)
        check("左を ⌃← に変えられる", Shortcuts.combo(.left) == ctrlLeft)
        Shortcuts.set(.top, ctrlLeft)
        check("同じキーを上に付けると左は「なし」", Shortcuts.combo(.left) == nil && Shortcuts.combo(.top) == ctrlLeft)
        Shortcuts.set(.top, nil)
        check("delete で「なし」", Shortcuts.combo(.top) == nil)
        Shortcuts.resetAll()
        check("すべて既定に戻す", Shortcuts.combo(.left) == Side.left.def && Shortcuts.combo(.top) == Side.top.def)
        Shortcuts.set(.maximize, Side.center.def)
        check("同じキーを最大化に付けると中央は「なし」", Shortcuts.combo(.center) == nil && Shortcuts.combo(.maximize) == Side.center.def)
        Shortcuts.resetAll()

        // 3. Mac 標準との重なり（置き場が空＝Mac の既定のまま）
        fake(nil)
        Shortcuts.set(.left, ctrlLeft)
        check("⌃← は「左の操作スペースに移動」と重なる", SystemKeys.clashing(ctrlLeft) == ["79"], SystemKeys.clashing(ctrlLeft).joined(separator: ","))
        // システム設定でキーを変えていれば、そちらを読む（79 を ⌃⌥← に変えた人）
        fake(["79": ["enabled": true, "value": ["parameters": [65535, 123, 0x8C0000], "type": "standard"]]])
        check("Mac 側で変えたキーを読む", SystemKeys.clashing(ctrlLeft).isEmpty &&
              SystemKeys.clashing(KeyCombo(code: UInt32(kVK_LeftArrow), mods: ctrl | UInt32(optionKey), char: "←")) == ["79"])

        // 4. 止める → 重なったものだけ止まる・ほかは触らない
        fake(["81": ["enabled": false, "value": ["parameters": [65535, 124, 0x840000], "type": "standard"]]])   // 元から止めていた
        SystemKeys.wantStop = true
        SystemKeys.sync()
        check("止める：⌃← の 79 だけ止まる", !on("79") && on("32") && on("33") && SystemKeys.stopped == ["79"],
              "stopped=\(SystemKeys.stopped)")
        check("止めたあとは重ならない", SystemKeys.clashesNow().isEmpty)

        // 5. キーを変えたら合わせ直す：⌃→ に変える → 79 は戻り、81 は元から止めていたので触らない（止めた記録にも入れない）
        Shortcuts.set(.left, ctrlRight)
        SystemKeys.sync()
        check("キーを変えると前に止めたものは戻る", on("79"))
        check("元から止めていたものは記録しない", !on("81") && SystemKeys.stopped.isEmpty, "stopped=\(SystemKeys.stopped)")

        // 6. スイッチをオフ：つみきスナップが止めたものだけ戻す
        Shortcuts.set(.left, ctrlLeft)
        SystemKeys.sync()
        check("また ⌃← にすると 79 が止まる", !on("79") && SystemKeys.stopped == ["79"])
        SystemKeys.wantStop = false
        SystemKeys.sync()
        check("オフで 79 は戻り、81 は止めたまま", on("79") && !on("81") && SystemKeys.stopped.isEmpty)
        check("オフのあとは重なりが見える", SystemKeys.clashesNow().first?.0 == .left)

        // 6b. 一時停止のあいだは Mac 標準に戻し、外すとまた止める
        SystemKeys.wantStop = true
        SystemKeys.sync()
        Shortcuts.paused = true; SystemKeys.sync()
        check("一時停止のあいだは Mac 標準に戻す", on("79") && SystemKeys.stopped.isEmpty)
        Shortcuts.paused = false; SystemKeys.sync()
        check("一時停止を外すとまた止める", !on("79") && SystemKeys.stopped == ["79"])

        // 6c. 終了するときは全部戻す（スイッチはオンのまま＝次に起動したらまた止める）
        SystemKeys.releaseAll()
        check("終了するとき止めたものを戻す", on("79") && !on("81") && SystemKeys.stopped.isEmpty && SystemKeys.wantStop)
        SystemKeys.sync()
        check("次に起動したらまた止める", !on("79") && SystemKeys.stopped == ["79"])
        SystemKeys.wantStop = false; SystemKeys.sync()

        // 7. 一時停止
        Shortcuts.resetAll()
        let f12 = KeyCombo(code: UInt32(kVK_F12), mods: UInt32(cmdKey | optionKey | controlKey), char: "F12")
        Shortcuts.set(.left, f12)          // 押しても害のないキーで試す
        for o in Shortcuts.sides where o != .left { Shortcuts.set(o, nil) }
        HotKeys.apply()
        check("止めていないときは登録される", HotKeys.registered == 1 && HotKeys.failed.isEmpty, "registered=\(HotKeys.registered)")
        Shortcuts.paused = true
        HotKeys.apply()
        check("一時停止で全部外れる", HotKeys.registered == 0)

        // 8. 本当にキーで呼ばれるか（⌃⌥⌘F12 を送る）。送る許可がない環境では「未確認」と出す
        var got: [Side] = []
        HotKeys.onPress = { got.append($0) }
        func press() {
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F12), keyDown: down)
                e?.flags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
                e?.post(tap: .cghidEventTap)
            }
            pump(0.6)
        }
        if AXIsProcessTrusted() {
            press()
            check("止めているあいだは押しても呼ばれない", got.isEmpty)
            Shortcuts.paused = false
            HotKeys.apply()
            press()
            check("止めるを外すと押して呼ばれる", got == [.left], "got=\(got.map { $0.name })")
        } else {
            print("– 本物のキーを送る確認は未確認（このテストを動かしているアプリにキーを送る許可がない）")
        }
        return ok
    }

    /// `--settings-png <出力>`：設定の窓を画像にする（架空の置き場で。左を ⌃← にして重なりを見せる）
    static func settingsPNG(_ out: String) {
        let suite = "tsumikisnap.shot"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        Shortcuts.defaults = ud
        SystemKeys.domain = "tsumikisnap.shot.symbolichotkeys" as CFString
        SystemKeys.applyNow = false
        HotKeys.signature = OSType(0x6D647374)
        Shortcuts.set(.left, KeyCombo(code: UInt32(kVK_LeftArrow), mods: UInt32(controlKey), char: "←"))
        let w = SettingsWindow()
        w.refresh()
        let v = w.window!.contentView!
        v.appearance = NSAppearance(named: .aqua)
        v.layoutSubtreeIfNeeded()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        ud.removePersistentDomain(forName: suite)
        HotKeys.suspend()
        removeFiles([suite, SystemKeys.domain as String])
    }

    /// 試しの置き場のファイルを残さない
    static func removeFiles(_ names: [String]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for n in names { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n + ".plist")) }
    }
}
