// ショートカットの設定（好きなキーに変えられる・止められる）と、Mac 標準のキーとの重なり、設定の窓。
// つみきショットの Shortcuts.swift と同じ作り。保存は UserDefaults の "hotkeys"（番号 → キー）。
// 書いていない番号は既定のキー、空のデータは「なし」。
import AppKit
import Carbon

let accent = NSColor(srgbRed: 0xd5 / 255.0, green: 0x9a / 255.0, blue: 0x4d / 255.0, alpha: 1)

/// 1つのキーの組み合わせ（Carbon の修飾キー＋キー番号）
struct KeyCombo: Codable, Equatable {
    var code: UInt32
    var mods: UInt32          // cmdKey / optionKey / controlKey / shiftKey の組み合わせ
    var char: String          // 表示用（「←」「S」「F5」など）

    static let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                       kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
    static let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                       kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"]

    func same(_ o: KeyCombo) -> Bool { code == o.code && mods == o.mods }

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + char
    }

    /// メニューの項目に出すキー（AppKit の書き方）
    var menuKey: (String, NSEvent.ModifierFlags) {
        var f: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { f.insert(.control) }
        if mods & UInt32(optionKey) != 0 { f.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { f.insert(.command) }
        let c = Int(code)
        let special: [Int: Int] = [kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
                                   kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
                                   kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
                                   kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                                   kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
                                   kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
                                   kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey]
        if let u = special[c], let sc = UnicodeScalar(u) { return (String(Character(sc)), f) }
        if c == kVK_Space { return (" ", f) }
        if c == kVK_Return { return ("\r", f) }
        if c == kVK_Tab { return ("\t", f) }
        return (char.lowercased(), f)
    }

    /// 押されたキーから作る。⌘・⌃・⌥ のどれかが要る（F キーだけは単独でもよい）
    static func from(code: UInt16, flags: NSEvent.ModifierFlags, chars: String?) -> KeyCombo? {
        let f = flags.intersection([.command, .option, .control, .shift])
        let c = Int(code)
        let isF = fKeys[c] != nil
        guard isF || !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        let name = fKeys[c] ?? named[c] ?? (chars ?? "").uppercased()
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return KeyCombo(code: UInt32(code), mods: m, char: name)
    }
}

extension Side {
    var def: KeyCombo {
        let m = UInt32(cmdKey | optionKey)
        switch self {
        case .left: return KeyCombo(code: UInt32(kVK_LeftArrow), mods: m, char: "←")
        case .top: return KeyCombo(code: UInt32(kVK_UpArrow), mods: m, char: "↑")
        case .right: return KeyCombo(code: UInt32(kVK_RightArrow), mods: m, char: "→")
        }
    }
    var name: String {
        switch self { case .left: return "左"; case .top: return "上"; case .right: return "右" }
    }
    var symbol: String {
        switch self {
        case .left: return "rectangle.lefthalf.filled"
        case .top: return "rectangle.tophalf.filled"
        case .right: return "rectangle.righthalf.filled"
        }
    }
}

enum Shortcuts {
    static let sides: [Side] = [.left, .top, .right]
    static var defaults: UserDefaults = .standard
    private static let key = "hotkeys"

    private static var stored: [String: Data] { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }

    /// いまのキー（nil＝なし）
    static func combo(_ s: Side) -> KeyCombo? {
        guard let d = stored[String(s.rawValue)] else {
            // 既定のキーが、別の項目に保存されたキーと同じなら「なし」
            let taken = stored.contains { k, v in k != String(s.rawValue) && (try? JSONDecoder().decode(KeyCombo.self, from: v)).map { $0.same(s.def) } == true }
            return taken ? nil : s.def
        }
        if d.isEmpty { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: d)
    }

    /// 変える。同じキーを使っている別の項目は「なし」にする（同じキーで2つは動かせない）
    static func set(_ side: Side, _ c: KeyCombo?) {
        var s = stored
        if let c {
            for o in sides where o != side && combo(o).map({ $0.same(c) }) == true { s[String(o.rawValue)] = Data() }
        }
        s[String(side.rawValue)] = c.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(s, forKey: key)
    }

