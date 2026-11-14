// ショートカットの設定（好きなキーに変えられる）と、設定の窓。
// 保存は UserDefaults の "hotkeys"（番号 → キー）。書いていない番号は既定のキー、空のデータは「なし」。
import AppKit
import Carbon

/// 1つのキーの組み合わせ（Carbon の修飾キー＋キー番号）
struct KeyCombo: Codable, Equatable {
    var code: UInt32
    var mods: UInt32          // cmdKey / optionKey / controlKey / shiftKey の組み合わせ
    var char: String          // 表示用（「4」「S」「F5」「Space」など）

    static let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                       kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
    static let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                       kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"]

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

struct ShotAction {
    let id: UInt32
    let name: String
    let symbol: String
    let def: KeyCombo
}

enum Shortcuts {
    /// 既定は CleanShot X と同じ並び（⇧⌘3 全画面・⇧⌘4 範囲・⇧⌘5 スクロール・⇧⌘6 録画・⇧⌘7 注釈）。残りは ⇧⌘8 ウィンドウ・⇧⌘2 文字を読む
    #if APPSTORE
    static let cmdShift = UInt32(cmdKey | shiftKey | optionKey)   // App Store 版は Mac 標準（⇧⌘3/4/5）と重ならない ⌥⇧⌘
    #else
    static let cmdShift = UInt32(cmdKey | shiftKey)
    #endif
    static let actions: [ShotAction] = [
        ShotAction(id: 1, name: "範囲", symbol: "rectangle.dashed", def: KeyCombo(code: UInt32(kVK_ANSI_4), mods: cmdShift, char: "4")),
        ShotAction(id: 2, name: "全画面", symbol: "macwindow", def: KeyCombo(code: UInt32(kVK_ANSI_3), mods: cmdShift, char: "3")),
        ShotAction(id: 3, name: "スクロール", symbol: "arrow.down.to.line.compact", def: KeyCombo(code: UInt32(kVK_ANSI_5), mods: cmdShift, char: "5")),
        ShotAction(id: 4, name: "ウィンドウ", symbol: "macwindow.on.rectangle", def: KeyCombo(code: UInt32(kVK_ANSI_8), mods: cmdShift, char: "8")),
        ShotAction(id: 5, name: "文字を読む", symbol: "text.viewfinder", def: KeyCombo(code: UInt32(kVK_ANSI_2), mods: cmdShift, char: "2")),
        ShotAction(id: 6, name: "録画", symbol: "record.circle", def: KeyCombo(code: UInt32(kVK_ANSI_6), mods: cmdShift, char: "6")),
        ShotAction(id: 7, name: "注釈", symbol: "pencil.tip", def: KeyCombo(code: UInt32(kVK_ANSI_7), mods: cmdShift, char: "7")),
    ]

    static var defaults: UserDefaults = .standard
    private static let key = "hotkeys"

    private static var stored: [String: Data] { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }

    /// いまのキー（nil＝なし）
    static func combo(_ id: UInt32) -> KeyCombo? {
        guard let d = stored[String(id)] else {
            // 既定のキーが、別の項目に保存されたキーと同じなら「なし」（前の版の既定を保存している人と重ねない）
            guard let def = actions.first(where: { $0.id == id })?.def else { return nil }
            let taken = stored.contains { k, v in k != String(id) && (try? JSONDecoder().decode(KeyCombo.self, from: v)).map { $0.code == def.code && $0.mods == def.mods } == true }
            return taken ? nil : def
        }
        if d.isEmpty { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: d)
    }

    /// 変える。同じキーを使っている別の項目は「なし」にする（同じキーで2つは動かせない）。外した項目の番号を返す
    @discardableResult
    static func set(_ id: UInt32, _ c: KeyCombo?) -> [UInt32] {
        var s = stored
        var cleared: [UInt32] = []
        if let c {
            for a in actions where a.id != id && combo(a.id).map({ $0.code == c.code && $0.mods == c.mods }) == true {
                s[String(a.id)] = Data(); cleared.append(a.id)
            }
        }
        s[String(id)] = c.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(s, forKey: key)
        return cleared
    }

    @discardableResult
    static func reset(_ id: UInt32) -> [UInt32] {
        guard let a = actions.first(where: { $0.id == id }) else { return [] }
        return set(id, a.def)
    }

    static func resetAll() { defaults.removeObject(forKey: key) }
}

// MARK: - 登録（Carbon のホットキー）

enum HotKeys {
    static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private(set) static var failed: Set<UInt32> = []     // 他のアプリが使っていて登録できなかった番号

