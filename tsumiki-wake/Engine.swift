// 中身（画面なし）：起きている時間・眠らせない宣言・電池・記録・ほかの起こすアプリ。
// 画面（main.swift）はここを呼ぶだけ。自己テスト（SelfTest.swift）もここを直接たたく。
import AppKit
import IOKit.pwr_mgt
import IOKit.ps

/// 1回の「起きている」時間。end が nil なら無期限
struct Session: Equatable {
    var start: Date
    var end: Date?
    /// 選んだ長さ（0＝無期限・分・-1＝時刻まで／延長した）。メニューのチェック用
    var plan: Int = 0
    func remaining(at now: Date) -> TimeInterval? { end.map { max(0, $0.timeIntervalSince(now)) } }
    func expired(at now: Date) -> Bool { if let e = end { return now >= e }; return false }
}

enum Fmt {
    /// 残り：「45分」「1:05」（時:分）「2日3時間」
    static func remain(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded(.up))
        if m < 60 { return "\(m)分" }
        if m < 24 * 60 { return String(format: "%d:%02d", m / 60, m % 60) }
        return "\(m / 1440)日\((m % 1440) / 60)時間"
    }
    /// 通算：「35分」「8,187時間」
    static func total(_ s: TimeInterval) -> String {
        let h = Int(s / 3600)
        if h < 1 { return "\(Int(s / 60))分" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: h)) ?? "\(h)")時間"
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "H:mm"
        return f.string(from: d)
    }
}

enum When {
    /// 次にその時刻が来る日時（今より前なら翌日）
    static func next(hour: Int, minute: Int, after now: Date, cal: Calendar = .current) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute; c.second = 0
        let d = cal.date(from: c)!
        return d > now ? d : cal.date(byAdding: .day, value: 1, to: d)!
    }
}

/// 眠らせない宣言（IOPMAssertion）。電源の設定（pmset）は一切書き換えない＝アプリが終われば必ず元どおり
final class Keeper {
    let name: String
    private var sysID: IOPMAssertionID = 0
    private var dispID: IOPMAssertionID = 0
    /// 自己テスト用：宣言の作成に失敗したことにする
    var refuse = false
    init(name: String) { self.name = name }
    var system: Bool { sysID != 0 }
    var display: Bool { dispID != 0 }

    func set(system s: Bool, display d: Bool) {
        sysID = flip(sysID, on: s, type: kIOPMAssertPreventUserIdleSystemSleep)
        dispID = flip(dispID, on: d, type: kIOPMAssertPreventUserIdleDisplaySleep)
    }

    private func flip(_ id: IOPMAssertionID, on: Bool, type: String) -> IOPMAssertionID {
        if !on { if id != 0 { IOPMAssertionRelease(id) }; return 0 }
        if id != 0 { return id }
        if refuse { return 0 }
        var n: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &n)
        return r == kIOReturnSuccess ? n : 0
    }

    /// このプロセスがいま出している宣言の種類（確かめる用）
    static func mine() -> [String] {
        var d: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&d) == kIOReturnSuccess, let dict = d?.takeRetainedValue() as NSDictionary? else { return [] }
        let list = dict[NSNumber(value: getpid())] as? [[String: Any]] ?? []
        return list.compactMap { $0["AssertType"] as? String }
    }
}

struct Power: Equatable {
    var onBattery: Bool
    var percent: Int?

    static func read() -> Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return Power(onBattery: false, percent: nil) }
        let src = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var pct: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                   let cur = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                    pct = cur * 100 / mx
                }
            }
        }
        return Power(onBattery: src == kIOPMBatteryPowerKey, percent: pct)
    }

    /// 電池で動いていて、残りが limit% 以下（limit 0 は「なし」）
    func low(limit: Int) -> Bool { limit > 0 && onBattery && (percent ?? 100) <= limit }
}