    static func reset(_ side: Side) { set(side, side.def) }
    static func resetAll() { defaults.removeObject(forKey: key) }

    /// 「キーを止める」（ほかのアプリで同じキーを使いたいとき）。開き直しても続く
    static var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }
}

// MARK: - 登録（Carbon の全体ホットキー。これ自体に許可は要らない）

enum HotKeys {
    static var onPress: ((Side) -> Void)?
    static var signature = OSType(0x6D646B77)   // 'mdkw'
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private(set) static var failed: Set<Side> = []      // ほかのアプリが使っていて登録できなかった
    private(set) static var registered = 0

    /// いまの設定で登録し直す（止めているときは全部外す）
    static func apply() {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hid = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
                if hid.signature == HotKeys.signature, let side = Side(rawValue: hid.id) {
                    DispatchQueue.main.async { HotKeys.onPress?(side) }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        suspend()
        failed = []
        guard !Shortcuts.paused else { return }
        for side in Shortcuts.sides {
            guard let c = Shortcuts.combo(side) else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(c.code, c.mods, EventHotKeyID(signature: signature, id: side.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.insert(side) }
        }
        registered = refs.count
    }

    /// いったん全部外す（キーを覚えさせている間に押しても寄らないように）
    static func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        registered = 0
    }
}

// MARK: - Mac 標準のキー
// 同じキーを Mac 本体が持っていると、押しても Mac 標準のほうが動く。止める/戻すはシステム設定の
// 「キーボード → キーボードショートカット」と同じ場所（com.apple.symbolichotkeys）を書き換える。
// 止めるのは「まどわけのキーと重なっているもの」だけ。戻すときは、まどわけが止めたものだけ戻す。

enum SystemKeys {
    /// 書かれていないときの既定（矢印を使うもの）。番号：名前・キー（文字・キー番号・修飾）
    static let known: [String: (name: String, params: [Int])] = [
        "32": ("Mission Control", [65535, 126, 0x840000]),
        "34": ("Mission Control", [65535, 126, 0x860000]),
        "33": ("アプリケーションウインドウ", [65535, 125, 0x840000]),
        "35": ("アプリケーションウインドウ", [65535, 125, 0x860000]),
        "79": ("左の操作スペースに移動", [65535, 123, 0x840000]),
        "80": ("左の操作スペースに移動", [65535, 123, 0x860000]),
        "81": ("右の操作スペースに移動", [65535, 124, 0x840000]),
        "82": ("右の操作スペースに移動", [65535, 124, 0x860000]),
        "60": ("前の入力ソースを選択", [32, 49, 0x40000]),
        "61": ("次の入力ソースを選択", [32, 49, 0xC0000]),
        "64": ("Spotlight 検索", [32, 49, 0x100000]),
        "28": ("スクリーンショット", [51, 20, 0x120000]),
        "30": ("スクリーンショット", [52, 21, 0x120000]),
        "184": ("スクリーンショット", [53, 23, 0x120000]),
    ]
    static var domain = "com.apple.symbolichotkeys" as CFString     // 自己テストでは別の名前に差し替える
    static var applyNow = true                                      // 自己テストでは反映の命令を撃たない
    private static let memoKey = "systemKeysStopped"                // まどわけが止めた番号