    /// いまの設定で登録し直す
    static func apply() {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hid = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
                let id = hid.id
                DispatchQueue.main.async { HotKeys.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        suspend()
        failed = []
        for a in Shortcuts.actions {
            guard let c = Shortcuts.combo(a.id) else { continue }
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(c.code, c.mods, EventHotKeyID(signature: OSType(0x54534854), id: a.id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.insert(a.id) }
            if SystemKeys.clashes(c) { failed.insert(a.id) }      // Mac 標準が同じキーを持っている
        }
    }

    /// スクロール撮影の間だけ Esc を取る（札は前面にならないので、キーの監視では受けられない）
    static let escID: UInt32 = 900
    private static var escRef: EventHotKeyRef?
    static func grabEsc(_ f: @escaping () -> Void) {
        releaseEsc()
        actions[escID] = f
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x54534854), id: escID),
                               GetApplicationEventTarget(), 0, &ref) == noErr { escRef = ref }
    }
    static func releaseEsc() {
        if let escRef { UnregisterEventHotKey(escRef) }
        escRef = nil; actions[escID] = nil
    }

    /// いったん全部外す（キーを覚えさせている間は、押しても撮影が始まらないように）
    static func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - キーを覚える欄

final class ShortcutField: NSButton {
    let actionID: UInt32
    var onChange: ((KeyCombo?) -> Void)?
    private var monitor: Any?
    private(set) var recording = false

