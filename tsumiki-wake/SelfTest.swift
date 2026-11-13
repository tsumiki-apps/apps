// `--selftest`：画面を出さずに中身を確かめる。設定は使い捨ての置き場（UserDefaults の別の名前）に書き、終わったら消す。
// 眠らせない宣言は本物を数秒だけ出して、出ていること・消えることを確かめる（電源の設定は触らない）。
import AppKit

enum SelfTest {
    static var ok = true
    static func check(_ name: String, _ cond: Bool, _ note: String = "") {
        print("\(cond ? "✓" : "✗") \(name)\(note.isEmpty ? "" : "（\(note)）")")
        if !cond { ok = false }
    }

    static func run() -> Bool {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. 時間の計算
        let s = Session(start: t0, end: t0.addingTimeInterval(3600))
        check("残り1時間", s.remaining(at: t0) == 3600)
        check("時間ちょうどで終わり", s.expired(at: t0.addingTimeInterval(3600)) && !s.expired(at: t0.addingTimeInterval(3599)))
        check("無期限は終わらない", !Session(start: t0, end: nil).expired(at: t0.addingTimeInterval(1e9)))
        check("表記：45分", Fmt.remain(45 * 60) == "45分", Fmt.remain(45 * 60))
        check("表記：1:05", Fmt.remain(65 * 60) == "1:05", Fmt.remain(65 * 60))
        check("表記：端数は切り上げ", Fmt.remain(61) == "2分", Fmt.remain(61))
        check("表記：2日3時間", Fmt.remain((51 * 60) * 60) == "2日3時間", Fmt.remain(51 * 3600))
        check("通算：8,187時間", Fmt.total(8187 * 3600 + 5) == "8,187時間", Fmt.total(8187 * 3600))

        // 2. 「時刻まで」
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let ten = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0))!
        let n1 = When.next(hour: 11, minute: 30, after: ten, cal: cal)
        check("後の時刻は今日", n1.timeIntervalSince(ten) == 90 * 60)
        let n2 = When.next(hour: 9, minute: 30, after: ten, cal: cal)
        check("過ぎた時刻は明日", n2.timeIntervalSince(ten) == (23 * 60 + 30) * 60)
        check("今ちょうどは明日", When.next(hour: 10, minute: 0, after: ten, cal: cal).timeIntervalSince(ten) == 86400)

        // 3. 電池
        check("電源につながっていれば止めない", !Power(onBattery: false, percent: 3).low(limit: 10))
        check("電池10%で止める", Power(onBattery: true, percent: 10).low(limit: 10))
        check("電池11%では止めない", !Power(onBattery: true, percent: 11).low(limit: 10))
        check("「なし」なら止めない", !Power(onBattery: true, percent: 1).low(limit: 0))
        check("電池の値が読めないときは止めない", !Power(onBattery: true, percent: nil).low(limit: 10))
        let p = Power.read()
        print("・この Mac の電源：電池で動作=\(p.onBattery) 残り=\(p.percent.map { "\($0)%" } ?? "なし")")

        // 4. ほかの起こすアプリ
        check("同じ役目のアプリを見つける", Others.names(["com.apple.finder", "com.if.Amphetamine"]) == ["Amphetamine"])
        check("関係ないアプリは数えない", Others.names(["com.apple.Safari"]).isEmpty)

        // 5. 本体（使い捨ての設定で）
        let suite = "com.tsumiki.wake.selftest.\(getpid())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let ac = Power(onBattery: false, percent: 100)
        let core = Core(defaults: d, name: "TsumikiWake selftest")
        check("既定：画面も・起動時に開始・復帰時に開始・電池10%・ショートカット・無期限",
              core.display && core.startAtLaunch && core.startOnWake && core.batteryLimit == 10 && core.hotkey && core.defaultMinutes == 0)
        check("最初は眠れる", core.look == .asleep && Keeper.mine().isEmpty, Keeper.mine().joined(separator: ","))

        core.start(minutes: nil, now: t0)
        var mine = Keeper.mine()
        check("開始で本体と画面の宣言が出る", mine.contains(kIOPMAssertPreventUserIdleSystemSleep) && mine.contains(kIOPMAssertPreventUserIdleDisplaySleep), mine.joined(separator: ","))
        check("アイコンは「画面も」", core.look == .display && !core.failed)
        core.display = false
        mine = Keeper.mine()
        check("画面を外すと画面の宣言だけ消える", mine.contains(kIOPMAssertPreventUserIdleSystemSleep) && !mine.contains(kIOPMAssertPreventUserIdleDisplaySleep), mine.joined(separator: ","))
        check("アイコンは「起きている」", core.look == .system)
        core.display = true

        // 記録：10秒ごとの見回りは数える。間が空いた（眠っていた）分は数えない
        var t = t0
        for _ in 0..<6 { t = t.addingTimeInterval(10); _ = core.tick(now: t, power: ac) }
        check("見回りの間を足す", abs(core.stats.total - 60) < 0.01, "\(core.stats.total)秒")
        t = t.addingTimeInterval(8 * 3600)
        check("無期限は見回りで止まらない", core.tick(now: t, power: ac) == nil && core.awake)
        check("8時間空いた分は数えない", abs(core.stats.total - 60) < 0.01, "\(core.stats.total)秒")
        core.willSleep(now: t.addingTimeInterval(5))
        _ = core.didWake(now: t.addingTimeInterval(3600), power: ac)
        _ = core.tick(now: t.addingTimeInterval(3610), power: ac)
        check("眠る前と復帰後だけ数える", abs(core.stats.total - 75) < 0.01, "\(core.stats.total)秒")

        core.start(minutes: 30, now: t)
        check("動いている間に時間を変えても回数は増えない", core.stats.count == 1, "\(core.stats.count)")
        check("選んだ長さにチェック", core.session?.plan == 30)
        core.extend(minutes: 15, now: t)
        check("15分延長", core.session?.end == t.addingTimeInterval(45 * 60))
        // 期限の20秒前に見回り → 眠って2時間後に復帰：時間切れ。期限を過ぎた分は数えない・復帰で始め直さない
        let before = core.stats.total
        _ = core.tick(now: t.addingTimeInterval(45 * 60 - 20), power: ac)
        let r = core.didWake(now: t.addingTimeInterval(3 * 3600), power: ac)
        check("眠っている間の時間切れは、復帰で止まったまま", r == .timeUp && !core.awake, "\(String(describing: r))")
        check("期限を過ぎた分は数えない", core.stats.total - before < 30, "\(core.stats.total - before)秒")
        check("止めたら宣言が全部消える", Keeper.mine().isEmpty, Keeper.mine().joined(separator: ","))
        check("最長は眠っていた時間を含まない", core.stats.longest < 3600, "\(Int(core.stats.longest))秒")

        // 手で止めてから眠った → 復帰で始まる（復帰時に開始）
        core.start(minutes: nil, now: t)
        core.stop(now: t)
        _ = core.didWake(now: t.addingTimeInterval(60), power: ac)
        check("手で止めた後は、復帰で始まる", core.awake)
        core.stop(now: t.addingTimeInterval(60))

        // 電池：低くなった瞬間だけ止める。低いまま手で始めたら止めない
        let t1 = t0.addingTimeInterval(2e6)
        core.prime(Power(onBattery: true, percent: 50))
        core.start(minutes: nil, now: t1)
        check("電池が十分なら続く", core.tick(now: t1, power: Power(onBattery: true, percent: 50)) == nil && core.awake)
        check("10%になったら止まる", core.tick(now: t1.addingTimeInterval(10), power: Power(onBattery: true, percent: 10)) == .battery && !core.awake)
        _ = core.didWake(now: t1.addingTimeInterval(600), power: Power(onBattery: true, percent: 9))
        check("電池で止まった後は、復帰で始め直さない", !core.awake)
        core.start(minutes: nil, now: t1.addingTimeInterval(620))
        check("低いまま手で始めたら続く", core.tick(now: t1.addingTimeInterval(630), power: Power(onBattery: true, percent: 9)) == nil && core.awake)
        core.stop(now: t1.addingTimeInterval(640))

        // 起動時にもう低い：「起動時に開始」でも始めない。そのあと手で始めたら尊重する
        let d2s = suite + ".2"; let d2 = UserDefaults(suiteName: d2s)!
        defer { d2.removePersistentDomain(forName: d2s) }
        let core2 = Core(defaults: d2, name: "TsumikiWake selftest 2")
        check("起動時に電池が低ければ始めない", !core2.launch(power: Power(onBattery: true, percent: 5), now: t1) && !core2.awake && Keeper.mine().isEmpty)
        check("起動時に電池が十分なら始める", {
            let ok = core2.launch(power: Power(onBattery: true, percent: 80), now: t1)
            core2.stop(now: t1); return ok
        }())
        core2.prime(Power(onBattery: true, percent: 5))
        core2.toggle(now: t1)
        check("低いまま手で始めたら、すぐには止めない", core2.tick(now: t1.addingTimeInterval(10), power: Power(onBattery: true, percent: 5)) == nil && core2.awake)
        // 上限を後から上げた：その時点でもう低くても、すぐには止めない
        core2.batteryLimit = 30
        check("上限を変えても、すぐには止めない", core2.tick(now: t1.addingTimeInterval(20), power: Power(onBattery: true, percent: 5)) == nil && core2.awake)
        core2.stop(now: t1.addingTimeInterval(30))
        check("電源につなぐと、ふたたび低くなった瞬間に止まる", {
            core2.start(minutes: nil, now: t1.addingTimeInterval(40))
            _ = core2.tick(now: t1.addingTimeInterval(50), power: Power(onBattery: false, percent: 5))
            return core2.tick(now: t1.addingTimeInterval(60), power: Power(onBattery: true, percent: 5)) == .battery
        }())

        core.toggle(now: t1)
        check("切り替えで始める・止める", core.awake && { core.toggle(now: t1); return !core.awake && Keeper.mine().isEmpty }())
        core.defaultMinutes = 60
        core.toggle(now: t1)
        check("切り替えで始めると既定の長さ", core.session?.end == t1.addingTimeInterval(3600) && core.session?.plan == 60)
        core.stop(now: t1)
        check("回数", core.stats.count == 7, "\(core.stats.count)回")

        // 時間切れの数えかた（別の記録で）
        let d3s = suite + ".3"; let d3 = UserDefaults(suiteName: d3s)!
        defer { d3.removePersistentDomain(forName: d3s) }
        let core3 = Core(defaults: d3, name: "TsumikiWake selftest 3")
        let t3 = t0.addingTimeInterval(4e6)
        core3.start(minutes: 15, now: t3)
        let e3 = t3.addingTimeInterval(15 * 60)
        _ = core3.tick(now: e3.addingTimeInterval(-20), power: ac)
        let b3 = core3.stats.total
        check("期限の後の見回りでは、期限までの分だけ数える", core3.tick(now: e3.addingTimeInterval(5), power: ac) == .timeUp && abs(core3.stats.total - b3 - 20) < 0.01, "\(core3.stats.total - b3)秒")
        // 眠る→期限の後に復帰：眠る前までだけ数える
        core3.start(minutes: 15, now: t3)
        let b4 = core3.stats.total
        _ = core3.tick(now: t3.addingTimeInterval(30), power: ac)
        core3.willSleep(now: t3.addingTimeInterval(40))
        let r3 = core3.didWake(now: t3.addingTimeInterval(3600), power: ac)
        check("眠る→期限の後に復帰：眠る前までだけ数える", r3 == .timeUp && !core3.awake && abs(core3.stats.total - b4 - 40) < 0.01, "\(core3.stats.total - b4)秒")
        check("最長は眠っていた時間を含まない（期限の後の復帰）", core3.stats.longest <= 900, "\(Int(core3.stats.longest))秒")
        // 時計が戻った：戻った時刻から数え直す
        core3.start(minutes: nil, now: t3)
        _ = core3.tick(now: t3.addingTimeInterval(-3600), power: ac)
        let b5 = core3.stats.total
        _ = core3.tick(now: t3.addingTimeInterval(-3590), power: ac)
        check("時計が戻っても数え続ける", abs(core3.stats.total - b5 - 10) < 0.01, "\(core3.stats.total - b5)秒")
        core3.stop(now: t3.addingTimeInterval(-3590))
        // 宣言が出せない：数えない・見回りで出し直す
        core3.keeper.refuse = true
        core3.start(minutes: nil, now: t3)
        check("宣言が出せなければ「失敗」の表示", core3.failed && core3.look == .asleep && Keeper.mine().isEmpty)
        let b6 = core3.stats.total
        _ = core3.tick(now: t3.addingTimeInterval(10), power: ac)
        check("宣言が出せない間は数えない", core3.stats.total == b6, "\(core3.stats.total - b6)秒")
        core3.keeper.refuse = false
        _ = core3.tick(now: t3.addingTimeInterval(20), power: ac)
        check("見回りで宣言を出し直す", !core3.failed && Keeper.mine().contains(kIOPMAssertPreventUserIdleSystemSleep) && core3.stats.total == b6, "\(core3.stats.total - b6)秒")
        _ = core3.tick(now: t3.addingTimeInterval(30), power: ac)
        check("出し直した後は数える", abs(core3.stats.total - b6 - 10) < 0.01, "\(core3.stats.total - b6)秒")
        core3.stop(now: t3.addingTimeInterval(30))
        check("止めたら宣言が全部消える（出し直しの後）", Keeper.mine().isEmpty)

        // 6. アイコン
        let a = AppIcon.menuPixels(.asleep), b = AppIcon.menuPixels(.system), c = AppIcon.menuPixels(.display)
        check("メニューのアイコンが描ける", a.count > 100 && b.count > a.count && c.count > b.count, "\(a.count)・\(b.count)・\(c.count)画素")
        check("3通りの見た目が違う", a.data != b.data && b.data != c.data)
        // 積み木の部分は「起きている」と「画面も」で同じ（光の線だけ足す）＝状態が変わっても跳ねない
        let size = 72, cubeTop = Int(0.72 * 39)
        let same = (cubeTop..<size).allSatisfy { y in (0..<size).allSatisfy { x in b.data[y * size + x] == c.data[y * size + x] } }
        check("光の線は積み木に重ならない", same)
        check("アプリのアイコン（PNG）", AppIcon.png(64).count > 500)

        print(ok ? "自己テスト OK" : "自己テスト ✗ あり")
        return ok
    }

    /// 確かめる用：メニューのアイコン3通りを大きく描いた PNG を書き出す
    static func writeMenuIcons(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (look, name) in [(Look.asleep, "眠れる"), (.system, "起きている"), (.display, "画面も")] {
            let size = 180
            let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)
            AppIcon.drawMenu(ctx, look)
            let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