    static func table() -> [String: Any] {
        CFPreferencesCopyValue("AppleSymbolicHotKeys" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    static func name(_ id: String) -> String { known[id]?.name ?? "Mac 標準のショートカット" }

    /// 有効か（書かれていなければ、既定を知っているものは有効）
    static func isEnabled(_ id: String, _ t: [String: Any]) -> Bool {
        guard let e = t[id] as? [String: Any] else { return known[id] != nil }
        return (e["enabled"] as? Bool) ?? ((e["enabled"] as? Int).map { $0 != 0 } ?? true)
    }

    /// その番号のいまのキー（システム設定で変えていればそちらを読む）
    static func combo(_ id: String, _ t: [String: Any]) -> KeyCombo? {
        let p: [Int]
        if let v = (t[id] as? [String: Any])?["value"] as? [String: Any], let q = v["parameters"] as? [Int], q.count == 3 { p = q }
        else if let k = known[id] { p = k.params }
        else { return nil }
        if p[1] == 65535 { return nil }                                      // キーなし
        let f = p[2]
        var m = 0
        if f & 0x20000 != 0 { m |= shiftKey }
        if f & 0x40000 != 0 { m |= controlKey }
        if f & 0x80000 != 0 { m |= optionKey }
        if f & 0x100000 != 0 { m |= cmdKey }
        let ch = KeyCombo.named[p[1]] ?? KeyCombo.fKeys[p[1]] ??
            (p[0] > 0 && p[0] < 65535 ? (UnicodeScalar(p[0]).map { String($0).uppercased() } ?? "?") : "?")
        return KeyCombo(code: UInt32(p[1]), mods: UInt32(m), char: ch)
    }

    /// いま有効な Mac 標準のキーのうち、c と同じもの（番号）
    static func clashing(_ c: KeyCombo) -> [String] {
        let t = table()
        let ids = Set(t.keys).union(known.keys)
        return ids.filter { isEnabled($0, t) && combo($0, t)?.same(c) == true }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }
    static func clashes(_ c: KeyCombo) -> Bool { !clashing(c).isEmpty }

    /// まどわけのキーと重なっている Mac 標準のキー（側ごと）
    static func clashesNow() -> [(Side, [String])] {
        Shortcuts.sides.compactMap { s in
            guard let c = Shortcuts.combo(s) else { return nil }
            let ids = clashing(c)
            return ids.isEmpty ? nil : (s, ids)
        }
    }

    static var stopped: [String] { Shortcuts.defaults.stringArray(forKey: memoKey) ?? [] }

    /// 「重なる Mac 標準のキーを止める」の設定
    static var wantStop: Bool {
        get { Shortcuts.defaults.bool(forKey: "stopSystemKeys") }
        set { Shortcuts.defaults.set(newValue, forKey: "stopSystemKeys") }
    }

    /// 設定に合わせる：止めたいなら重なるものを止め、もう重ならない（または止めたくない）ものは戻す
    static func sync(done: (() -> Void)? = nil) {
        var t = table()
        var memo = stopped
        let mine = Shortcuts.sides.compactMap { Shortcuts.combo($0) }
        var changed = false
        // 戻す：止めたくない、またはまどわけのキーと重ならなくなったもの
        for id in memo {
            let c = combo(id, t)
            if !wantStop || !mine.contains(where: { c?.same($0) == true }) {
                write(&t, id, enabled: true); memo.removeAll { $0 == id }; changed = true
            }
        }
        // 止める
        if wantStop {
            for c in mine {
                for id in Set(t.keys).union(known.keys) where isEnabled(id, t) && combo(id, t)?.same(c) == true {
                    write(&t, id, enabled: false); if !memo.contains(id) { memo.append(id) }; changed = true
                }
            }
        }
        Shortcuts.defaults.set(memo, forKey: memoKey)
        guard changed else { done?(); return }
        CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, t as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard applyNow else { done?(); return }
        // ログインし直さなくても効くように、システム設定と同じ反映の命令を呼ぶ（画面が固まらないよう裏で）
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
            p.arguments = ["-u"]
            if (try? p.run()) != nil {
                let deadline = Date().addingTimeInterval(5)
                while p.isRunning && Date() < deadline { usleep(50_000) }
                if p.isRunning { p.terminate() }
            }
            DispatchQueue.main.async { done?() }
        }
    }

    private static func write(_ t: inout [String: Any], _ id: String, enabled: Bool) {
        var v = t[id] as? [String: Any] ?? ["value": ["parameters": known[id]?.params ?? [65535, 65535, 0], "type": "standard"]]
        v["enabled"] = enabled
        t[id] = v
    }
}

// MARK: - キーを覚える欄

final class ShortcutField: NSButton {
    let side: Side
    var onChange: ((KeyCombo?) -> Void)?
    private var monitor: Any?
    private(set) var recording = false

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self; action = #selector(toggle)
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if recording { title = "キーを押す"; contentTintColor = accent; return }
        contentTintColor = nil
        title = Shortcuts.combo(side)?.display ?? "なし"
        toolTip = "押してからキーを押す（delete＝なし・esc＝やめる）"
    }

