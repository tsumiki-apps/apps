// キーの設定（好きなキーに変えられる）と Carbon のホットキー（アプリが前に出ていなくても効くキー）。
// 作りはつみきショットの Shortcuts.swift と同じ。保存は UserDefaults の "hotkeys"（番号 → キー）。書いていない番号は既定、空のデータは「なし」。
import AppKit
import Carbon

/// 1つのキーの組み合わせ（Carbon の修飾キー＋キー番号）
struct KeyCombo: Codable, Equatable {
    var code: UInt32
    var mods: UInt32
    var char: String

    static let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                       kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
    static let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                       kVK_UpArrow: "↑", kVK_DownArrow: "↓"]

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
        if KeyCombo.fKeys[Int(code)] != nil || KeyCombo.named[Int(code)] != nil { return ("", f) }
        return (char.lowercased(), f)
    }

    /// 押されたキーから作る。⌘・⌃・⌥ のどれかが要る（F キーだけは単独でもよい）
    static func from(code: UInt16, flags: NSEvent.ModifierFlags, chars: String?) -> KeyCombo? {
        let f = flags.intersection([.command, .option, .control, .shift])
        let c = Int(code)
        guard fKeys[c] != nil || !f.intersection([.command, .option, .control]).isEmpty else { return nil }
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

struct ClipAction {
    let id: UInt32
    let name: String
    let symbol: String
    let def: KeyCombo
}

enum Shortcuts {
    static let cmdShift = UInt32(cmdKey | shiftKey)
    /// 既定は本家で使っていたのと同じ並び（⇧⌘V 開く・⇧⌘C 順番に貼る）
    static let actions: [ClipAction] = [
        ClipAction(id: 1, name: "開く", symbol: "rectangle.bottomhalf.inset.filled", def: KeyCombo(code: UInt32(kVK_ANSI_V), mods: cmdShift, char: "V")),
        ClipAction(id: 2, name: "順番に貼る", symbol: "list.number", def: KeyCombo(code: UInt32(kVK_ANSI_C), mods: cmdShift, char: "C")),
    ]

    static var defaults: UserDefaults = .standard
    private static let key = "hotkeys"
    private static var stored: [String: Data] { defaults.dictionary(forKey: key) as? [String: Data] ?? [:] }

    static func combo(_ id: UInt32) -> KeyCombo? {
        guard let d = stored[String(id)] else { return actions.first { $0.id == id }?.def }
        if d.isEmpty { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: d)
    }

    /// 変える。同じキーを使っている別の項目は「なし」にする。外した項目の番号を返す
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

    static func resetAll() { defaults.removeObject(forKey: key) }
}

enum HotKeys {
    static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private(set) static var failed: Set<UInt32> = []      // 他のアプリが使っていて登録できなかった番号

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
            let st = RegisterEventHotKey(c.code, c.mods, EventHotKeyID(signature: OSType(0x54534350), id: a.id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.insert(a.id) }
        }
    }

    static func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

/// キーを覚える欄（押してからキーを押す・delete＝なし・esc＝やめる）
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
        widthAnchor.constraint(equalToConstant: 110).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if recording { title = "キーを押す"; contentTintColor = Palette.accent; return }
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

    func handle(code: UInt16, flags: NSEvent.ModifierFlags, chars: String?) {
        let plain = flags.intersection([.command, .option, .control, .shift]).isEmpty
        if Int(code) == kVK_Escape && plain { stop(); return }
        if (Int(code) == kVK_Delete || Int(code) == kVK_ForwardDelete) && plain { stop(); onChange?(nil); return }
        guard let c = KeyCombo.from(code: code, flags: flags, chars: chars) else { NSSound.beep(); return }
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