/// 通算の記録（UserDefaults）。途中で落ちても失うのは最後の数秒だけ。
/// 見回りの間が maxGap より空いたら、その間は眠っていた（または止まっていた）とみなして数えない
final class Stats {
    let d: UserDefaults
    static let maxGap: TimeInterval = 60
    private var last: Date?
    private var counted: TimeInterval = 0
    init(_ d: UserDefaults) { self.d = d }
    var total: TimeInterval { d.double(forKey: "statTotal") }
    var count: Int { d.integer(forKey: "statCount") }
    var longest: TimeInterval { d.double(forKey: "statLongest") }

    func begin(_ now: Date) { d.set(count + 1, forKey: "statCount"); last = now; counted = 0 }
    func tick(_ now: Date) {
        guard let l = last else { return }
        let gap = now.timeIntervalSince(l)
        if gap > 0 && gap <= Stats.maxGap {
            d.set(total + gap, forKey: "statTotal")
            counted += gap
            d.set(max(longest, counted), forKey: "statLongest")
        }
        // 時計が戻ったときも、その時刻から数え直す
        if gap != 0 { last = now }
    }
    /// 数えずに、起点だけ進める（宣言が出せていない間）
    func skip(_ now: Date) { if last != nil { last = now } }
    /// 眠る直前：そこまでを数え、復帰後は復帰の時刻から数え直す
    func pause(_ now: Date) { tick(now); last = nil }
    func resume(_ now: Date) { if last == nil && counting { last = now } }
    private var counting = false
    func finish(_ now: Date) { tick(now); last = nil; counting = false }
    func started() { counting = true }
}

/// 同じ役目のアプリ（同時に動くと二重になる）
enum Others {
    static let known: [String: String] = [
        "com.if.Amphetamine": "Amphetamine",
        "info.marcel-dierkes.KeepingYouAwake": "KeepingYouAwake",
        "com.lightheadsw.caffeine": "Caffeine",
        "com.intelliscapesolutions.caffeine": "Caffeine",
        "com.sindresorhus.Lungo": "Lungo",
    ]
    static func names(_ ids: [String]) -> [String] { Array(Set(ids.compactMap { known[$0] })).sorted() }
    static func running() -> [String] { names(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }) }
}

enum Look: Equatable { case asleep, system, display }
enum Reason: Equatable { case user, timeUp, battery }

/// 起きている／眠れるの本体
final class Core {
    let keeper: Keeper
    let stats: Stats
    let d: UserDefaults
    private(set) var session: Session?
    /// 最後に止まった理由（復帰時に開始するかの判断に使う）
    private(set) var lastEnd: Reason?
    private var wasLow = false
    private var lastPower = Power(onBattery: false, percent: nil)
    var onChange: (() -> Void)?

    init(defaults: UserDefaults, name: String = "TsumikiWake") {
        d = defaults
        d.register(defaults: ["display": true, "startAtLaunch": true, "startOnWake": true,
                              "batteryLimit": 10, "hotkey": true, "defaultMinutes": 0])
        keeper = Keeper(name: name)
        stats = Stats(defaults)
    }

    /// 起動時に電源を1回読んでおく（起動時にもう低かったら、それは「なった瞬間」ではない）
    func prime(_ p: Power) { lastPower = p; wasLow = p.low(limit: batteryLimit) }

    /// 起動時：「起動時に開始」でも、電池が低いときは始めない（自動の開始は復帰と同じ扱い）。始めたら true
    @discardableResult
    func launch(power: Power, now: Date = Date()) -> Bool {
        prime(power)
        guard startAtLaunch, !power.low(limit: batteryLimit) else { onChange?(); return false }
        toggle(now: now); return true
    }

    var awake: Bool { session != nil }
    /// 始めたのに宣言が出せなかった
    var failed: Bool { session != nil && !keeper.system }
    var look: Look { (session == nil || !keeper.system) ? .asleep : (keeper.display ? .display : .system) }

