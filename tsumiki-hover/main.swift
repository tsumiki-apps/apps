// つみきホバー：カーソルを乗せた窓が前に出て、そのまま操作の対象になる（メニューバーに常駐）。
//   control を押しているあいだは止まる ／ ⌃⌥⌘H でオン・オフ ／ メニューから休む・待ち時間・除外
//   `--selftest` 判断の自己テスト ／ `--livetest` 本物の窓で確かめる（アクセシビリティの許可が要る）
//   `--icons <フォルダ>` アイコンの PNG ／ `--menu-preview <png>` メニューバーの絵の見本
import AppKit
import Carbon
import ServiceManagement

enum Prefs {
    static let d = UserDefaults.standard
    static let defaultExcluded = ["com.runningwithcrayons.Alfred", "com.wiheads.paste", "com.apple.Spotlight",
                                  "com.raycast.macos", "com.tsumiki.shot", "pl.maketheweb.cleanshotx"]
    static var delayMs: Int {
        get { d.object(forKey: "delayMs") as? Int ?? 50 }
        set { d.set(newValue, forKey: "delayMs") }
    }
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? defaultExcluded }
        set { d.set(newValue, forKey: "excluded") }
    }
}

/// ⌃⌥⌘H（Carbon のホットキー＝許可は要らない）
final class HotKey {
    private var ref: EventHotKeyRef?
    static var action: (() -> Void)?
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }; return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x54534856), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    let brain = Brain(selfPid: getpid())
    var timer: Timer?
    var lastMouse = CGPoint(x: -1, y: -1)
    var trusted = false
    var pauseEnd: Date?            // 時間を決めて休んでいるときの終わり
    var hotKey: HotKey?
    var menuFrontApp: NSRunningApplication?
    var log = ProcessInfo.processInfo.environment["HOVER_LOG"] != nil

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        status.menu = menu
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        applyPrefs()
        HotKey.action = { [weak self] in self?.toggle() }
        hotKey = HotKey()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.brain.spaceChanged(now: self.uptime, mouse: Screen.mouse())
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { Screen.bundleCache[a.processIdentifier] = nil }
        }
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
        // 許可は外から付く・外れるので、2秒ごとに見直す
        let t2 = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.recheck() }
        RunLoop.main.add(t2, forMode: .common)
    }

    func recheck() {
        let now = AXIsProcessTrusted()
        if let e = pauseEnd, e <= Date() { pauseEnd = nil; applyPrefs() }
        if now != trusted { trusted = now; applyPrefs() } else { updateIcon() }
    }

    var running: Bool { Prefs.enabled && pauseEnd == nil && trusted }

    func applyPrefs() {
        brain.delay = Double(Prefs.delayMs) / 1000
        brain.excluded = Set(Prefs.excluded)
        if !Prefs.enabled { brain.pausedUntil = .infinity }
        else if let e = pauseEnd { brain.pausedUntil = uptime + e.timeIntervalSinceNow }
        else { brain.pausedUntil = 0 }
        updateIcon()
    }

    func updateIcon() { status.button?.image = AppIcon.menuImage(active: running) }

    func tick() {
        guard trusted, running else { return }
        // control・ボタンを押しているあいだは窓の一覧を読まない（軽く）
        if NSEvent.modifierFlags.contains(.control) || NSEvent.pressedMouseButtons != 0 { lastMouse = CGPoint(x: -1, y: -1); return }
        let m = Screen.mouse()
        // カーソルが止まっていて、待っている窓も無ければ何もしない（窓の一覧を読まない＝軽い）
        if m == lastMouse && !brain.waitingForCandidate { return }
        lastMouse = m
        let snap = Screen.snapshot(now: uptime)
        let (why, w) = brain.step(snap)
        if log && why != .waiting { FileHandle.standardError.write("\(why.rawValue)\n".data(using: .utf8)!) }
        if why == .raise, let w { Raiser.raise(w, at: snap.mouse, before: snap.windows) }
    }

    // MARK: - 操作
    @objc func toggle() {
        if pauseEnd != nil { pauseEnd = nil; Prefs.enabled = true } else { Prefs.enabled.toggle() }
        applyPrefs()
    }
    @objc func pause(_ s: NSMenuItem) { Prefs.enabled = true; pauseEnd = Date().addingTimeInterval(TimeInterval(s.tag * 60)); applyPrefs() }
    @objc func resume() { pauseEnd = nil; Prefs.enabled = true; applyPrefs() }
    @objc func setDelay(_ s: NSMenuItem) { Prefs.delayMs = s.tag; applyPrefs() }
    @objc func toggleFrontApp() {
        guard let b = menuFrontApp?.bundleIdentifier else { return }
        var list = Prefs.excluded
        if let i = list.firstIndex(of: b) { list.remove(at: i) } else { list.append(b) }
        Prefs.excluded = list; applyPrefs()
    }
    @objc func removeExcluded(_ s: NSMenuItem) {
        guard let b = s.representedObject as? String else { return }
        Prefs.excluded = Prefs.excluded.filter { $0 != b }; applyPrefs()
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } } catch { NSSound.beep() }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - メニュー（開くたびに作り直す）
    static func appName(_ bundle: String) -> String {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundle
    }

    func item(_ title: String, _ sel: Selector?, symbol: String? = nil, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        if let s = symbol { i.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        i.state = on ? .on : .off
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuFrontApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()
        // 状態
        if !trusted {
            menu.addItem(item("許可が必要", #selector(openAccessibility), symbol: "lock"))
        } else if let e = pauseEnd {
            let f = DateFormatter(); f.dateFormat = "H:mm"
            menu.addItem(item("〜\(f.string(from: e)) 休み", #selector(resume), symbol: "moon"))
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.sbmpost.AutoRaise").count > 0 {
            let w = item("AutoRaise と二重", nil, symbol: "exclamationmark.triangle"); w.isEnabled = false
            menu.addItem(w)
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }

        let onItem = item("オン", #selector(toggle), symbol: "cursorarrow.rays", on: Prefs.enabled && pauseEnd == nil)
        onItem.keyEquivalent = "h"; onItem.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(onItem)

        let pm = NSMenu(); pm.autoenablesItems = false
        for (t, m) in [("15分", 15), ("1時間", 60)] { let i = item(t, #selector(pause(_:))); i.tag = m; pm.addItem(i) }
        let p = item("休む", nil, symbol: "moon"); p.submenu = pm; menu.addItem(p)

        let dm = NSMenu(); dm.autoenablesItems = false
        for (t, ms) in [("すぐ", 0), ("50ms", 50), ("150ms", 150), ("300ms", 300), ("600ms", 600)] {
            let i = item(t, #selector(setDelay(_:)), on: Prefs.delayMs == ms); i.tag = ms; dm.addItem(i)
        }
        let d = item("待ち時間", nil, symbol: "timer"); d.submenu = dm; menu.addItem(d)

        menu.addItem(.separator())
        if let a = menuFrontApp, let b = a.bundleIdentifier, a.processIdentifier != getpid() {
            let name = a.localizedName ?? App.appName(b)
            menu.addItem(item("\(name)で止める", #selector(toggleFrontApp), symbol: "hand.raised", on: Prefs.excluded.contains(b)))
        }
        let em = NSMenu(); em.autoenablesItems = false
        for b in Prefs.excluded.sorted(by: { App.appName($0) < App.appName($1) }) {
            let i = item(App.appName(b), #selector(removeExcluded(_:)), on: true); i.representedObject = b; em.addItem(i)
        }
        if em.items.isEmpty { let i = item("なし", nil); i.isEnabled = false; em.addItem(i) }
        let e = item("除外", nil, symbol: "nosign"); e.submenu = em; menu.addItem(e)

        menu.addItem(.separator())
        menu.addItem(item("ログイン時に開く", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        let q = item("終了", #selector(quit)); q.keyEquivalent = "q"; menu.addItem(q)
    }
}

let args = CommandLine.arguments
if args.contains("--selftest") { exit(SelfTest.run()) }
if args.contains("--livetest") { exit(LiveTest.run()) }
if let i = args.firstIndex(of: "--dummy"), i + 1 < args.count { Dummy.run(Array(args[(i + 1)...])) }
if let i = args.firstIndex(of: "--icons"), i + 1 < args.count { AppIcon.writeIconset(args[i + 1]); exit(0) }
if let i = args.firstIndex(of: "--menu-preview"), i + 1 < args.count { AppIcon.menuPreview(args[i + 1]); exit(0) }
// 知らない「--」の引数・足りない引数では起動しない（試験のつもりで本体が常駐しないように）
if args.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write("使い方: --selftest | --livetest | --icons <dir> | --menu-preview <png>\n".data(using: .utf8)!); exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
