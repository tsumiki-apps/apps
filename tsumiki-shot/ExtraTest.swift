// `--extratest [出力先フォルダ]`：書き込み（焼き込み）・文字の読み取り・編集画面を、画面収録の許可なしで確かめる。
import AppKit
import AVFoundation
import Carbon

enum ExtraTest {
    static func run(outDir: String?) -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var ok = true
        func check(_ name: String, _ cond: Bool, _ note: String = "") {
            print("\(cond ? "✓" : "✗") \(name)\(note.isEmpty ? "" : "：\(note)")")
            if !cond { ok = false }
        }
        let dir = outDir ?? NSTemporaryDirectory()

        // 1. 焼き込み
        let base = SelfTest.makeBody(height: 600)
        let W = base.width
        let unit: CGFloat = 2
        let mos = CGRect(x: 20, y: 30, width: 240, height: 112)
        let marks: [Mark] = [Mark(.mosaic(mos)), Mark(.arrow(CGPoint(x: 300, y: 300), CGPoint(x: 420, y: 220))),
                             Mark(.box(CGRect(x: 40, y: 400, width: 200, height: 120))), Mark(.text(CGPoint(x: 60, y: 540), "ここ"))]
        guard let flat = Annotate.flatten(base, marks, unit: unit) else { check("焼き込み", false); return false }
        SelfTest.save(flat, to: dir + "/焼き込み.png")
        let a = SelfTest.pixels(base), b = SelfTest.pixels(flat)
        func px(_ p: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * W + x) * 4; return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) }
        func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 110 && c.2 < 110 }
        func colors(_ p: [UInt8], _ r: CGRect) -> Int {
            var set = Set<UInt32>()
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
                let c = px(p, x, y); set.insert(UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2)) } }
            return set.count
        }
        let cells = (Int(mos.width) / 16) * (Int(mos.height) / 16)
        let before = colors(a, mos), after = colors(b, mos)
        check("モザイク：元の細かさが消える", after <= cells && before > cells, "色の数 \(before) → \(after)（マス \(cells)）")
        check("矢印の先が赤", isRed(px(b, 416, 223)))
        check("四角の線が赤", isRed(px(b, 140, 400)) && isRed(px(b, 40, 460)))
        check("四角の中は元のまま", px(a, 140, 460) == px(b, 140, 460))
        var redInText = 0
        for y in 540..<580 { for x in 60..<140 where isRed(px(b, x, y)) { redInText += 1 } }
        check("文字が描かれる", redInText > 80, "赤い画素 \(redInText)")
        check("書き込みの外は元のまま", px(a, W - 5, 590) == px(b, W - 5, 590) && px(a, 5, 5) == px(b, 5, 5))

        drawingTests(base, unit: unit, dir: dir, check)

        // 2. 文字の読み取り
        let lines = ["つみきショットで文字を読む", "Scroll capture 2026"]
        let tw = 900, th = 200
        let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: NSPoint(x: 30, y: th - 80 - i * 80),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let t0 = Date()
        let got = OCR.read(ctx.makeImage()!)
        let norm = { (s: String) in s.replacingOccurrences(of: " ", with: "").lowercased() }
        let gotLines = got.split(separator: "\n").map { norm(String($0)) }
        check("文字の読み取り（日本語・英語・行の順）", gotLines == lines.map(norm),
              "「\(got.replacingOccurrences(of: "\n", with: " / "))」\(String(format: "%.1f", Date().timeIntervalSince(t0)))秒")

        // 3. 編集画面（描いて確かめる）
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let shot = base.cropping(to: CGRect(x: 0, y: 0, width: W, height: 600))!
        let e = EditorWindow(image: shot, url: URL(fileURLWithPath: "/tmp/スクショ 見本.png"), unit: 1)
        e.canvas.marks = marks + [Mark(.number(CGPoint(x: 400, y: 60), 1)), Mark(.number(CGPoint(x: 400, y: 110), 2)),
                                  Mark(.marker([CGPoint(x: 20, y: 248), CGPoint(x: 230, y: 248)]), color: 2),
                                  Mark(.oval(CGRect(x: 290, y: 400, width: 150, height: 70)), color: 4),
                                  Mark(.pen([CGPoint(x: 300, y: 500), CGPoint(x: 330, y: 530), CGPoint(x: 360, y: 505), CGPoint(x: 400, y: 540)]), color: 3)]
        e.choose(.arrow)
        if let v = e.window?.contentView {
            e.window?.appearance = NSAppearance(named: .darkAqua)
            v.wantsLayer = true
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            v.layoutSubtreeIfNeeded()
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            SelfTest.save(rep.cgImage!, to: dir + "/編集画面.png")
            check("編集画面を描ける", rep.pixelsWide > 0)
            // 背景（余白・角丸・影）とスポットを付けた見本
            var bg = Backdrop(); bg.on = true; bg.fill = 1; bg.pad = 40
            e.canvas.backdrop = bg
            e.canvas.marks = [Mark(.spot(CGRect(x: 20, y: 150, width: 300, height: 120))), Mark(.number(CGPoint(x: 330, y: 160), 1)),
                              Mark(.arrow(CGPoint(x: 420, y: 330), CGPoint(x: 330, y: 230)))]
            e.choose(.spot)
            v.layoutSubtreeIfNeeded()
            let rep2 = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep2)
            SelfTest.save(rep2.cgImage!, to: dir + "/編集画面_背景.png")
            check("編集画面：背景を付けても窓の幅からはみ出さない", e.canvas.frame.width <= v.bounds.width + 1, "")

            // キー：⌘Z＝戻す・⇧⌘Z＝やり直す（窓に届いたキーで確かめる）
            func key(_ ch: String, _ mods: NSEvent.ModifierFlags) -> Bool {
                guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                windowNumber: e.window?.windowNumber ?? 0, context: nil, characters: ch,
                                                charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 6) else { return false }
                return e.window?.performKeyEquivalent(with: ev) ?? false
            }
            let n0 = e.canvas.marks.count
            e.canvas.add(Mark(.box(CGRect(x: 10, y: 10, width: 50, height: 50))))
            e.canvas.add(Mark(.box(CGRect(x: 80, y: 10, width: 50, height: 50))))
            _ = key("z", .command)
            check("キー：⌘Z で1つ戻す", e.canvas.marks.count == n0 + 1, "\(e.canvas.marks.count - n0)")
            _ = key("Z", [.command, .shift])
            check("キー：⇧⌘Z でやり直す（戻すにならない）", e.canvas.marks.count == n0 + 2, "\(e.canvas.marks.count - n0)")
            _ = key("z", .command); _ = key("z", .command)
            _ = key("z", [.command, .shift])
            check("キー：⇧⌘Z（小文字で届いても）やり直す", e.canvas.marks.count == n0 + 1, "\(e.canvas.marks.count - n0)")
        }

        // 4. 録画の書き出し（作りものの30コマ/秒×1.5秒 → MP4）
        let mv = URL(fileURLWithPath: dir + "/録画テスト.mp4")
        try? FileManager.default.removeItem(at: mv)
        if let w = try? MovieWriter(url: mv, width: 641, height: 361) {
            for i in 0..<45 {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pb)
                CVPixelBufferLockBaseAddress(pb!, [])
                let p = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb!)
                for y in 0..<360 { for x in 0..<640 { let o = y * bpr + x * 4
                    let on = x / 40 == i % 16
                    p[o] = on ? 60 : 240; p[o + 1] = on ? 150 : 240; p[o + 2] = on ? 210 : 240; p[o + 3] = 255 } }
                CVPixelBufferUnlockBaseAddress(pb!, [])
                // 本物は1/30秒おきに来る＝書き手の手が空くまで待ってから渡す（速すぎるコマは捨てる作り）
                if i > 0 { var n = 0; while !w.input.isReadyForMoreMediaData && n < 2000 { usleep(1000); n += 1 } }
                w.append(pb!, at: CMTime(value: CMTimeValue(1000 + i), timescale: 30))
            }
            let sem = DispatchSemaphore(value: 0)
            var done = false
            w.finish(end: CMTime(value: 1000 + 60, timescale: 30)) { ok in done = ok; sem.signal() }
            sem.wait()
            let asset = AVURLAsset(url: mv)
            let dur = CMTimeGetSeconds(asset.duration)
            let size = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
            check("録画の書き出し（MP4）", done && w.frames == 45 && abs(dur - 2.0) < 0.05 && size == CGSize(width: 640, height: 360),
                  "\(w.frames)コマ・\(String(format: "%.2f", dur))秒（止めた時刻まで）・\(Int(size.width))×\(Int(size.height))")
        } else { check("録画の書き出し（MP4）", false, "書き手を作れない") }

        // 5. ピン
        let pinP = makePin(shot, unit: 1) { _ in }
        if let v = pinP.contentView {
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            check("ピンを描ける", rep.pixelsWide > 0 && v.bounds.width > 40, "\(Int(v.bounds.width))×\(Int(v.bounds.height))")
        }

        // 7. 自動スクロール：本物のつなぎ手に、送った量だけ動く架空のページを見せて、端まで行って止まるか
        func autoRun(sign: Int, horizontal: Bool, start: Int = 0) -> (Bool, String) {
            let body = SelfTest.makeBody(height: 2400)
            let mid = SelfTest.viewH - SelfTest.header - SelfTest.footer
            let maxOff = body.height - mid
            let st = AutoStitcher()
            let pilot = AutoPilot(viewLength: CGFloat(horizontal ? SelfTest.viewH : SelfTest.viewH))
            var off = start, n = 0, turns = 0
            func shot() -> CGImage {
                let f = SelfTest.frame(body: body, offset: off)
                return horizontal ? rotate90(f, clockwise: false)! : f
            }
            _ = st.add(shot())
            var next = pilot.begin()
            while n < 200 {
                n += 1
                guard case let .scroll(dx, dy) = next else { break }
                // 合図の向き：sign＝-1 ならナチュラルのように逆。横は dx が効く
                let amount = horizontal ? dx : dy
                off = min(maxOff, max(0, off - sign * amount))
                let r = st.add(shot())
                if let a = st.axis { pilot.axisDecided(a) }
                let before = pilot.dirIndex
                next = pilot.next(after: r)
                if pilot.dirIndex != before { turns += 1 }
            }
            guard let out = st.compose() else { return (false, "合成できない") }
            let len = horizontal ? out.width : out.height
            let want = SelfTest.header + body.height - start + SelfTest.footer     // 途中から始めたら、そこから下
            let ok = next == .finish && len == want && st.axis == (horizontal ? .horizontal : .vertical)
            return (ok, "\(len)px（正解 \(want)）・\(n)回・向きの試し直し \(turns)回")
        }
        // 本物に近いページ：合図を受けても3コマかけて滑らかに動き、読み込んだ所の端に来ると1.5秒後に続きを読み込む
        // （1コマ＝0.12秒。合図の間合いは AutoDriver が決める。前の作り＝1コマごとに送る、では 1100px・1.1秒で止まっていた）
        func realRun(loadWait: Double = 1.5, start: Int = 0, sign: Int = 1) -> (Bool, String) {
            let body = SelfTest.makeBody(height: 2400)
            let mid = SelfTest.viewH - SelfTest.header - SelfTest.footer
            let maxOff = body.height - mid
            var loaded = min(maxOff, start + 500)  // いま読み込んである所まで
            var reachedAt: Double? = nil
            let st = AutoStitcher()
            st.force(.vertical)                    // 札で「縦」を選んだ
            let driver = AutoDriver(pilot: AutoPilot(viewLength: CGFloat(SelfTest.viewH)))
            var off = start, pending = 0, t = 0.0, n = 0, sent = 0
            _ = st.add(SelfTest.frame(body: body, offset: off))
            var next = driver.begin(now: t)
            if case let .scroll(_, dy) = next { pending -= sign * dy; sent += abs(dy) }
            while n < 600 {
                n += 1; t += 0.12
                // ページの動き：残りの1/3ずつ（滑らか）
                let mv = pending == 0 ? 0 : (abs(pending) <= 3 ? pending : pending / 3)
                pending -= mv
                off = min(loaded, max(0, off + mv))
                if off >= loaded, loaded < maxOff { if reachedAt == nil { reachedAt = t } ; pending = 0 }
                if let r0 = reachedAt, t - r0 >= loadWait { loaded = min(maxOff, loaded + 500); reachedAt = nil }
                let r = st.add(SelfTest.frame(body: body, offset: off))
                if let a = st.axis { driver.pilot.axisDecided(a) }
                guard let nx = driver.frame(r, now: t) else { continue }
                next = nx
                guard case let .scroll(_, dy) = next else { break }
                pending -= sign * dy; sent += abs(dy)
            }
            let out = st.compose()
            let len = out?.height ?? 0
            let want = SelfTest.header + body.height - start + SelfTest.footer
            let speed = Int(Double(sent) / max(t, 0.01))
            // 速さ：1秒に画面の高さの6割まで（前の作りは毎秒 1500点）
            return (next == .finish && len == want && Double(sent) / t <= 0.6 * Double(SelfTest.viewH), "\(len)px（正解 \(want)）・\(String(format: "%.1f", t))秒・合図 \(speed)点/秒")
        }
        let rr = realRun(); check("自動スクロール：滑らかに動き・続きを読み込むページでも端まで", rr.0, rr.1)
        let rr5 = realRun(start: 700, sign: -1); check("自動スクロール：滑らかに動くページの途中から・合図が逆向き（ナチュラル）でも端まで", rr5.0, rr5.1)
        let rr4 = realRun(loadWait: 4.0); check("自動スクロール：続きの読み込みに4秒かかっても端まで", rr4.0, rr4.1)
        // 縦を選んだのに全く動かない範囲（合図が届かない・短いページ）でも、いつまでも送り続けずに終わる
        do {
            let d = AutoDriver(pilot: AutoPilot(viewLength: 600))
            d.pilot.axisDecided(.vertical)
            var t = 0.0, nx: AutoPilot.Next? = d.begin(now: 0), sideways = false
            while t < 60, nx != .finish {
                t += 0.12
                d.pilot.axisDecided(.vertical)
                if let n = d.frame(.still, now: t) { nx = n; if case let .scroll(dx, _) = n, dx != 0 { sideways = true } }
            }
            check("自動スクロール：縦で動かなければ終わる（横へは送らない）", nx == .finish && !sideways && t < 10, String(format: "%.1f秒", t))
        }
        // 1回の間合いの中で「継いだ→見失った」なら、最後の「見失った」で送りすぎと判断する
        do {
            let d = AutoDriver(pilot: AutoPilot(viewLength: 600))
            _ = d.begin(now: 0)
            _ = d.frame(.added(40), now: 0.2); _ = d.frame(.lost, now: 0.4)
            let n = d.frame(.still, now: 0.7)
            check("自動スクロール：継いだあと見失ったら戻して半分に", n == .scroll(dx: 0, dy: 90) && d.pilot.step == 90, "\(String(describing: n))")
        }
        // 滑らか：送った分にほぼ追いついて流れているなら、止まるのを待たずに間合いで次を送る（止まっては動く、にしない）
        do {
            let d = AutoDriver(pilot: AutoPilot(viewLength: 600), scale: 2)
            guard case let .scroll(_, dy0) = d.begin(now: 0) else { check("滑らか：最初の合図", false); return false }
            var t = 0.0, sent: Double? = nil
            while t < 1.4, sent == nil {        // 1/60秒ずつ流れる＝送った量（点）を画素で少しずつ継ぐ
                t += 0.12
                if let n = d.frame(.added(Int(Double(abs(dy0)) * 2 * 0.12 / AutoDriver.gap)), now: t) { if case .scroll = n { sent = t } }
            }
            check("滑らか：流れていれば止まるのを待たずに次を送る", sent != nil && sent! < AutoDriver.gap + 0.25, sent.map { String(format: "%.2f秒", $0) } ?? "送らない")
            let d2 = AutoDriver(pilot: AutoPilot(viewLength: 600), scale: 2)
            _ = d2.begin(now: 0)
            var t2 = 0.0, sent2: Double? = nil
            while t2 < 1.6, sent2 == nil {      // 送った分よりずっと少ししか動かない（まだ慣性で動いている）
                t2 += 0.12
                if let n = d2.frame(.added(4), now: t2) { if case .scroll = n { sent2 = t2 } }
            }
            check("滑らか：追いついていなければ今までどおり止まるのを待つ", sent2 == nil || sent2! >= AutoDriver.settle, sent2.map { String(format: "%.2f秒", $0) } ?? "待つ")
        }
        // 左下の見本：細く縮めて、新しい所（縦は下端・横は右端）を上限の長さまで見せる
        do {
            let body = SelfTest.makeBody(height: 3000)
            let st = Stitcher()
            let lp = LivePreview(screen: NSScreen.main ?? NSScreen.screens[0], horizontal: false, scale: 2)
            var img = lp.reset(SelfTest.frame(body: body, offset: 0))
            _ = st.add(SelfTest.frame(body: body, offset: 0))
            var ok = img != nil && img!.width == 300
            for k in 1...12 {
                if case .added = st.add(SelfTest.frame(body: body, offset: k * 180)), let s = st.lastStrip { img = lp.add(head: st.head, strip: s) }
            }
            ok = ok && img != nil && img!.width == 300 && img!.height == 480
            let lh = LivePreview(screen: NSScreen.main ?? NSScreen.screens[0], horizontal: true, scale: 1)
            let ih = lh.reset(SelfTest.frame(body: body, offset: 0))
            check("左下の見本：縦は幅150点・長い所は240点で切る／横は横長", ok && ih != nil && ih!.height == 150, "\(img?.width ?? 0)×\(img?.height ?? 0)・横 \(ih?.width ?? 0)×\(ih?.height ?? 0)")
        }
        let r1 = autoRun(sign: 1, horizontal: false); check("自動スクロール：縦・ふつうの向きで端まで", r1.0, r1.1)
        let r2 = autoRun(sign: -1, horizontal: false); check("自動スクロール：縦・合図が逆向きでも端まで", r2.0, r2.1)
        let r3 = autoRun(sign: 1, horizontal: true); check("自動スクロール：横で端まで", r3.0, r3.1)
        // ページの途中から自動を始める（逆向きだと端で「動かない」にならず、戻る＝前は「見失った」で1画面だけになっていた）
        let r5 = autoRun(sign: -1, horizontal: false, start: 700); check("自動スクロール：途中から・合図が逆向き（ナチュラル）でも端まで", r5.0, r5.1)
        let r6 = autoRun(sign: 1, horizontal: false, start: 700); check("自動スクロール：途中から・ふつうの向きで端まで", r6.0, r6.1)
        let r7 = autoRun(sign: -1, horizontal: true, start: 700); check("自動スクロール：途中から・横で合図が逆向きでも端まで", r7.0, r7.1)
        // 戻った（.back）ら、まだ継いでいなければすぐ同じ軸の逆向きへ。継いだ後の戻りでは切り替えない
        do {
            let p = AutoPilot(viewLength: 600); p.axisDecided(.vertical)
            _ = p.begin()
            let n1 = p.next(after: .back(180))
            let n2 = p.next(after: .back(60))           // 出発点へ戻る途中＝もう切り替えない
            check("自動スクロール：戻ったら逆向きに切り替え（戻る途中では切り替えない）", n1 == .scroll(dx: 0, dy: 180) && n2 == .scroll(dx: 0, dy: 180) && p.dirIndex == 1 && p.turns == 1, "\(n1) \(n2)")
            let q = AutoPilot(viewLength: 600); q.axisDecided(.vertical)
            _ = q.begin(); _ = q.next(after: .added(180))
            let m = q.next(after: .back(30))
            check("自動スクロール：継いだ後の戻りでは向きを変えない", q.dirIndex == 0 && m == .scroll(dx: 0, dy: -180), "\(m)")
            // 戻ったとも言えず「見失った」が続く（逆向きに動いた先が模様の少ない所など）→ 2回で逆向きへ
            let l = AutoPilot(viewLength: 600); l.axisDecided(.vertical)
            _ = l.begin(); _ = l.next(after: .lost)
            let ln = l.next(after: .lost)
            check("自動スクロール：継ぐ前に見失いが2回続いたら逆向きへ（戻して半分にしない）", l.dirIndex == 1 && ln == .scroll(dx: 0, dy: 180), "\(ln)")
            // 「戻った」の誤検知で逆にしても、逆で継げなければ1回だけ元の向きに戻す（その後は終える）
            let g = AutoPilot(viewLength: 600); g.axisDecided(.vertical)
            _ = g.begin()
            _ = g.next(after: .back(40))                // 誤検知で逆へ（grace＝1）
            var k = 0, nx = AutoPilot.Next.scroll(dx: 0, dy: 0)
            while g.dirIndex == 1, k < 20 { nx = g.next(after: .back(100)); k += 1 }
            let backToA = g.dirIndex == 0 && nx == .scroll(dx: 0, dy: -180)
            var e = 0, end = AutoPilot.Next.scroll(dx: 0, dy: 0)
            while end != .finish, e < 30 { end = g.next(after: .still); e += 1 }
            check("自動スクロール：誤って逆にしても元の向きに戻し、それでも動かなければ終える", backToA && k == 4 && end == .finish && e <= 10, "戻すまで\(k)回・終えるまで\(e)回")
            // いちばん下から始めた（下は動かない→上へ）。上で「戻った」が出ても、試し済みの下には戻らず終える
            let d = AutoPilot(viewLength: 600); d.axisDecided(.vertical)
            _ = d.begin()
            for _ in 0..<3 { _ = d.next(after: .still) }
            let up = d.dirIndex
            var f = 0, fe = AutoPilot.Next.scroll(dx: 0, dy: 0)
            while fe != .finish, f < 30 { fe = d.next(after: .back(150)); f += 1 }
            check("自動スクロール：下端から始めて上が戻るだけなら終える（行ったり来たりしない）", up == 1 && fe == .finish && d.dirIndex == 1 && f <= 4, "\(f)回")
        }
        // 重さ：前にも後ろにも合わないコマ（速すぎ）は、逆向きも探す分だけ重い。Retina の大きな範囲（約2.7倍）で1コマの時間を測る
        do {
            let body = SelfTest.makeBody(height: 6000)
            func big(_ off: Int) -> CGImage {
                let f = SelfTest.frame(body: body, offset: off)
                let W = f.width * 8 / 3, H = f.height * 8 / 3
                let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.interpolationQuality = .high
                c.draw(f, in: CGRect(x: 0, y: 0, width: W, height: H))
                return c.makeImage()!
            }
            let st = Stitcher()
            _ = st.add(big(0)); _ = st.add(big(100))       // 固定帯を決める
            let frames = [big(1500), big(2600), big(3700)]   // どれも前と重ならない＝見失う
            let t0 = CACurrentMediaTime()
            var rs: [StepResult] = []
            for f in frames { rs.append(st.add(f)) }
            let ms = (CACurrentMediaTime() - t0) / Double(frames.count) * 1000
            check("重さ：見失うコマ（逆向きも探す）1枚 \(frames[0].width)×\(frames[0].height)", rs.allSatisfy { $0 == .lost } && ms < 400, String(format: "%.0f ms", ms))
            let ok = big(200)
            let t1 = CACurrentMediaTime(); let ra = st.add(ok); _ = ra
            check("重さ：継げるコマ 1枚（比べる目安）", true, String(format: "%.0f ms", (CACurrentMediaTime() - t1) * 1000))
        }
        // 手で逆に回したときは「戻」と出す（前は「×」＝札が「ゆっくり」になり、逆向きだと分からなかった）
        do {
            let body = SelfTest.makeBody(height: 2400)
            let st = Stitcher()
            _ = st.add(SelfTest.frame(body: body, offset: 600))
            let r = st.add(SelfTest.frame(body: body, offset: 450))
            let r2 = st.add(SelfTest.frame(body: body, offset: 800))
            check("手動：上へ戻すと「戻」・進み直せば続きから継ぐ", { if case .back(150) = r { return true }; return false }() && r2 == .added(200), "\(r) \(r2)")
        }
        // 送りすぎ（×）のあとは戻して半分に
        let pl = AutoPilot(viewLength: 600)
        _ = pl.begin(); _ = pl.next(after: .added(180))
        let back = pl.next(after: .lost)
        check("自動スクロール：送りすぎたら少し戻して半分に", back == .scroll(dx: 0, dy: 90) && pl.step == 90, "\(back)")

        // 8. ショートカット
        let k = KeyCombo.from(code: UInt16(kVK_ANSI_K), flags: [.command, .shift], chars: "k")
        check("キーの表示", k?.display == "⇧⌘K" && k?.menuKey.0 == "k", k?.display ?? "nil")
        check("修飾キーなしは受けない（F キーは可）", KeyCombo.from(code: UInt16(kVK_ANSI_K), flags: [], chars: "k") == nil
              && KeyCombo.from(code: UInt16(kVK_F5), flags: [], chars: nil)?.display == "F5")
        let suite = "tsumikishot.selftest"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        let keep = Shortcuts.defaults
        Shortcuts.defaults = ud
        // 既定は CleanShot X と同じ並び（App Store 版は ⌥ が足される）
        let want: [UInt32: Int] = [2: kVK_ANSI_3, 1: kVK_ANSI_4, 3: kVK_ANSI_5, 6: kVK_ANSI_6, 7: kVK_ANSI_7, 4: kVK_ANSI_8, 5: kVK_ANSI_2]
        check("既定のキー＝CleanShot X の並び（3 全画面・4 範囲・5 スクロール・6 録画・7 注釈）",
              want.allSatisfy { id, code in Shortcuts.combo(id).map { $0.code == UInt32(code) && $0.mods == Shortcuts.cmdShift } == true },
              Shortcuts.actions.map { "\($0.name)=\(Shortcuts.combo($0.id)?.display ?? "なし")" }.joined(separator: " "))
        let defs = Shortcuts.actions.map { "\($0.def.code)-\($0.def.mods)" }
        check("既定のキーに重なりがない", Set(defs).count == defs.count)
        // 前の版の既定（スクロール＝⇧⌘6）を保存している人：新しい既定の録画（⇧⌘6）は「なし」にして重ねない
        ud.set(["3": try! JSONEncoder().encode(KeyCombo(code: UInt32(kVK_ANSI_6), mods: Shortcuts.cmdShift, char: "6"))], forKey: "hotkeys")
        check("前の版の保存キーと新しい既定を重ねない", Shortcuts.combo(6) == nil && Shortcuts.combo(3)?.code == UInt32(kVK_ANSI_6))
        Shortcuts.resetAll()
        let s3 = Shortcuts.combo(3)
        let cleared = Shortcuts.set(1, s3)                       // 範囲に、スクロールと同じキー
        check("同じキーは片方だけ（もう片方はなしに）", cleared == [3] && Shortcuts.combo(3) == nil && Shortcuts.combo(1) == s3)
        Shortcuts.set(2, nil)
        check("なしにできる", Shortcuts.combo(2) == nil)
        Shortcuts.resetAll()
        check("既定に戻す", Shortcuts.actions.allSatisfy { Shortcuts.combo($0.id) == $0.def })
        // 注釈（⇧⌘7）が開くのは、保存先でいちばん新しい画像（動画は飛ばす）
        let td = FileManager.default.temporaryDirectory.appendingPathComponent("tsumikishot-annotate-\(getpid())")
        try? FileManager.default.createDirectory(at: td, withIntermediateDirectories: true)
        let fm = FileManager.default
        for (n, ago) in [("古い.png", 300.0), ("新しい.png", 100.0), ("録画.mp4", 10.0)] {
            let u = td.appendingPathComponent(n)
            fm.createFile(atPath: u.path, contents: Data([0]))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: u.path)
        }
        let latest = App.latestImage(in: td)
        check("注釈：いちばん新しい画像を選ぶ（動画は除く）", latest?.lastPathComponent == "新しい.png", latest?.lastPathComponent ?? "nil")
        let empty = td.appendingPathComponent("空"); try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        check("注釈：画像が無ければ nil（＝選ぶ画面へ）", App.latestImage(in: empty) == nil)
        // 写真の向き（EXIF 6＝右に90°）は起こして読む・向きの無い画像はそのまま
        do {
            let c = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            let im = c.makeImage()!
            func make(_ o: Int?) -> CGImage? {
                let data = NSMutableData()
                guard let dst = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(dst, im, o.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
                CGImageDestinationFinalize(dst)
                return CGImageSourceCreateWithData(data, nil).flatMap { App.loadUpright($0) }
            }
            let rot = make(6), plain = make(nil)
            check("注釈：写真の向きを起こして読む", rot?.width == 20 && rot?.height == 40 && plain?.width == 40 && plain?.height == 20,
                  "\(rot?.width ?? 0)×\(rot?.height ?? 0)")
        }
        try? fm.removeItem(at: td)
        // ウィンドウ選びは Enter（とテンキーの Enter）で撮る・Esc でやめる
        let wpv = WindowPickView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        var keysHeard: [String] = []
        if let rep = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 36) {
            let w2 = WindowPickView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)); var n = 0
            w2.onEnter = { n += 1 }; w2.keyDown(with: rep)
            check("ウィンドウ選び：Enter の押しっぱなし（連打）は撮らない", n == 0)
        }
        wpv.onEnter = { keysHeard.append("enter") }; wpv.onCancel = { keysHeard.append("cancel") }; wpv.onClick = { keysHeard.append("click") }
        for code: UInt16 in [36, 76, 53] {
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) { wpv.keyDown(with: ev) }
        }
        check("ウィンドウ選び：Enter で撮る・Esc でやめる", keysHeard == ["enter", "enter", "cancel"], keysHeard.joined(separator: ","))
        // 範囲選びは、ドラッグ前の Enter で画面まるごと（ドラッグ中は効かない）
        let sv = SelectView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), tracking: true)
        var enters = 0
        sv.onEnter = { enters += 1 }
        func press(_ v: NSView, _ code: UInt16) {
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) { v.keyDown(with: ev) }
        }
        press(sv, 36); press(sv, 76)
        sv.start = NSPoint(x: 1, y: 1)
        press(sv, 36)
        check("範囲選び：ドラッグ前の Enter で画面まるごと・ドラッグ中は効かない", enters == 2, "\(enters)")
        let f = ShortcutField(id: 4)
        var heard: KeyCombo?? = .none
        f.onChange = { heard = .some($0) }
        f.handle(code: UInt16(kVK_Escape), flags: [], chars: nil)
        let escOK = heard == nil
        f.handle(code: UInt16(kVK_Delete), flags: [], chars: nil)
        check("覚える欄：esc はやめる・delete はなし", escOK && heard == .some(nil))
        let sw = SettingsWindow()
        sw.window?.appearance = NSAppearance(named: .darkAqua)
        if let v = sw.window?.contentView {
            v.wantsLayer = true
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            v.layoutSubtreeIfNeeded()
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            SelfTest.save(rep.cgImage!, to: dir + "/設定.png")
            check("設定の窓を描ける", rep.pixelsWide > 200, "\(Int(v.bounds.width))×\(Int(v.bounds.height))")
        }
        #if !APPSTORE   // App Store 版は Mac 標準のキーを書き換えない（setEnabled は何もしない）
        // Mac 標準のキー（本物は触らず、別の名前の置き場で）
        let realDomain = SystemKeys.domain
        SystemKeys.domain = "tsumikishot.selftest.symbolichotkeys" as CFString; SystemKeys.applyNow = false
        let fresh = SystemKeys.anyEnabled                                  // 何も書かれていない＝Mac の既定＝有効
        SystemKeys.setEnabled(false)
        let off = !SystemKeys.anyEnabled && SystemKeys.activeCombos.isEmpty
        let noWarn = !SystemKeys.clashes(Shortcuts.actions[0].def)
        SystemKeys.setEnabled(true)
        // Mac 標準と重なるのは ⇧⌘4 範囲・⇧⌘3 全画面・⇧⌘5 スクロール。⇧⌘6 録画は重ならない
        func def(_ id: UInt32) -> KeyCombo { Shortcuts.actions.first { $0.id == id }!.def }
        let warn = [1, 2, 3].allSatisfy { SystemKeys.clashes(def(UInt32($0))) } && !SystemKeys.clashes(def(6))
        let restored = SystemKeys.isEnabled("28") && SystemKeys.isEnabled("184")
        // 元から止めていた ⌃⇧⌘3 は、止める→戻すのあとも止めたまま
        var tb = CFPreferencesCopyValue("AppleSymbolicHotKeys" as CFString, SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as! [String: Any]
        var e29 = tb["29"] as! [String: Any]; e29["enabled"] = false; tb["29"] = e29
        // ⇧⌘4 をシステム設定で ⌥⌘4 に変えていたら、⇧⌘4 は重ならない
        var e30 = tb["30"] as! [String: Any]; e30["value"] = ["parameters": [52, 21, 0x180000], "type": "standard"]; tb["30"] = e30
        CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, tb as CFDictionary, SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        SystemKeys.setEnabled(false); SystemKeys.setEnabled(true)
        let kept = !SystemKeys.isEnabled("29") && SystemKeys.isEnabled("31")
        let moved = !SystemKeys.clashes(Shortcuts.actions[0].def)
            && SystemKeys.clashes(KeyCombo(code: UInt32(kVK_ANSI_4), mods: UInt32(cmdKey | optionKey), char: "4"))
        CFPreferencesSetValue("AppleSymbolicHotKeys" as CFString, nil, SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(SystemKeys.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        SystemKeys.domain = realDomain; SystemKeys.applyNow = true
        check("Mac 標準のキー：既定は有効・止める・重なりに⚠︎・戻す", fresh && off && noWarn && warn && restored)
        check("Mac 標準のキー：元から止めていたものは戻さない・変えたキーを読む", kept && moved, "kept=\(kept) moved=\(moved)")
        #endif

        // 保存先
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tsumikishot-保存先テスト", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let firstDir = saveDir
        SaveFolder.set(tmpDir)
        let chosen = saveDir.standardizedFileURL.path == tmpDir.standardizedFileURL.path
        try? FileManager.default.removeItem(at: tmpDir)
        let gone = saveDir == SaveFolder.standard          // 選んだフォルダが消えたら既定へ
        SaveFolder.set(nil)
        check("保存先を変える・消えたら既定・既定に戻す", firstDir == SaveFolder.standard && chosen && gone && !SaveFolder.isCustom && saveDir == SaveFolder.standard)
        Shortcuts.defaults = keep
        ud.removePersistentDomain(forName: suite)
        // 自己テストの置き場のファイルを残さない
        for n in [suite, "tsumikishot.selftest.symbolichotkeys"] {
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(n).plist"))
        }

        // 9. アイコン
        let icon = NSBitmapImageRep(data: AppIcon.png(64))
        let mid = icon?.colorAt(x: 32, y: 32)
        check("アプリのアイコンを描ける（真ん中は積み木の色）", icon?.pixelsWide == 64 && (mid?.alphaComponent ?? 0) > 0.9)
        let menu = AppIcon.menuImage()
        let mrep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: mrep)
        menu.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36)); NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for yy in 0..<36 { for xx in 0..<36 where (mrep.colorAt(x: xx, y: yy)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        check("メニューバーのアイコン（テンプレート・18pt）", menu.isTemplate && menu.size == NSSize(width: 18, height: 18) && inked > 150 && inked < 900, "塗り \(inked)/1296")

        // 6. 窓の一覧（許可なしでも位置は取れる）
        let ws = onScreenWindows()
        print("・画面に出ている窓：\(ws.count)個")
        return ok
    }
}

