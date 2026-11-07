// `--extratest [出力先フォルダ]`：書き込み（焼き込み）・文字の読み取り・編集画面を、画面収録の許可なしで確かめる。
import AppKit

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

        // 4. 窓の一覧（許可なしでも位置は取れる）
        let ws = onScreenWindows()
        print("・画面に出ている窓：\(ws.count)個")
        return ok
    }
}
