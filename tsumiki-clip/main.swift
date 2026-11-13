// つみきクリップ：コピーした履歴をためて、あとから選んで貼る（メニューバーに常駐）。
// ⇧⌘V 開く（画面の下に帯）／⇧⌘C 順番に貼る（オンの間にコピーしたものを ⌘V のたびに前から1つずつ）
// 履歴はこの Mac の中（~/Library/Application Support/TsumikiClip）だけ。ネットにつながるコードは持たない。
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    lazy var watcher = Watcher(store: store)
    lazy var paster = Paster(store: store, watcher: watcher)
    lazy var stack = Stack(paster: paster)
    lazy var strip = Strip(store: store)
    let badge = StackBadge()
    var settings: SettingsWindow?
    var status: NSStatusItem!
    var purgeTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = AppIcon.menuImage()
        status.button?.toolTip = "つみきクリップ"
        let m = NSMenu(); m.delegate = self
        status.menu = m

        watcher.onCapture = { [weak self] c in self?.stack.add(c) }
        watcher.start()
        strip.onPaste = { [weak self] c, mode in self?.paster.paste(c, mode: mode) }
        strip.onSettings = { [weak self] in self?.openSettings() }
        stack.onUpdate = { [weak self] in
            guard let self else { return }
            self.badge.update(on: self.stack.on, pasted: self.stack.index, total: self.stack.queue.count)
        }
        HotKeys.actions = [1: { [weak self] in self?.strip.toggle() }, 2: { [weak self] in self?.toggleStack() }]
        HotKeys.apply()
        installEditMenu()
        refreshStatus()
        if store.loadFailed {
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "履歴を読めませんでした"
            a.informativeText = "壊れたファイルは clips.corrupt-…json として横に残しました。新しい履歴から始めます。"
            a.addButton(withTitle: "OK"); a.runModal()
        }
        store.purge()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.store.purge() }
    }

    func toggleStack() {
        if !stack.on && !Paster.trusted(prompt: false) {
            _ = Paster.trusted(prompt: true)      // 許可の案内を出す
            return
        }
        if stack.on { stack.stop(); return }
        if !stack.start() {
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "順番に貼るを始められません"
            a.informativeText = "アクセシビリティを許可した直後は、アプリを開き直すと使えます。"
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    /// 一時停止中はメニューバーのアイコンを薄くする
    func refreshStatus() {
        status.button?.appearsDisabled = Prefs.paused
        status.button?.toolTip = Prefs.paused ? "つみきクリップ（一時停止中）" : "つみきクリップ"
    }

    /// 帯の検索や名前の入力で ⌘V・⌘C・⌘A・⌘Z を効かせる（メニューバー常駐のアプリは自分で用意する）
    func installEditMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        main.addItem(appItem); main.addItem(editItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let ed = NSMenu(title: "編集")
        ed.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        ed.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        ed.addItem(.separator())
        ed.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        ed.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        ed.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        ed.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = ed
        NSApp.mainMenu = main
    }

    // メニューは開くたびに作る（キー・一時停止の状態を反映）
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        func add(_ t: String, _ sym: String, _ id: UInt32?, _ f: @escaping () -> Void) -> NSMenuItem {
            let it = BlockItem(title: t, block: f)
            it.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            if let id, let c = Shortcuts.combo(id) {
                let (k, mods) = c.menuKey
                it.keyEquivalent = k; it.keyEquivalentModifierMask = mods
            }
            m.addItem(it)
            return it
        }
        _ = add("開く", "rectangle.bottomhalf.inset.filled", 1) { [weak self] in self?.strip.show() }
        #if !APPSTORE
        let st = add(stack.on ? "順番に貼るをやめる" : "順番に貼る", "list.number", 2) { [weak self] in self?.toggleStack() }
        st.state = stack.on ? .on : .off
        #endif
        let p = add(Prefs.paused ? "記録を再開" : "一時停止", Prefs.paused ? "play.circle" : "pause.circle", nil) {
            Prefs.paused.toggle(); self.refreshStatus()
        }
        p.state = Prefs.paused ? .on : .off
        if !Paster.trusted(prompt: false) {
            m.addItem(.separator())
            let w = add("直接貼るには許可が要る", "exclamationmark.triangle", nil) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            w.image = w.image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        }
        if !PasteboardAccess.allowed {
            let w = add("コピーを読む許可が要る", "exclamationmark.triangle", nil) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
            }
            w.image = w.image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        }
        m.addItem(.separator())
        let s = add("設定…", "gearshape", nil) { [weak self] in self?.openSettings() }
        s.keyEquivalent = ","; s.keyEquivalentModifierMask = .command
        _ = add("履歴を全部消す…", "trash", nil) { [weak self] in self?.confirmClear() }
        m.addItem(.separator())
        let q = add("終了", "power", nil) { NSApp.terminate(nil) }
        q.keyEquivalent = "q"; q.keyEquivalentModifierMask = .command
    }

    func openSettings() {
        if settings == nil {
            let w = SettingsWindow()
            w.onKeysChanged = { HotKeys.apply() }
            w.onRetentionChanged = { [weak self] in self?.store.purge() }
            w.onClearHistory = { [weak self] in self?.confirmClear() }
            settings = w
        }
        settings?.show()
    }

    func confirmClear() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "履歴を全部消す"
        a.informativeText = "ピンボードは残ります。元に戻せません。"
        a.alertStyle = .warning
        a.addButton(withTitle: "消す"); a.addButton(withTitle: "やめる")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }
}

// MARK: - 起動

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--icons" {
    AppIcon.writeIconset(args[2]); exit(0)
}
if args.count >= 2 && args[1] == "--selftest" {
    _ = NSApplication.shared
    exit(SelfTest.run() ? 0 : 1)
}
if args.count >= 3 && args[1] == "--shot" {
    _ = NSApplication.shared
    SelfTest.shot(args[2]); exit(0)
}

// 許可の状態をファイルに書いて終わる（open -W … --args --status <ファイル> で、アプリ自身から見た状態を確かめる）
if args.count >= 3 && args[1] == "--status" {
    let s = "accessibility=\(Paster.trusted(prompt: false))\npasteboard=\(PasteboardAccess.state)\n"
    try? s.write(toFile: args[2], atomically: true, encoding: .utf8); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