// MARK: - 編集の道具（描いた画素と、選ぶ・切り抜き・戻すの動き）
extension ExtraTest {
    static func drawingTests(_ base: CGImage, unit: CGFloat, dir: String, _ check: (String, Bool, String) -> Void) {
        let W = base.width
        let a = SelfTest.pixels(base)
        func px(_ p: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * w + x) * 4; return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
        }
        func near(_ c: (Int, Int, Int, Int), _ hex: UInt32, _ tol: Int = 40) -> Bool {
            abs(c.0 - Int(hex >> 16 & 255)) <= tol && abs(c.1 - Int(hex >> 8 & 255)) <= tol && abs(c.2 - Int(hex & 255)) <= tol
        }
        let marks: [Mark] = [
            Mark(.line(CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 40)), color: 4),
            Mark(.oval(CGRect(x: 280, y: 40, width: 180, height: 100)), color: 3),
            Mark(.fill(CGRect(x: 40, y: 150, width: 100, height: 50)), color: 5),
            Mark(.pen([CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 240), CGPoint(x: 380, y: 200), CGPoint(x: 420, y: 240)]), color: 0, size: 2),
            Mark(.marker([CGPoint(x: 40, y: 300), CGPoint(x: 260, y: 300)]), color: 2),
            Mark(.number(CGPoint(x: 420, y: 300), 7), color: 0),
            Mark(.blur(CGRect(x: 40, y: 380, width: 200, height: 100))),
        ]
        guard let img = Annotate.render(base, marks, unit: unit) else { check("新しい道具の焼き込み", false, ""); return }
        SelfTest.save(img, to: dir + "/新しい道具.png")
        let b = SelfTest.pixels(img)
        check("線（青）", near(px(b, W, 140, 40), 0x0A84FF, 60), "\(px(b, W, 140, 40))")
        check("丸：縁は緑・中は元のまま", near(px(b, W, 280, 90), 0x34C759, 60) && px(a, W, 370, 90) == px(b, W, 370, 90), "")
        check("塗り（墨）", near(px(b, W, 90, 175), 0x1D1A15, 30), "\(px(b, W, 90, 175))")
        check("ペン（太い・なめらか）", px(b, W, 335, 225).0 > 200 && px(b, W, 335, 225).1 < 110, "\(px(b, W, 335, 225))")
        let o = px(a, W, 150, 300), h = px(b, W, 150, 300)
        check("蛍光ペン：透けて黄みが乗る（青が減り赤は残る）", h.2 < o.2 - 40 && h.0 > o.0 - 40 && h.2 > 20, "元 \(o) → \(h)")
        let numEdge = px(b, W, 420 - 22, 300)
        check("番号：赤い丸", numEdge.0 > 200 && numEdge.1 < 110, "\(numEdge)")
        func roughness(_ p: [UInt8], _ r: CGRect) -> Int {
            var s = 0
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<(Int(r.maxX) - 1) {
                let c = px(p, W, x, y), d = px(p, W, x + 1, y); s += abs(c.0 - d.0) + abs(c.1 - d.1) + abs(c.2 - d.2) } }
            return s
        }
        let br = CGRect(x: 44, y: 384, width: 192, height: 92)
        let r0 = roughness(a, br), r1 = roughness(b, br)
        check("ぼかし：細かい模様が消える", r0 > 0 && r1 * 5 < r0, "となりとの差 \(r0) → \(r1)")
        let sp = Annotate.render(base, [Mark(.spot(CGRect(x: 300, y: 380, width: 160, height: 100)))], unit: unit).map { SelfTest.pixels($0) } ?? a
        let out = px(sp, W, 470, 500), outA = px(a, W, 470, 500), inS = px(sp, W, 380, 430)
        check("スポット：外は暗く・中は元のまま", out.0 < outA.0 * 6 / 10 + 4 && inS == px(a, W, 380, 430), "外 \(outA) → \(out)")
        check("書き込みの無い所は元のまま", px(a, W, W - 5, 590) == px(b, W, W - 5, 590), "")

        // 背景（余白・角丸・影）
        var bg = Backdrop(); bg.on = true; bg.pad = 48; bg.fill = 0; bg.round = true; bg.shadow = true
        let pad = Int(48 * unit)
        if let r = Annotate.render(base, [], bg: bg, unit: unit) {
            SelfTest.save(r, to: dir + "/背景.png")
            let p = SelfTest.pixels(r)
            check("背景：余白のぶん大きくなる", r.width == W + 2 * pad && r.height == base.height + 2 * pad, "\(r.width)×\(r.height)")
            check("背景：角は地の色（紙）", near(px(p, r.width, 2, 2), 0xF5F4F0, 12), "\(px(p, r.width, 2, 2))")
            check("背景：画像の真ん中は元のまま", px(p, r.width, pad + W / 2, pad + 300) == px(a, W, W / 2, 300), "")
            let shadowY = pad + base.height + 10
            var flat = bg; flat.shadow = false
            let q = Annotate.render(base, [], bg: flat, unit: unit).map { SelfTest.pixels($0) } ?? p
            let sh = px(p, r.width, pad + W / 2, shadowY), noSh = px(q, r.width, pad + W / 2, shadowY)
            check("背景：下に影が落ちる", sh.0 + 8 < noSh.0, "影あり \(sh)・なし \(noSh)")
        } else { check("背景", false, "作れない") }
        var clear = bg; clear.fill = backdropFills.count - 1; clear.shadow = false
        if let r = Annotate.render(base, [], bg: clear, unit: unit) {
            let p = SelfTest.pixels(r)
            check("背景：透明＋角丸（画像の角が透ける）", px(p, r.width, 2, 2).3 == 0 && px(p, r.width, pad + 1, pad + 1).3 < 40
                  && px(p, r.width, pad + 40, pad + 40).3 == 255, "角 \(px(p, r.width, pad + 1, pad + 1).3)")
        }
        check("背景なしは前と同じ焼き込み", Annotate.flatten(base, marks, unit: unit).map { SelfTest.pixels($0) == b } ?? false, "")

        // 選ぶ・動かす・複製・消す・色を変える・戻す・やり直す
        let cv = CanvasView(base: base, unit: unit, width: 600)
        let arrow = Mark(.arrow(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)))
        let box = Mark(.box(CGRect(x: 50, y: 50, width: 400, height: 300)), color: 4)
        cv.add(box); cv.add(arrow)
        check("選ぶ：線の上を押すと矢印", cv.hitIndex(CGPoint(x: 200, y: 101)) == 1, "")
        check("選ぶ：四角の縁を押すと四角", cv.hitIndex(CGPoint(x: 50, y: 200)) == 0, "")
        check("選ぶ：四角の中（他に無い所）でも四角", cv.hitIndex(CGPoint(x: 200, y: 250)) == 0, "")
        check("選ぶ：何も無い所は無し", cv.hitIndex(CGPoint(x: 470, y: 560)) == nil, "")
        check("矢印キー：何も選んでいなければ動かさない（スクロールに回す）", !cv.nudge(10, 0) && cv.marks[1] == arrow, "")
        cv.tool = .arrow
        cv.selected = 1
        cv.setStyle(color: 2)
        check("描いた直後に色を押しても、描いたものは変わらない", cv.marks[1] == arrow && cv.color == 2, "")
        cv.tool = .select
        cv.nudge(10, 0)
        check("動かす（矢印キー）", cv.marks[1].shape == .arrow(CGPoint(x: 110, y: 100), CGPoint(x: 310, y: 100)), "")
        cv.setStyle(color: 3, size: 2)
        check("選んでいる書き込みの色・太さを変える", cv.marks[1].color == 3 && cv.marks[1].size == 2, "")
        cv.duplicateSelected()
        check("複製（少しずらして上に）", cv.marks.count == 3 && cv.selected == 2, "")
        cv.deleteSelected()
        check("消す", cv.marks.count == 2 && cv.selected == nil, "")
        cv.undo()
        check("戻す：消したのが戻る", cv.marks.count == 3, "")
        cv.undo(); cv.undo()
        check("戻す：色・太さが戻る（位置はそのまま）", cv.marks.count == 2 && cv.marks[1] == Mark(.arrow(CGPoint(x: 110, y: 100), CGPoint(x: 310, y: 100))), "\(cv.marks.count)件")
        cv.undo()
        check("戻す：動かす前に戻る", cv.marks.count == 2 && cv.marks[1] == arrow, "")
        cv.redo()
        check("やり直す", cv.marks[1].shape == .arrow(CGPoint(x: 110, y: 100), CGPoint(x: 310, y: 100)), "")
        cv.add(Mark(.number(CGPoint(x: 500, y: 500), 1))); cv.add(Mark(.number(CGPoint(x: 520, y: 500), 2)))
        check("番号は続きから（3）", cv.nextNumber == 3, "")
        cv.locked = true
        let lockedMarks = cv.marks
        cv.undo(); cv.selected = 0; cv.setStyle(color: 5); cv.nudge(5, 5)
        check("保存中は書き込みが変わらない", cv.marks == lockedMarks, "")
        cv.locked = false; cv.selected = nil

        // モザイク・ぼかしの入れ物は大きさで上限（大きな範囲をドラッグしても溜まらない）
        let hc = HideCache()
        for i in 0..<40 { _ = hc.get("k\(i)") { Annotate.bitmap(2000, 2000, nil)?.makeImage() } }
        check("隠しの入れ物は 256MB まで", hc.byteCount <= HideCache.limit && hc.byteCount > 0, "\(hc.byteCount >> 20)MB")

        // 切り抜き：画像が小さくなり、書き込みも一緒に動く → 戻すで元の大きさ
        let before = cv.marks
        cv.setCrop(CGRect(x: 60, y: 80, width: 400, height: 300))
        cv.applyCrop()
        check("切り抜き：大きさ", cv.base.width == 400 && cv.base.height == 300, "\(cv.base.width)×\(cv.base.height)")
        check("切り抜き：書き込みも一緒に動く", cv.marks[0].shape == .box(CGRect(x: -10, y: -30, width: 400, height: 300)), "")
        let cropOut = Annotate.render(cv.base, [], unit: unit).map { SelfTest.pixels($0) } ?? []
        check("切り抜き：中身は元の同じ所", cropOut.count == 400 * 300 * 4 && px(cropOut, 400, 10, 10) == px(a, W, 70, 90), "")
        cv.undo()
        check("切り抜きを戻す", cv.base.width == W && cv.marks == before, "")
        cv.redo()
        check("切り抜きをやり直す", cv.base.width == 400, "")

        // ペンの1回押し（点）・Shift でまっすぐ
        let dotImg = Annotate.render(base, [Mark(.pen([CGPoint(x: 450, y: 560), CGPoint(x: 450.1, y: 560)]), size: 2)], unit: unit)
        check("ペンの1回押しは点", dotImg.map { px(SelfTest.pixels($0), W, 450, 560).0 > 200 } ?? false, "")
    }
}
