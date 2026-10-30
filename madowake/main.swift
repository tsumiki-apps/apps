// まどわけ — ⌘⌥← / ⌘⌥↑ / ⌘⌥→ で、いま前に出ているウインドウを左・上・右の半分に寄せる。
// メニューバーに常駐するだけのアプリ（Dock には出ない）。
import AppKit
import ServiceManagement

// MARK: - メニューバー

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let keys = HotKeys()
    private let trustItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "ログイン時に開く", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "まどわけ")
            img?.isTemplate = true
            b.image = img
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for side in [Side.left, .top, .right] {
            let mi = NSMenuItem(title: side.title, action: #selector(snapFromMenu(_:)), keyEquivalent: side.keyEquivalent)
            mi.keyEquivalentModifierMask = [.command, .option]
            mi.tag = Int(side.rawValue)
            mi.target = self
            menu.addItem(mi)
        }
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

        keys.onPress = { side in
            if Snapper.snap(side) { return }
            if Snapper.trusted { NSSound.beep() } else { self.explainTrust() }
        }
        keys.register()

        // 起動時は OS の案内だけ（これで設定の一覧に「まどわけ」が載る）
        if !Snapper.trusted { Snapper.askForTrust() }
        if !keys.failed.isEmpty {
            let names = keys.failed.map { $0.title }.joined(separator: "・")
            alert("ほかのアプリが同じショートカットを使っています", "使えないもの：\(names)\nそのアプリを終了してから、まどわけを開き直してください。")
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
        }
    }

    @objc private func snapFromMenu(_ sender: NSMenuItem) {
        guard let side = Side(rawValue: UInt32(sender.tag)) else { return }
        // メニューが閉じて元のアプリに前が戻るのを待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Snapper.snap(side) }
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
        guard !explained else { NSSound.beep(); return }
        explained = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "ウインドウを動かす許可が必要です"
        a.informativeText = "システム設定の「アクセシビリティ」で「まどわけ」をオンにしてください。オンにしたら、すぐ使えます。\n\nすでにオンなのに動かないときは、一覧の「まどわけ」を選んで「−」で消し、もう一度オンにしてください。"
        a.addButton(withTitle: "設定を開く")
        a.addButton(withTitle: "あとで")
        if a.runModal() == .alertFirstButtonReturn { openTrustSettings() }
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
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
