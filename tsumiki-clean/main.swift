// つみきそうじ：掃除のあいだ、キー・メディアキー・トラックパッド・マウスを効かなくするメニューバー常駐アプリ。
// 解除は3つ：①クリックを3秒押し続ける ②決めた時間で自動解除 ③それでも続いていたら見張りがアプリごと終わらせる
//（入力を捨てる口はこのアプリの中だけ＝アプリが終われば必ず戻る）。詳しくは README.md。
import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// 自動解除の時刻を過ぎても掃除が続いていたら発火する見張り（主の糸が固まっても別の糸で動く）
/// 発火したら _exit（後始末を走らせない＝主の糸が錠を握ったまま固まっていても終われる）
final class Watchdog {
    private let lock = NSLock()
    private var token = 0
    private let onFire: () -> Void
    init(onFire: @escaping () -> Void = { _exit(0) }) { self.onFire = onFire }
    func arm(after seconds: Double) {
        lock.lock(); token += 1; let my = token; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock(); let live = token == my; lock.unlock()
            if live { onFire() }
        }
    }
    func disarm() { lock.lock(); token += 1; lock.unlock() }
}

final class App: NSObject, NSApplicationDelegate {
    let blocker = Blocker()
    let watchdog = Watchdog()
    var status: NSStatusItem!
    var windows: [CurtainWindow] = []
    var ui: Timer?
    var deadline = Date()
    var cleaning = false
    var assertion: IOPMAssertionID = 0
    var waitTrust: Timer?
    /// `--clean-for 秒`：試す用。その秒数だけ掃除して終わる
    var testSeconds: Int?
    var loginLaunch = false
    let d = UserDefaults.standard

    var duration: Int { Core.clamp(d.integer(forKey: "duration")) }
    var autoStart: Bool { d.object(forKey: "autoStart") as? Bool ?? true }

    func applicationWillFinishLaunching(_ n: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        loginLaunch = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = AppIcon.menuImage()
        buildMenu()
        if testSeconds != nil || Core.shouldAutoStart(pref: autoStart, loginLaunch: loginLaunch,
                                                     uptime: ProcessInfo.processInfo.systemUptime) { start() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.rebuildCurtains() }
    }

    /// 動いているときにもう一度開いた（Finder・Spotlight・Dock から）＝始める
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { start(); return false }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "始める", action: #selector(startItem), keyEquivalent: "").target = self
        m.addItem(.separator())
        for s in Core.durations {
            let it = m.addItem(withTitle: "\(s / 60)分", action: #selector(pick(_:)), keyEquivalent: "")
            it.target = self; it.tag = s; it.state = s == duration ? .on : .off
        }
        m.addItem(.separator())
        let a = m.addItem(withTitle: "開いたら始める", action: #selector(toggleAuto), keyEquivalent: "")
        a.target = self; a.state = autoStart ? .on : .off
        if !AXIsProcessTrusted() {
            m.addItem(withTitle: "許可…", action: #selector(openPrivacy), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }

    @objc func startItem() { start() }
    @objc func pick(_ it: NSMenuItem) { d.set(it.tag, forKey: "duration"); buildMenu() }
    @objc func toggleAuto() { d.set(!autoStart, forKey: "autoStart"); buildMenu() }
    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func start() {
        guard !cleaning else { return }
        guard AXIsProcessTrusted() else { askTrust(); return }
        guard blocker.start() else { NSLog("TsumikiClean: 入力の口を作れなかった"); NSSound.beep(); return }
        cleaning = true
        let secs = testSeconds.map { min(max($0, 1), Core.maxDuration) } ?? duration
        deadline = Date().addingTimeInterval(Double(secs))
        watchdog.arm(after: Double(secs) + Core.watchdogGrace)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "掃除中" as CFString, &assertion)
        rebuildCurtains()
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        ui = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ui!, forMode: .common)
        NSLog("TsumikiClean: 開始 \(secs)秒")
    }

    /// 画面ごとに幕をかける。掃除中に画面を抜き差ししたら掛け直す
    func rebuildCurtains() {
        guard cleaning else { return }
        for w in windows { w.orderOut(nil); w.close() }
        windows = NSScreen.screens.map { CurtainWindow(screen: $0) }
        for w in windows { w.view.remain = deadline.timeIntervalSinceNow; w.orderFrontRegardless() }
        windows.first?.makeKey()
    }

    func tick() {
        let remain = deadline.timeIntervalSinceNow
        let now = ProcessInfo.processInfo.systemUptime
        let h = blocker.hold
        for w in windows { w.view.remain = remain; w.view.hold = h.progress(now) }
        if h.done(now) { stop("長押し") } else if remain <= 0 { stop("時間") }
    }

    func stop(_ why: String) {
        guard cleaning else { return }
        blocker.stop()
        watchdog.disarm()
        ui?.invalidate(); ui = nil
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        NSCursor.unhide()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        cleaning = false
        NSLog("TsumikiClean: 解除（\(why)）")
        if testSeconds != nil { NSApp.terminate(nil) }
    }

    /// 許可が無いとき：macOS の確認を出し、許可されるまで（2分）待って、許可されたら始める
    func askTrust() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        waitTrust?.invalidate()
        let until = Date().addingTimeInterval(120)
        waitTrust = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if AXIsProcessTrusted() { t.invalidate(); buildMenu(); start() }
            else if Date() > until { t.invalidate() }
        }
    }

    func applicationWillTerminate(_ n: Notification) { blocker.stop() }
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--selftest" { exit(SelfTest.run() ? 0 : 1) }
if args.count >= 3, args[1] == "--icons" { AppIcon.writeIconset(args[2]); exit(0) }
if args.count >= 7, args[1] == "--render" {
    try! CurtainLook.png(Int(args[3])!, Int(args[4])!, remain: Double(args[5])!, hold: Double(args[6])!)
        .write(to: URL(fileURLWithPath: args[2]))
    exit(0)
}
if args.count >= 3, args[1] == "--e2e" { exit(SelfTest.e2e(out: args[2]) ? 0 : 1) }

let app = NSApplication.shared
let delegate = App()
if let i = args.firstIndex(of: "--clean-for"), i + 1 < args.count { delegate.testSeconds = Int(args[i + 1]) }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