    var display: Bool { get { d.bool(forKey: "display") } set { d.set(newValue, forKey: "display"); apply() } }
    var startAtLaunch: Bool { get { d.bool(forKey: "startAtLaunch") } set { d.set(newValue, forKey: "startAtLaunch") } }
    var startOnWake: Bool { get { d.bool(forKey: "startOnWake") } set { d.set(newValue, forKey: "startOnWake") } }
    var hotkey: Bool { get { d.bool(forKey: "hotkey") } set { d.set(newValue, forKey: "hotkey") } }
    /// 電池がこの%以下で終える（0＝なし）。変えたときに既に低くても、すぐには止めない
    var batteryLimit: Int {
        get { d.integer(forKey: "batteryLimit") }
        set { d.set(newValue, forKey: "batteryLimit"); wasLow = lastPower.low(limit: newValue) }
    }
    /// 右クリック・ショートカット・起動時の開始の長さ（0＝無期限）
    var defaultMinutes: Int { get { d.integer(forKey: "defaultMinutes") } set { d.set(newValue, forKey: "defaultMinutes") } }

    /// 始める（動いているときは長さだけ変える）。minutes nil＝無期限
    func start(minutes: Int?, now: Date = Date()) {
        begin(end: minutes.map { now.addingTimeInterval(Double($0) * 60) }, plan: minutes ?? 0, now: now)
    }
    func start(until: Date, now: Date = Date()) { begin(end: until, plan: -1, now: now) }

    private func begin(end: Date?, plan: Int, now: Date) {
        if let s = session { stats.tick(now); session = Session(start: s.start, end: end, plan: plan) }
        else { stats.begin(now); stats.started(); session = Session(start: now, end: end, plan: plan) }
        // 低いまま手で始めたら、それは尊重する（次に「なった瞬間」まで止めない）
        wasLow = lastPower.low(limit: batteryLimit)
        lastEnd = nil
        apply()
    }

    func extend(minutes: Int, now: Date = Date()) {
        guard var s = session, let e = s.end else { return }
        s.end = max(e, now).addingTimeInterval(Double(minutes) * 60)
        s.plan = -1
        session = s; apply()
    }

    @discardableResult
    func stop(now: Date = Date(), reason: Reason = .user) -> Bool {
        guard session != nil else { return false }
        stats.finish(now); session = nil; lastEnd = reason; apply(); return true
    }

    func toggle(now: Date = Date()) {
        if awake { stop(now: now) } else { start(minutes: defaultMinutes == 0 ? nil : defaultMinutes, now: now) }
    }

    /// 定期の見回り。終えたらその理由を返す
    func tick(now: Date = Date(), power: Power) -> Reason? {
        lastPower = power
        let low = power.low(limit: batteryLimit)
        defer { wasLow = low }
        guard let s = session else { return nil }
        if let e = s.end, s.expired(at: now) {
            // 期限を過ぎた分は数えない
            stop(now: min(now, e), reason: .timeUp); return .timeUp
        }
        // 宣言が出せていなければ出し直す。出せない間は起きている時間に数えない
        let had = keeper.system
        if !had { apply() }
        if had { stats.tick(now) } else { stats.skip(now) }
        // 低くなった瞬間だけ終える
        if low && !wasLow { stop(now: now, reason: .battery); return .battery }
        return nil
    }

    func willSleep(now: Date = Date()) { if awake { stats.pause(now) } }

    /// 復帰：見回りをしてから、「復帰時に開始」なら始める。
    /// ただし時間切れ・電池で止まったあと、電池が低いままのときは始めない
    func didWake(now: Date = Date(), power: Power) -> Reason? {
        stats.resume(now)
        let r = tick(now: now, power: power)
        if !awake && startOnWake && r == nil && lastEnd != .timeUp && lastEnd != .battery && !power.low(limit: batteryLimit) {
            toggle(now: now)
        }
        return r
    }

    func apply() {
        keeper.set(system: session != nil, display: session != nil && display)
        onChange?()
    }
}