    @objc func toggle() { recording ? stop() : start() }

    func start() {
        guard !recording else { return }
        recording = true
        HotKeys.suspend()
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self else { return e }
            self.handle(code: e.keyCode, flags: e.modifierFlags, chars: e.characters(byApplyingModifiers: []))
            return nil
        }
    }

    /// 押されたキー（テストからも呼ぶ）
    func handle(code: UInt16, flags: NSEvent.ModifierFlags, chars: String?) {
        let plain = flags.intersection([.command, .option, .control, .shift]).isEmpty
        if Int(code) == kVK_Escape && plain { stop(); return }
        if (Int(code) == kVK_Delete || Int(code) == kVK_ForwardDelete) && plain { stop(); onChange?(nil); return }
        guard let c = KeyCombo.from(code: code, flags: flags, chars: chars) else { NSSound.beep(); return }   // ⌘⌃⌥ のどれかが要る
        stop(); onChange?(c)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        refresh()
        HotKeys.apply()
    }
}

// MARK: - 設定の窓

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private var fields: [Side: ShortcutField] = [:]
    private var warns: [Side: NSImageView] = [:]
    var onKeysChanged: (() -> Void)?
    var confirm: ((String, String) -> Bool) = { _, _ in true }   // 「止めますか」（テストでは差し替える）
    private let pause = NSSwitch()
    private let sysKeys = NSSwitch()
    private let sysNote = NSTextField(labelWithString: "")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "設定"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.contentView = makeContent()
        w.setContentSize(w.contentView!.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func header(_ sym: String, _ text: String) -> NSView {
        let i = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: text)!)
        i.contentTintColor = .secondaryLabelColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .secondaryLabelColor
        let s = NSStackView(views: [i, l]); s.spacing = 6
        return s
    }

    private func row(_ sym: String, _ text: String, _ sw: NSSwitch, tip: String) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!)
        icon.contentTintColor = accent
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 13); l.toolTip = tip
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: [icon, l, spacer, sw]); r.spacing = 10
        return r
    }

    func makeContent() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8; grid.columnSpacing = 10
        for s in Shortcuts.sides {
            let icon = NSImageView(image: NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.name)!)
            icon.contentTintColor = accent
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            let name = NSTextField(labelWithString: s.name)
            name.font = .systemFont(ofSize: 13)
            let f = ShortcutField(side: s)
            f.onChange = { [weak self] c in self?.change(s, c) }
            fields[s] = f
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "使用中")!)
            warn.contentTintColor = .systemOrange
            warns[s] = warn
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "既定に戻す")!,
                                 target: self, action: #selector(resetOne(_:)))
            reset.bezelStyle = .accessoryBarAction; reset.isBordered = false
            reset.tag = Int(s.rawValue); reset.toolTip = "既定（\(s.def.display)）に戻す"
            grid.addRow(with: [icon, name, f, warn, reset])
        }
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).width = 40
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }

        pause.target = self; pause.action = #selector(pauseChanged)
        let pauseRow = row("pause.circle", "キーを止める", pause, tip: "オンのあいだは、ほかのアプリで同じキーが使える")

        sysKeys.target = self; sysKeys.action = #selector(sysKeysChanged)
        let sysRow = row("command", "重なる Mac 標準のキーを止める", sysKeys,
                         tip: "選んだキーを Mac 本体も使っているときだけ、そちらを止める。オフに戻すと Mac 標準に戻る")
        sysNote.font = .systemFont(ofSize: 11); sysNote.textColor = .secondaryLabelColor
        sysNote.lineBreakMode = .byWordWrapping; sysNote.maximumNumberOfLines = 3

        let resetAll = NSButton(title: "すべて既定に戻す", image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)!,
                                target: self, action: #selector(resetAllKeys))
        resetAll.imagePosition = .imageLeading; resetAll.bezelStyle = .rounded

        let stack = NSStackView(views: [header("keyboard", "ショートカット"), grid, pauseRow, sysRow, sysNote, resetAll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.setCustomSpacing(4, after: sysRow)
        for v in [pauseRow, sysRow, sysNote] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualTo: grid.widthAnchor, constant: 44).isActive = true
        refresh()
        return stack
    }

    func refresh() {
        let clashes = SystemKeys.clashesNow()
        for s in Shortcuts.sides {
            fields[s]?.refresh()
            let sysIDs = clashes.first(where: { $0.0 == s })?.1 ?? []
            let busy = HotKeys.failed.contains(s)
            warns[s]?.isHidden = !busy && sysIDs.isEmpty
            warns[s]?.toolTip = !sysIDs.isEmpty ? "Mac 標準の「\(SystemKeys.name(sysIDs[0]))」と同じキー"
                                                : "ほかのアプリが使っているキー＝別のキーにしてください"
        }
        pause.state = Shortcuts.paused ? .on : .off
        sysKeys.state = SystemKeys.wantStop ? .on : .off
        let stoppedNames = Array(Set(SystemKeys.stopped.map { SystemKeys.name($0) })).sorted()
        let clashNames = Array(Set(clashes.flatMap { $0.1 }.map { SystemKeys.name($0) })).sorted()
        if !stoppedNames.isEmpty { sysNote.stringValue = "止めているもの：" + stoppedNames.joined(separator: "・") }
        else if !clashNames.isEmpty { sysNote.stringValue = "重なっているもの：" + clashNames.joined(separator: "・") }
        else { sysNote.stringValue = "いまは重なっていません" }
    }

    private func change(_ s: Side, _ c: KeyCombo?) {
        Shortcuts.set(s, c)
        // Mac 標準と重なるキーを選んだら、ショットと同じく「止めますか」と聞く
        if let c, !SystemKeys.wantStop, let id = SystemKeys.clashing(c).first {
            if confirm("Mac 標準のキーと重なっています", "\(c.display) は Mac 標準の「\(SystemKeys.name(id))」が使っています。Mac 標準のほうを止めますか？\n設定の「重なる Mac 標準のキーを止める」をオフにすれば、いつでも元に戻せます。") {
                SystemKeys.wantStop = true
            }
        }
        afterChange()
    }

    private func afterChange() {
        fields.values.forEach { $0.stop() }
        SystemKeys.sync { [weak self] in HotKeys.apply(); self?.refresh(); self?.onKeysChanged?() }
        HotKeys.apply(); refresh(); onKeysChanged?()
    }

    @objc func resetOne(_ b: NSButton) {
        guard let s = Side(rawValue: UInt32(b.tag)) else { return }
        Shortcuts.reset(s); afterChange()
    }

    @objc func resetAllKeys() { Shortcuts.resetAll(); afterChange() }

    @objc func pauseChanged() {
        Shortcuts.paused = pause.state == .on
        HotKeys.apply(); refresh(); onKeysChanged?()
    }

    @objc func sysKeysChanged() {
        sysKeys.isEnabled = false
        SystemKeys.wantStop = sysKeys.state == .on
        SystemKeys.sync { [weak self] in
            HotKeys.apply(); self?.sysKeys.isEnabled = true; self?.refresh(); self?.onKeysChanged?()
        }
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { fields.values.forEach { $0.stop() } }
}
