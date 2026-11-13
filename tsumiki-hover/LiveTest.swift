// `--livetest`：本物の窓で確かめる（アクセシビリティの許可が要る。カーソルは動かさない）。
//   子プロセスを2つ立てて窓を出す：B（窓2枚）→ A（大きい窓1枚で B の2枚に重なる）。
//   ① A1 を前に出す → A1 がいちばん前・A が最前面のアプリ
//   ② B1 を前に出す → B1 がいちばん前・B が最前面。B2 は A1 の後ろのまま（その窓だけが出る）
//   ③ Brain に本物の画面を流す（カーソルの位置だけ架空）→ 待ち時間のあと A1 を選ぶ
//   `--dummy <名前> x y w h [x y w h…]`：子プロセス側。左上原点で窓を出し、20秒で消える
import AppKit

enum Dummy {
    static func run(_ args: [String]) -> Never {
        let name = args[0]
        let nums = args.dropFirst().compactMap { Double($0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let h = NSScreen.screens.first?.frame.height ?? 900
        var wins: [NSWindow] = []
        for i in stride(from: 0, to: nums.count - 3, by: 4) {
            let r = NSRect(x: nums[i], y: h - nums[i + 1] - nums[i + 3], width: nums[i + 2], height: nums[i + 3])
            let w = NSWindow(contentRect: r, styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "\(name)\(i / 4 + 1)"
            w.isReleasedWhenClosed = false
            w.orderFrontRegardless()
            wins.append(w)
        }
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
        app.run()
        exit(0)
    }
}

enum LiveTest {
    static func run() -> Int32 {
        var ng = 0
        func check(_ ok: Bool, _ s: String) { print(ok ? "✓" : "✗", s); if !ok { ng += 1 } }
        guard AXIsProcessTrusted() else { print("✗ アクセシビリティの許可がない"); return 1 }
        let me = CommandLine.arguments[0]
        func spawn(_ a: [String]) -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: me); p.arguments = ["--dummy"] + a
            try! p.run(); return p
        }
        func wait(_ cond: () -> Bool) -> Bool {
            for _ in 0..<60 { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return false
        }
        let b = spawn(["B", "300", "260", "420", "300", "760", "300", "420", "300", "560", "420", "420", "300"])
        defer { b.terminate() }
        _ = wait { Screen.windows().filter { $0.pid == b.processIdentifier && $0.layer == 0 }.count == 3 }
        let a = spawn(["A", "200", "200", "1100", "520"])
        defer { a.terminate() }
        _ = wait { Screen.windows().contains { $0.pid == a.processIdentifier && $0.layer == 0 } }
        usleep(300_000)
        func order() -> [Win] { Screen.windows().filter { $0.layer == 0 } }
        func idx(_ id: CGWindowID) -> Int { order().firstIndex { $0.id == id } ?? 9999 }
        let bw = Screen.windows().filter { $0.pid == b.processIdentifier && $0.layer == 0 }.sorted { $0.bounds.minX < $1.bounds.minX }
        guard let a1 = Screen.windows().first(where: { $0.pid == a.processIdentifier && $0.layer == 0 }), bw.count == 3 else {
            print("✗ 試験の窓が出なかった"); return 1
        }
        let b1 = bw[0], b2 = bw[2], b3 = bw[1]
        func front() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }

        // ①
        check(Raiser.raise(a1, at: nil), "① A1 を前に出す命令が通る")
        check(wait { order().first?.id == a1.id }, "① A1 がいちばん前")
        check(wait { front() == a.processIdentifier }, "① A が最前面のアプリ")
        // ②
        let t0 = Date()
        check(Raiser.raise(b1, at: nil), "② B1 を前に出す命令が通る")
        check(wait { order().first?.id == b1.id }, "② B1 がいちばん前（\(Int(Date().timeIntervalSince(t0) * 1000))ms）")
        check(wait { front() == b.processIdentifier }, "② B が最前面のアプリ")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(idx(b2.id) > idx(a1.id), "② B2 は A1 の後ろのまま（その窓だけが出る）")
        check(idx(b3.id) > idx(a1.id), "② B3 も A1 の後ろのまま（3枚目も）")
        if ng > 0 { print("  並び:", order().prefix(5).map { w in w.id == a1.id ? "A1" : w.id == b1.id ? "B1" : w.id == b2.id ? "B2" : "他\(w.pid)" }, "前:", front() == a.processIdentifier ? "A" : front() == b.processIdentifier ? "B" : NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") }
        // ③ Brain：B1 が前にいる状態で、A1 だけが見えている所（右下）にカーソルがあることにする
        let brain = Brain(selfPid: getpid()); brain.delay = 0.05
        let p = CGPoint(x: 1250, y: 650)
        func snap(_ t: TimeInterval) -> Snapshot {
            var s = Screen.snapshot(now: t); s.mouse = p; s.controlDown = false; s.buttonsDown = false; s.topEdge = false; return s
        }
        let r0 = brain.step(snap(0))
        check(r0.0 == .waiting, "③ 入った直後は待つ（\(r0.0.rawValue)）")
        let r1 = brain.step(snap(0.06))
        check(r1.0 == .raise && r1.1?.id == a1.id, "③ 50ms 後に A1 を選ぶ（\(r1.0.rawValue)）")
        if let w = r1.1 { Raiser.raise(w, at: p) }
        check(wait { order().first?.id == a1.id && front() == a.processIdentifier }, "③ A1 が前に出て A が最前面")
        let r2 = brain.step(snap(2))
        check(r2.0 == .alreadyFront, "③ 出たあとは何もしない（\(r2.0.rawValue)）")
        print(ng == 0 ? "LIVE OK" : "LIVE NG \(ng)")
        return ng == 0 ? 0 : 1
    }
}
