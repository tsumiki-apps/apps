// つみきトレイ：ファイル・文字・画像・URL をドラッグしている間だけ画面の端に棚が出て、一時的に置いておける。
// 置いたファイルは「場所の控え」だけ。取り出しはいつもコピー＝元のファイルを動かさない・消さない。
//   --selftest            架空のファイルで中身の扱い・位置・見分けを確かめる（画面の許可は要らない）
//   --render <出力.png>   棚（空・置いた後・しまった取っ手）をライト/ダークで1枚に描く
//   --icons <フォルダ>     アプリアイコンの .iconset を書き出す
//   --store <フォルダ>     中身の置き場を変えて起動する（試すとき用。ふだんは ~/Library/Application Support/TsumikiTray）
import AppKit
import Carbon
import ServiceManagement

// MARK: - ドラッグの見張り

/// 画面のどこかでドラッグが始まったら知らせる。
/// 「マウスのドラッグ」と「ドラッグ用の受け渡し場所が書き換わった」がそろったときだけ＝窓の移動や文字の範囲選択では出ない。
/// マウスの動きを見るだけなので、アクセシビリティの許可は要らない。
final class DragWatcher {
    private let pb = NSPasteboard(name: .drag)
    private var baseline: Int
    private(set) var active = false
    private var poll: Timer?
    private var monitors: [Any] = []
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    init() { baseline = pb.changeCount }

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.resync() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] e in self?.dragged(e.modifierFlags) }) { monitors.append(m) }
    }

    /// 押した瞬間の値を覚える（そこから変わったら、このドラッグで何かを運び始めた）
    func resync() { if !active { baseline = pb.changeCount } }

    /// Fn を押しながらのドラッグでは出さない
    static func ignored(_ flags: NSEvent.ModifierFlags) -> Bool { flags.contains(.function) }

    private func dragged(_ eventFlags: NSEvent.ModifierFlags) {
        guard !active else { return }
        let c = pb.changeCount
        guard c != baseline else { return }
        baseline = c
        // ドラッグの知らせに付いている印と、いまのキーの状態の両方を見る
        // 裏で動くアプリでは NSEvent.modifierFlags から Fn が落ちることがあるので、キーボードそのものの状態も見る
        let hw = CGEventSource.flagsState(.hidSystemState).union(CGEventSource.flagsState(.combinedSessionState))
        if DragWatcher.ignored(eventFlags.union(NSEvent.modifierFlags)) || hw.contains(.maskSecondaryFn) { return }
        active = true
        onBegin()
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate(); self.active = false; self.baseline = self.pb.changeCount
            self.onEnd()
        }
    }
}

// MARK: - キー（⇧⌘9 で出す／しまう）。Carbon のホットキー＝許可は要らない

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?
    init(code: UInt32, mods: UInt32, _ f: @escaping () -> Void) {
        HotKey.action = f
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action?(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(code, mods, EventHotKeyID(signature: OSType(0x54545259), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - アプリ

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// `--store <フォルダ>`：試すときに本物のトレイの中身と分ける
    let store: Store = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--store"), i + 1 < a.count { return Store(dir: URL(fileURLWithPath: a[i + 1])) }
        return Store()
    }()
    var shelf: Shelf!
    let watcher = DragWatcher()
    var status: NSStatusItem!
    var hotkey: HotKey?
    private var toggleItem: ClosureItem!
    private var rightItem: ClosureItem!, leftItem: ClosureItem!
    private var removeItem: ClosureItem!, tuckItem: ClosureItem!, loginItem: ClosureItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        shelf = Shelf(store: store)
        shelf.onDragOutEnded = { [weak self] in self?.watcher.resync() }
        watcher.onBegin = { [weak self] in self?.shelf.systemDragBegan() }
        watcher.onEnd = { [weak self] in self?.shelf.systemDragEnded() }
        watcher.start()
        hotkey = HotKey(code: UInt32(kVK_ANSI_9), mods: UInt32(cmdKey | shiftKey)) { [weak self] in self?.shelf.toggle() }
        setupMenu()
        shelf.restore()
    }

    /// 「このアプリで開く」・つみきショットの「トレイへ」から来たファイル
    func application(_ app: NSApplication, open urls: [URL]) {
        guard shelf != nil else { return }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty, store.addFiles(files) != nil { shelf.announceAdded() }
    }

    private func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = AppIcon.menuImage()
        let m = NSMenu(); m.delegate = self
        toggleItem = ClosureItem(title: "出す", key: "9") { [weak self] in self?.shelf.toggle() }
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.image = symbol("sidebar.right", 13)
        m.addItem(toggleItem)
        let paste = ClosureItem(title: "クリップボードを入れる") { [weak self] in
            guard let self else { return }
            if self.shelf.take(NSPasteboard.general) { self.shelf.show() } else { NSSound.beep() }
        }
        paste.image = symbol("doc.on.clipboard", 13); m.addItem(paste)
        let clear = ClosureItem(title: "全部消す") { [weak self] in self?.store.removeAll() }
        clear.image = symbol("trash", 13); m.addItem(clear)
        m.addItem(.separator())
        let pos = NSMenuItem(title: "位置", action: nil, keyEquivalent: ""); pos.image = symbol("rectangle.righthalf.inset.filled", 13)
        let sub = NSMenu()
        rightItem = ClosureItem(title: "右") { [weak self] in self?.setSide("right") }
        leftItem = ClosureItem(title: "左") { [weak self] in self?.setSide("left") }
        sub.addItem(rightItem); sub.addItem(leftItem); pos.submenu = sub; m.addItem(pos)
        removeItem = ClosureItem(title: "取り出したら消す") { [weak self] in self?.flip("removeAfterDrag") }
        tuckItem = ClosureItem(title: "端にしまう") { [weak self] in self?.flip("autoTuck") }
        loginItem = ClosureItem(title: "ログイン時に開く") { [weak self] in self?.toggleLogin() }
        [removeItem, tuckItem, loginItem].forEach { m.addItem($0!) }
        m.addItem(.separator())
        m.addItem(ClosureItem(title: "終了", key: "q") { NSApp.terminate(nil) })
        status.menu = m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        toggleItem.title = shelf.state == .shown ? "しまう" : "出す"
        rightItem.state = shelf.side == "right" ? .on : .off
        leftItem.state = shelf.side == "left" ? .on : .off
        removeItem.state = shelf.removeAfterDrag ? .on : .off
        tuckItem.state = shelf.autoTuck ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func flip(_ key: String) {
        let d = UserDefaults.standard
        d.set(!(d.object(forKey: key) as? Bool ?? true), forKey: key)
    }

    private func setSide(_ s: String) {
        UserDefaults.standard.set(s, forKey: "side")
        if shelf.state != .hidden { shelf.hide(); shelf.show() }
    }

    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
if let i = args.firstIndex(of: "--icons"), i + 1 < args.count { AppIcon.writeIconset(args[i + 1]); exit(0) }
if let i = args.firstIndex(of: "--render"), i + 1 < args.count { SelfTest.render(to: args[i + 1]); exit(0) }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
