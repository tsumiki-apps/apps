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
        let marks: [Mark] = [.mosaic(mos), .arrow(CGPoint(x: 300, y: 300), CGPoint(x: 420, y: 220)),
                             .box(CGRect(x: 40, y: 400, width: 200, height: 120)), .text(CGPoint(x: 60, y: 540), "ここ")]
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
        e.canvas.marks = marks
        e.tools.selectedSegment = 1
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
        func autoRun(sign: Int, horizontal: Bool) -> (Bool, String) {
            let body = SelfTest.makeBody(height: 2400)
            let mid = SelfTest.viewH - SelfTest.header - SelfTest.footer
            let maxOff = body.height - mid
            let st = AutoStitcher()
            let pilot = AutoPilot(viewLength: CGFloat(horizontal ? SelfTest.viewH : SelfTest.viewH))
            var off = 0, n = 0, turns = 0
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
            let want = SelfTest.header + body.height + SelfTest.footer
            let ok = next == .finish && len == want && st.axis == (horizontal ? .horizontal : .vertical)
            return (ok, "\(len)px（正解 \(want)）・\(n)回・向きの試し直し \(turns)回")
        }
        let r1 = autoRun(sign: 1, horizontal: false); check("自動スクロール：縦・ふつうの向きで端まで", r1.0, r1.1)
        let r2 = autoRun(sign: -1, horizontal: false); check("自動スクロール：縦・合図が逆向きでも端まで", r2.0, r2.1)
        let r3 = autoRun(sign: 1, horizontal: true); check("自動スクロール：横で端まで", r3.0, r3.1)
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
        let s3 = Shortcuts.combo(3)
        let cleared = Shortcuts.set(1, s3)                       // 範囲に、スクロールと同じキー
        check("同じキーは片方だけ（もう片方はなしに）", cleared == [3] && Shortcuts.combo(3) == nil && Shortcuts.combo(1) == s3)
        Shortcuts.set(2, nil)
        check("なしにできる", Shortcuts.combo(2) == nil)
        Shortcuts.resetAll()
        check("既定に戻す", Shortcuts.actions.allSatisfy { Shortcuts.combo($0.id) == $0.def })
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
