// まどわけ — ⌘⌥← / ⌘⌥↑ / ⌘⌥→（設定で変えられる）で、いま前に出ているウインドウを左・上・右の半分に寄せる。
// メニューバーに常駐するだけのアプリ（Dock には出ない）。
import AppKit
import ServiceManagement

// MARK: - メニューバー

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var settings: SettingsWindow?
    private let pauseItem = NSMenuItem(title: "キーを止める", action: #selector(togglePause), keyEquivalent: "")
    private let busyItem = NSMenuItem()
    private let trustItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "ログイン時に開く", action: #selector(toggleLogin), keyEquivalent: "")
    private let launchedAt = Date()
    private var shownTrusted: Bool?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        // 許可が変わったらアイコンで分かるように（許可なしの間は「！」の形）
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                Snapper.lastOtherPID = app.processIdentifier
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for side in Shortcuts.sides {
            let mi = NSMenuItem(title: side.title, action: #selector(snapFromMenu(_:)), keyEquivalent: "")
            mi.tag = Int(side.rawValue)
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        busyItem.isEnabled = false
        menu.addItem(busyItem)
        let set = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        set.target = self
        menu.addItem(set)
        menu.addItem(.separator())
        trustItem.target = self
        trustItem.action = #selector(openTrustSettings)
        menu.addItem(trustItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "まどわけを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu

        HotKeys.onPress = { side in
            if Snapper.snap(side) { return }
            if Snapper.trusted { NSSound.beep() } else { self.explainTrust() }
        }
        // 前に止めた Mac 標準のキーを、いまの設定に合わせ直してから登録する
        SystemKeys.sync { HotKeys.apply(); self.updateIcon(force: true) }
        HotKeys.apply()
        updateIcon(force: true)

        // 起動時は OS の案内だけ（これで設定の一覧に「まどわけ」が載る）。重なるキーの知らせは、案内と重ならないときだけ
        if !Snapper.trusted { Snapper.askForTrust() }
        else if !HotKeys.failed.isEmpty {
            let names = Shortcuts.sides.filter { HotKeys.failed.contains($0) }.map { $0.title }.joined(separator: "・")
            alert("ほかのアプリが同じショートカットを使っています", "使えないもの：\(names)\n設定でキーを変えるか、そのアプリを終了してから、まどわけを開き直してください。")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ok = Snapper.trusted
        trustItem.title = ok ? "許可：オン" : "許可：オフ（押して設定を開く）"
        trustItem.isEnabled = !ok
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        default: loginItem.state = .off
        }
        for mi in menu.items where mi.action == #selector(snapFromMenu(_:)) {
            mi.isEnabled = ok
            // いまのキーを横に出す（止めているときは出さない）
            if !Shortcuts.paused, let side = Side(rawValue: UInt32(mi.tag)), let c = Shortcuts.combo(side) {
                (mi.keyEquivalent, mi.keyEquivalentModifierMask) = c.menuKey
            } else { mi.keyEquivalent = ""; mi.keyEquivalentModifierMask = [] }
        }
        pauseItem.state = Shortcuts.paused ? .on : .off
        let busy = Shortcuts.sides.filter { HotKeys.failed.contains($0) }.map { $0.title }
        busyItem.title = "ほかのアプリと重なって使えない：" + busy.joined(separator: "・")
        busyItem.isHidden = busy.isEmpty
    }

    @objc private func snapFromMenu(_ sender: NSMenuItem) {
        guard let side = Side(rawValue: UInt32(sender.tag)) else { return }
        // メニューが閉じて元のアプリに前が戻るのを待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !Snapper.snap(side) { NSSound.beep() }
        }
    }

    @objc private func togglePause() {
        Shortcuts.paused.toggle()
        HotKeys.apply()
        updateIcon(force: true)
        settings?.refresh()
    }

    @objc private func openSettings() {
        if settings == nil {
            let w = SettingsWindow()
            w.onKeysChanged = { [weak self] in self?.updateIcon(force: true) }
            w.confirm = { title, body in
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = title
                a.informativeText = body
                a.addButton(withTitle: "止める")
                a.addButton(withTitle: "そのまま")
                return a.runModal() == .alertFirstButtonReturn
            }
            settings = w
        }
        settings?.show()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            alert("ログイン時に開く設定を変えられませんでした", "まどわけを「アプリケーション」フォルダに入れてから、もう一度試してください。")
        }
    }

    @objc private func openTrustSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // キーを押すたびに出さない（開いているあいだに1回だけ）
    private var explained = false
    private func explainTrust() {
        // 起動直後は OS の案内が出ているので重ねない
        guard !explained, Date().timeIntervalSince(launchedAt) > 5 else { NSSound.beep(); return }
        explained = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "ウインドウを動かす許可が必要です"
        a.informativeText = "システム設定の「アクセシビリティ」で「まどわけ」をオンにしてください。オンにしたら、すぐ使えます。\n\nすでにオンなのに動かないときは、一覧の「まどわけ」を選んで「−」で消し、もう一度オンにしてください。"
        a.addButton(withTitle: "設定を開く")
        a.addButton(withTitle: "あとで")
        if a.runModal() == .alertFirstButtonReturn { openTrustSettings() }
    }

    private var shownPaused: Bool?
    private func updateIcon(force: Bool = false) {
        let ok = Snapper.trusted
        guard force || ok != shownTrusted || Shortcuts.paused != shownPaused, let b = item.button else { return }
        shownTrusted = ok
        shownPaused = Shortcuts.paused
        b.appearsDisabled = Shortcuts.paused     // 止めているあいだは薄く
        b.toolTip = Shortcuts.paused ? "まどわけ（キーを止めています）" : "まどわけ"
        let img = NSImage(systemSymbolName: ok ? "rectangle.split.2x1" : "exclamationmark.triangle",
                          accessibilityDescription: ok ? "まどわけ" : "まどわけ（許可が必要）")
        img?.isTemplate = true
        b.image = img
    }

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") {
    app.setActivationPolicy(.accessory)
    exit(SelfTest.run() ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--settings-png"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    SelfTest.settingsPNG(CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