    init(id: UInt32) {
        actionID = id
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
        title = Shortcuts.combo(actionID)?.display ?? "なし"
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
    private var fields: [UInt32: ShortcutField] = [:]
    private var warns: [UInt32: NSImageView] = [:]
    var onKeysChanged: (() -> Void)?
    var loginState: () -> Bool = { false }
    var onLogin: ((Bool) -> Void)?
    private let login = NSSwitch()
    private let sysKeys = NSSwitch()
    private let folderLabel = NSTextField(labelWithString: "")
    private let folderReset = NSButton()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
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

    func makeContent() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8; grid.columnSpacing = 10
        for a in Shortcuts.actions {
            let icon = NSImageView(image: NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.name)!)
            icon.contentTintColor = accent
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            let name = NSTextField(labelWithString: a.name)
            name.font = .systemFont(ofSize: 13)
            let f = ShortcutField(id: a.id)
            f.onChange = { [weak self] c in self?.change(a.id, c) }
            fields[a.id] = f
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "使用中")!)
            warn.contentTintColor = .systemOrange
            warn.toolTip = "他のアプリが使っているキー＝別のキーにしてください"
            warns[a.id] = warn
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "既定に戻す")!,
                                 target: self, action: #selector(resetOne(_:)))
            reset.bezelStyle = .accessoryBarAction; reset.isBordered = false
            reset.tag = Int(a.id); reset.toolTip = "既定（\(a.def.display)）に戻す"
            grid.addRow(with: [icon, name, f, warn, reset])
        }
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).width = 96
        grid.rowAlignment = .firstBaseline
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }

        login.target = self; login.action = #selector(loginChanged)
        let loginLabel = NSTextField(labelWithString: "ログイン時に起動")
        loginLabel.font = .systemFont(ofSize: 13)
        let loginIcon = NSImageView(image: NSImage(systemSymbolName: "power", accessibilityDescription: nil)!)
        loginIcon.contentTintColor = accent
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let loginRow = NSStackView(views: [loginIcon, loginLabel, spacer, login]); loginRow.spacing = 10

        // Mac 標準のスクショのキーを止める
        sysKeys.target = self; sysKeys.action = #selector(sysKeysChanged)
        let sysLabel = NSTextField(labelWithString: "Mac 標準のスクショのキーを止める")
        sysLabel.font = .systemFont(ofSize: 13)
        sysLabel.toolTip = "⇧⌘3・⇧⌘4・⇧⌘5（とコピー用の ⌃⇧⌘3・⌃⇧⌘4）。オンにするとつみきショットで使える。オフに戻すと Mac 標準に戻る"
        let sysIcon = NSImageView(image: NSImage(systemSymbolName: "command", accessibilityDescription: nil)!)
        sysIcon.contentTintColor = accent
        let sysSpacer = NSView(); sysSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let sysRow = NSStackView(views: [sysIcon, sysLabel, sysSpacer, sysKeys]); sysRow.spacing = 10
        #if APPSTORE
        sysRow.isHidden = true      // App Store 版は Mac 標準のキーを書き換えない（既定のキーを ⌥⇧⌘ にして重ねない）
        #endif

        let resetAll = NSButton(title: "すべて既定に戻す", image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)!,
                                target: self, action: #selector(resetAllKeys))
        resetAll.imagePosition = .imageLeading; resetAll.bezelStyle = .rounded

        // 保存先：今の場所・変える・既定に戻す
        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
        folderIcon.contentTintColor = accent
        folderLabel.font = .systemFont(ofSize: 13); folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let choose = NSButton(title: "変更…", target: self, action: #selector(chooseFolder)); choose.bezelStyle = .rounded
        folderReset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "既定に戻す")
        folderReset.target = self; folderReset.action = #selector(resetFolder)
        folderReset.bezelStyle = .accessoryBarAction; folderReset.isBordered = false
        folderReset.toolTip = "既定（~/Pictures/つみきショット）に戻す"
        let folderSpacer = NSView(); folderSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let folderRow = NSStackView(views: [folderIcon, folderLabel, folderSpacer, choose, folderReset]); folderRow.spacing = 10

        let sep = NSBox(); sep.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator
        let stack = NSStackView(views: [header("keyboard", "ショートカット"), grid, sysRow, resetAll, sep,
                                        header("folder", "保存先"), folderRow, sep2, header("gearshape", "起動"), loginRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.setCustomSpacing(18, after: resetAll); stack.setCustomSpacing(18, after: sep)
        stack.setCustomSpacing(18, after: folderRow); stack.setCustomSpacing(18, after: sep2)
        sep2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        sysRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        loginRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualTo: grid.widthAnchor, constant: 44).isActive = true   // 右端の「戻す」が切れないように
        refresh()
        return stack
    }

    func refresh() {
        for a in Shortcuts.actions {
            fields[a.id]?.refresh()
            warns[a.id]?.isHidden = !HotKeys.failed.contains(a.id)
        }
        login.state = loginState() ? .on : .off
        sysKeys.state = SystemKeys.anyEnabled ? .off : .on
        if SaveFolder.isMissing {
            folderLabel.stringValue = "⚠︎ " + SaveFolder.chosenDisplay
            folderLabel.toolTip = "見つからない・書けないので、いまは \(SaveFolder.display) に保存しています"
        } else {
            folderLabel.stringValue = SaveFolder.display
            folderLabel.toolTip = SaveFolder.url.path
        }
        folderReset.isHidden = !SaveFolder.isCustom
    }

    @objc func chooseFolder() {
        fields.values.forEach { $0.stop() }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "ここに保存"; p.message = "撮った画像と録画を保存するフォルダ"
        p.directoryURL = SaveFolder.url
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            SaveFolder.set(u); self?.refresh()
        }
    }

    @objc func resetFolder() { SaveFolder.set(nil); refresh() }

    private func change(_ id: UInt32, _ c: KeyCombo?) {
        Shortcuts.set(id, c)
        HotKeys.apply()
        refresh()
        onKeysChanged?()
    }

    @objc func resetOne(_ b: NSButton) {
        fields.values.forEach { $0.stop() }
        Shortcuts.reset(UInt32(b.tag)); HotKeys.apply(); refresh(); onKeysChanged?()
    }

    @objc func resetAllKeys() {
        fields.values.forEach { $0.stop() }
        Shortcuts.resetAll(); HotKeys.apply(); refresh(); onKeysChanged?()
    }

    @objc func sysKeysChanged() {
        sysKeys.isEnabled = false
        SystemKeys.setEnabled(sysKeys.state == .off) { [weak self] in
            HotKeys.apply(); self?.sysKeys.isEnabled = true; self?.refresh(); self?.onKeysChanged?()
        }
    }

    @objc func loginChanged() { onLogin?(login.state == .on); refresh() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { fields.values.forEach { $0.stop() } }
}

// MARK: - Mac 標準のスクショのキー（⇧⌘3・⇧⌘4・⇧⌘5 など）
// 同じキーを Mac 本体が持っていると、押しても Mac 標準のほうが動く。止める/戻すはシステム設定の
// 「キーボード → キーボードショートカット → スクリーンショット」と同じ場所（com.apple.symbolichotkeys）を書き換える。

