// つみきウェイク：Mac を眠らせないメニューバーのアプリ。
// 左クリック＝メニュー・右クリック＝すぐ開始／停止。⌃⌥⌘W でも切り替え。
// 眠らせない宣言（IOPMAssertion）を出すだけで、電源の設定（pmset）は書き換えない。
import AppKit
import Carbon
import ServiceManagement
import UserNotifications

// MARK: - ショートカットキー（⌃⌥⌘W）

final class HotKey {
    static var action: (() -> Void)?
    private static var installed = false
    private var ref: EventHotKeyRef?
    static let label = "⌃⌥⌘W"

    /// 登録できたか（ほかのアプリが同じキーを使っていると false）
    private(set) var ok = true

    func set(_ on: Bool) {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        ok = true
        guard on else { return }
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.installed = true
        }
        ok = RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: OSType(0x54535741), id: 1), GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - アプリ

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let core = Core(defaults: .standard)
    let hot = HotKey()
    var item: NSStatusItem!
    var timer: Timer?
    let picker = NSDatePicker()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        core.onChange = { [weak self] in self?.refresh() }
        HotKey.action = { [weak self] in self?.core.toggle() }
        hot.set(core.hotkey)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        // メニューを開いている間も見回る（.common）
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        core.prime(Power.read())
        if core.startAtLaunch { core.toggle() } else { refresh() }
        let others = Others.running()
        if !others.isEmpty { say("二重", others.joined(separator: "・")) }
    }

    func applicationWillTerminate(_ n: Notification) { core.stop() }

    // MARK: 見回り

    func tick() {
        if let r = core.tick(power: Power.read()) { notify(r) }
        refresh()
    }

    @objc func didWake() {
        if let r = core.didWake(power: Power.read()) { notify(r) }
        refresh()
    }

    @objc func willSleep() { core.willSleep() }

    /// 同じ役目のアプリが起動したら知らせる
    @objc func appLaunched(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = Others.names([a.bundleIdentifier ?? ""]).first else { return }
        say("二重", name)
    }

    func notify(_ r: Reason) {
        say("眠れる", r == .battery ? "電池 \(core.batteryLimit)%" : "時間切れ")
    }

    func say(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: 見た目

    var stateText: String {
        guard let s = core.session else { return "眠れる" }
        if core.failed { return "眠れる（宣言できず）" }
        var t = core.keeper.display ? "起きている・画面も" : "起きている"
        if let r = s.remaining(at: Date()), let e = s.end { t += "　残り\(Fmt.remain(r))（\(Fmt.clock(e))まで）" }
        return t
    }

    func refresh() {
        item.button?.image = AppIcon.menuImage(core.look)
        item.button?.toolTip = stateText
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { core.toggle(); return }
        let m = buildMenu()
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: メニュー

    func row(_ title: String, _ symbol: String?, _ sel: Selector?, tag: Int = 0, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.tag = tag; i.state = on ? .on : .off
        if let s = symbol { i.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        return i
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let head = NSMenuItem(title: stateText, action: nil, keyEquivalent: "")
        head.image = AppIcon.menuImage(core.look); head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())

        let go = row(core.awake ? "停止" : "開始", core.awake ? "stop.circle" : "play.circle", #selector(toggle))
        if core.hotkey && hot.ok { go.keyEquivalent = "w"; go.keyEquivalentModifierMask = [.control, .option, .command] }
        m.addItem(go)

        // 時間
        let tm = NSMenu()
        for (label, min) in [("無期限", 0), ("15分", 15), ("30分", 30), ("1時間", 60), ("2時間", 120), ("4時間", 240), ("8時間", 480)] {
            let current = core.session?.plan == min
            tm.addItem(row(label, nil, #selector(pickMinutes(_:)), tag: min, on: current))
        }
        tm.addItem(.separator())
        tm.addItem(untilRow())
        let ti = row("時間", "timer", nil); ti.submenu = tm
        m.addItem(ti)

        if core.session?.end != nil {
            let em = NSMenu()
            em.addItem(row("15分", nil, #selector(extend(_:)), tag: 15))
            em.addItem(row("1時間", nil, #selector(extend(_:)), tag: 60))
            let ei = row("延長", "plus.circle", nil); ei.submenu = em
            m.addItem(ei)
        }

        m.addItem(row("画面も", "display", #selector(toggleDisplay), on: core.display))

        let others = Others.running()
        if !others.isEmpty {
            m.addItem(.separator())
            let w = row("二重：\(others.joined(separator: "・"))", "exclamationmark.triangle", nil)
            w.isEnabled = false
            w.toolTip = "同じ役目のアプリも動いています"
            m.addItem(w)
        }

        m.addItem(.separator())
        // 設定
        let sm = NSMenu()
        sm.addItem(row("ログイン時に起動", nil, #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        sm.addItem(row("起動時に開始", nil, #selector(toggleSetting(_:)), tag: 1, on: core.startAtLaunch))
        sm.addItem(row("復帰時に開始", nil, #selector(toggleSetting(_:)), tag: 2, on: core.startOnWake))
        let bm = NSMenu()
        for (label, v) in [("なし", 0), ("10%", 10), ("20%", 20), ("30%", 30)] {
            bm.addItem(row(label, nil, #selector(pickBattery(_:)), tag: v, on: core.batteryLimit == v))
        }
        let bi = row("電池で停止", nil, nil); bi.submenu = bm
        sm.addItem(bi)
        let lm = NSMenu()
        for (label, v) in [("無期限", 0), ("1時間", 60), ("2時間", 120), ("4時間", 240), ("8時間", 480)] {
            lm.addItem(row(label, nil, #selector(pickDefault(_:)), tag: v, on: core.defaultMinutes == v))
        }
        let li = row("開始の長さ", nil, nil); li.submenu = lm
        sm.addItem(li)
        let hk = row("ショートカット \(HotKey.label)\(core.hotkey && !hot.ok ? "（ほかと重なり使えない）" : "")", nil,
                     #selector(toggleSetting(_:)), tag: 3, on: core.hotkey)
        sm.addItem(hk)
        let si = row("設定", "gearshape", nil); si.submenu = sm
        m.addItem(si)

        // 記録
        let rm = NSMenu()
        for t in ["通算　\(Fmt.total(core.stats.total))", "回数　\(core.stats.count)回", "最長　\(Fmt.total(core.stats.longest))"] {
            let r = NSMenuItem(title: t, action: nil, keyEquivalent: ""); r.isEnabled = false; rm.addItem(r)
        }
        let ri = row("記録", "chart.bar", nil); ri.submenu = rm
        m.addItem(ri)

        m.addItem(.separator())
        let q = row("閉じる", "xmark.circle", #selector(quit)); q.keyEquivalent = "q"
        m.addItem(q)
        return m
    }

    /// 「時刻まで」の行：時刻の欄と ▶
    func untilRow() -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let label = NSTextField(labelWithString: "時刻")
        label.frame = NSRect(x: 20, y: 6, width: 40, height: 18)
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.locale = Locale(identifier: "ja_JP")
        if let e = core.session?.end { picker.dateValue = e }
        else if picker.dateValue < Date() {
            // 既定は1時間後の正時（10:20 なら 11:00）
            let h = Calendar.current.component(.hour, from: Date().addingTimeInterval(3600))
            picker.dateValue = When.next(hour: h, minute: 0, after: Date())
        }
        picker.frame = NSRect(x: 60, y: 3, width: 90, height: 24)
        let b = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "開始")!, target: self, action: #selector(pickUntil))
        b.bezelStyle = .accessoryBarAction; b.isBordered = false
        b.frame = NSRect(x: 158, y: 3, width: 30, height: 24)
        b.toolTip = "この時刻まで"
        [label, picker, b].forEach { v.addSubview($0) }
        let i = NSMenuItem(); i.view = v
        return i
    }

    // MARK: 操作

    @objc func toggle() { core.toggle() }
    @objc func pickMinutes(_ s: NSMenuItem) { core.start(minutes: s.tag == 0 ? nil : s.tag) }
    @objc func extend(_ s: NSMenuItem) { core.extend(minutes: s.tag) }
    @objc func toggleDisplay() { core.display.toggle() }
    @objc func pickBattery(_ s: NSMenuItem) { core.batteryLimit = s.tag }
    @objc func pickDefault(_ s: NSMenuItem) { core.defaultMinutes = s.tag }

    @objc func pickUntil() {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: picker.dateValue)
        core.start(until: When.next(hour: c.hour ?? 0, minute: c.minute ?? 0, after: Date()))
        item.menu?.cancelTracking()
        item.button?.menu?.cancelTracking()
    }

    @objc func toggleSetting(_ s: NSMenuItem) {
        switch s.tag {
        case 1: core.startAtLaunch.toggle()
        case 2: core.startOnWake.toggle()
        case 3: core.hotkey.toggle(); hot.set(core.hotkey)
        default: break
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - 起動

let args = CommandLine.arguments
if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
if let i = args.firstIndex(of: "--icons") { AppIcon.writeIconset(args[i + 1]); exit(0) }
if let i = args.firstIndex(of: "--menu-icons") { SelfTest.writeMenuIcons(args[i + 1]); exit(0) }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