enum SystemKeys {
    /// 番号：キーの中身（文字・キー番号・修飾）。⇧⌘3／⌃⇧⌘3（コピー）／⇧⌘4／⌃⇧⌘4（コピー）／⇧⌘5（スクショと録画）
    static let entries: [(id: String, combo: KeyCombo, params: [Int])] = [
        ("28", KeyCombo(code: UInt32(kVK_ANSI_3), mods: UInt32(cmdKey | shiftKey), char: "3"), [51, 20, 1179648]),
        ("29", KeyCombo(code: UInt32(kVK_ANSI_3), mods: UInt32(cmdKey | shiftKey | controlKey), char: "3"), [51, 20, 1441792]),
        ("30", KeyCombo(code: UInt32(kVK_ANSI_4), mods: UInt32(cmdKey | shiftKey), char: "4"), [52, 21, 1179648]),
        ("31", KeyCombo(code: UInt32(kVK_ANSI_4), mods: UInt32(cmdKey | shiftKey | controlKey), char: "4"), [52, 21, 1441792]),
        ("184", KeyCombo(code: UInt32(kVK_ANSI_5), mods: UInt32(cmdKey | shiftKey), char: "5"), [53, 23, 1179648]),
    ]
    static var domain = "com.apple.symbolichotkeys" as CFString     // 自己テストでは別の名前に差し替える
    static var applyNow = true                                      // 自己テストでは反映の命令を撃たない

    private static func table() -> [String: Any] {
        CFPreferencesCopyValue("AppleSymbolicHotKeys" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    /// その番号が有効か（書かれていなければ Mac の既定＝有効）
    static func isEnabled(_ id: String) -> Bool {
        guard let e = table()[id] as? [String: Any] else { return true }
        return (e["enabled"] as? Bool) ?? ((e["enabled"] as? Int).map { $0 != 0 } ?? true)
    }

    /// その番号のいまのキー（システム設定で変えていればそちらを読む。読めなければ既定）
    static func combo(_ id: String) -> KeyCombo? {
        guard let e = entries.first(where: { $0.id == id }) else { return nil }
        guard let v = (table()[id] as? [String: Any])?["value"] as? [String: Any],
              let p = v["parameters"] as? [Int], p.count == 3 else { return e.combo }
        if p[1] == 65535 { return nil }                                      // キーなし
        let f = p[2]
        var m = 0
        if f & 0x20000 != 0 { m |= shiftKey }
        if f & 0x40000 != 0 { m |= controlKey }
        if f & 0x80000 != 0 { m |= optionKey }
        if f & 0x100000 != 0 { m |= cmdKey }
        let ch = p[0] > 0 && p[0] < 65535 ? (UnicodeScalar(p[0]).map { String($0).uppercased() } ?? "?") : "?"
        return KeyCombo(code: UInt32(p[1]), mods: UInt32(m), char: ch)
    }

    /// いま Mac 標準が持っているキー（有効なものだけ）
    static var activeCombos: [KeyCombo] { entries.filter { isEnabled($0.id) }.compactMap { combo($0.id) } }
    static var anyEnabled: Bool { !activeCombos.isEmpty }
    /// 同じキーか（表示用の文字は見ず、キー番号と修飾だけで比べる）
    static func clashes(_ c: KeyCombo) -> Bool { activeCombos.contains { $0.code == c.code && $0.mods == c.mods } }

    /// 止める（false）／戻す（true）。止める前の状態を覚えておき、戻すときはそこへ戻す（元から止めていたものは止めたまま）
    static func setEnabled(_ on: Bool, done: (() -> Void)? = nil) {
        #if APPSTORE
        done?(); return
        #endif
        var t = table()
        let memo = "systemKeysBefore"
        if !on, entries.contains(where: { isEnabled($0.id) }) {
            Shortcuts.defaults.set(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, isEnabled($0.id)) }), forKey: memo)
        }
        let before = Shortcuts.defaults.dictionary(forKey: memo) as? [String: Bool]
        for e in entries {
            var v = t[e.id] as? [String: Any] ?? ["value": ["parameters": e.params, "type": "standard"]]
            v["enabled"] = on ? (before?[e.id] ?? true) : false
            t[e.id] = v
        }
        if on { Shortcuts.defaults.removeObject(forKey: memo) }
        CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, t as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard applyNow else { done?(); return }
        // ログインし直さなくても効くように、システム設定と同じ反映の命令を呼ぶ（画面が固まらないよう裏で。無い OS では再ログインで効く）
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
}
