// `--selftest`：架空の縦長ページを作り、窓の位置をずらしたコマを Stitcher に流して確かめる。
// 確かめること：①各コマの判定が期待どおりの並びか（継げるのに × にしていないか）
//               ②できあがりが正解と1画素も違わないか（つなぎ間違いがないか）
// 画面の許可は要らない。
import AppKit
import CoreText

enum SelfTest {
    static let W = 480, viewH = 600, header = 56, footer = 40

    enum Look { case light, dark, sparse, periodic }

    /// 本体（ヘッダー・フッターの間に流れる中身）を描く。決定論＝毎回同じ絵。
    static func makeBody(height: Int, look: Look = .light) -> CGImage {
        let ctx = CGContext(data: nil, width: W, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dark = look == .dark
        ctx.setFillColor(dark ? CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                              : CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: height))
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 15, nil)
        let ink = dark ? CGColor(gray: 0.88, alpha: 1) : CGColor(gray: 0.15, alpha: 1)
        func text(_ s: String, x: Int, y: Int) {
            let attr = NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink])
            ctx.textPosition = CGPoint(x: x, y: height - y - 16)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        var y = 12, i = 0
        let words = ["見積", "納品", "請求", "在庫", "予約", "会計", "日報", "手配"]
        while y < height - 30 {
            i += 1
            switch look {
            case .periodic:                       // 同じ行が52画素ごとに繰り返す
                text("同じ行 ■■■ 1234", x: 18, y: y); y += 52; continue
            case .sparse:                         // ほとんど空白
                text("\(i). \(words[i % words.count]) \(i * 7919 % 10007)", x: 18 + (i % 5) * 9, y: y); y += 230; continue
            default: break
            }
            let gap = (i % 7 == 0) ? 70 : 26
            if i % 11 == 0 {
                ctx.setFillColor(CGColor(red: 0.69, green: 0.44, blue: 0.15, alpha: 1))
                ctx.fill(CGRect(x: 16, y: height - y - 60, width: 120 + (i * 37) % 300, height: 54))
                y += 70; continue
            }
            text("\(i). \(words[i % words.count])の行 \(String(repeating: "■", count: i % 9)) \(i * 7919 % 10007)",
                 x: 18 + (i % 5) * 6, y: y)
            y += gap
        }
        return ctx.makeImage()!
    }

    struct Noise { var scrollbar = false; var hover = false }

    /// 本体の offset 行目から見た1コマ（ヘッダー・フッター・飾りつき）
    static func frame(body: CGImage, offset: Int, header hdr: Int = header, footer ftr: Int = footer,
                      noise: Noise = Noise()) -> CGImage {
        let ctx = CGContext(data: nil, width: W, height: viewH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let mid = viewH - hdr - ftr
        let part = body.cropping(to: CGRect(x: 0, y: offset, width: W, height: mid))!
        ctx.draw(part, in: CGRect(x: 0, y: ftr, width: W, height: mid))
        if noise.hover {                          // 一部だけ色が変わる（ホバーの強調）
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 0.25))
            ctx.fill(CGRect(x: 0, y: viewH - hdr - 150, width: W, height: 40))
        }
        if noise.scrollbar {                      // 右端のスクロールバー（位置が動く）
            let thumb = 80, track = mid - thumb
            let pos = min(track, offset * track / 3400)
            ctx.setFillColor(CGColor(gray: 0.45, alpha: 0.8))
            ctx.fill(CGRect(x: W - 12, y: ftr + mid - thumb - pos, width: 7, height: thumb))
        }
        if hdr > 0 {
            ctx.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1))
            ctx.fill(CGRect(x: 0, y: viewH - hdr, width: W, height: hdr))
            ctx.setFillColor(CGColor(red: 0.84, green: 0.6, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 16, y: viewH - hdr + 18, width: 90, height: 20))
        }
        if ftr > 0 {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.88, blue: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: ftr))
            ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
            ctx.fill(CGRect(x: W / 2 - 20, y: 12, width: 40, height: 16))
        }
        return ctx.makeImage()!
    }

    static func scaled(_ img: CGImage, _ k: Int) -> CGImage {
        guard k > 1 else { return img }
        let c = CGContext(data: nil, width: img.width * k, height: img.height * k, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .none
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width * k, height: img.height * k))
        return c.makeImage()!
    }

    static func pixels(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }

    struct Case {
        let name: String
        let offsets: [Int]
        let expect: String           // 期待する判定の並び（始 +n 止 × 満）
        var header = SelfTest.header, footer = SelfTest.footer
        var look = Look.light
        var scale = 1
        var noiseAt: (Int) -> Noise = { _ in Noise() }
        var maxPixels = 160_000_000
        var ignoreRight = 0          // 画素比較で右端を見ない幅（スクロールバーの写り込み）
        var horizontal = false       // 横スクロール：コマを左に90°回して流す（ヘッダー→左のサイドバー）
    }

    static func symbol(_ r: StepResult, scale: Int) -> String {
        switch r { case .first: return "始"; case .added(let n): return "+\(n / scale)"
        case .still: return "止"; case .lost: return "×"; case .full: return "満" }
    }

    static func run(outDir: String?) -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        let cases = [
            Case(name: "ふつう（固定ヘッダー・フッターあり）", offsets: [0, 37, 120, 121, 260, 410, 410, 655, 900, 1180, 1500, 1820],
                 expect: "始 +37 +83 +1 +139 +150 止 +245 +245 +280 +320 +320"),
            Case(name: "途中で戻る・止まる", offsets: [0, 200, 120, 80, 200, 330, 330, 330, 520, 700],
                 expect: "始 +200 × × 止 +130 止 止 +190 +180"),
            Case(name: "速すぎて途切れる", offsets: [0, 150, 300, 1200, 1350], expect: "始 +150 +150 × ×"),
            Case(name: "固定帯なし", offsets: [0, 90, 250, 251, 500, 760, 1010], expect: "始 +90 +160 +1 +249 +260 +250",
                 header: 0, footer: 0),
            Case(name: "1行ずつ細かく", offsets: Array(stride(from: 0, through: 60, by: 3)),
                 expect: "始" + String(repeating: " +3", count: 20)),
            Case(name: "ダークモード", offsets: [0, 50, 180, 400, 640], expect: "始 +50 +130 +220 +240", look: .dark),
            Case(name: "Retina（2倍）", offsets: [0, 45, 200, 420, 700], expect: "始 +45 +155 +220 +280", scale: 2),
            Case(name: "スクロール前のホバー（固定帯を誤確定しない）", offsets: [0, 0, 0, 60, 200, 380],
                 expect: "始 止 止 +60 +140 +180", noiseAt: { i in Noise(hover: i == 1) }),
            Case(name: "右端のスクロールバー", offsets: [0, 70, 200, 390, 600, 820], expect: "始 +70 +130 +190 +210 +220",
                 noiseAt: { _ in Noise(scrollbar: true) }, ignoreRight: 16),
            Case(name: "同じ行の繰り返し（決められない＝継がない）", offsets: [0, 20, 45, 70], expect: "始 × × ×", look: .periodic),
            Case(name: "ほとんど空白（ゆっくりなら継げる）", offsets: [0, 60, 150, 240, 330, 420], expect: "始 +60 +90 +90 +90 +90", look: .sparse),
            Case(name: "上限で止まる", offsets: [0, 200, 400, 600], expect: "始 +200 満 満", maxPixels: 480 * 900),
            Case(name: "横：左右に固定サイドバー", offsets: [0, 37, 120, 121, 260, 410, 410, 655, 900, 1180, 1500, 1820],
                 expect: "始 +37 +83 +1 +139 +150 止 +245 +245 +280 +320 +320", horizontal: true),
            Case(name: "横：途中で戻る・止まる", offsets: [0, 200, 120, 80, 200, 330, 330, 330, 520, 700],
                 expect: "始 +200 × × 止 +130 止 止 +190 +180", horizontal: true),
            Case(name: "横：サイドバーなし", offsets: [0, 90, 250, 251, 500, 760, 1010], expect: "始 +90 +160 +1 +249 +260 +250",
                 header: 0, footer: 0, horizontal: true),
            Case(name: "横：Retina（2倍）", offsets: [0, 45, 200, 420, 700], expect: "始 +45 +155 +220 +280", scale: 2, horizontal: true),
            Case(name: "横：ダークモード", offsets: [0, 50, 180, 400, 640], expect: "始 +50 +130 +220 +240", look: .dark, horizontal: true),
        ]
        var allOK = true
        for c in cases {
            let body = makeBody(height: 4000, look: c.look)
            // 縦も横も、本番と同じ「向きを自分で決める」つなぎ手で通す
            let st = AutoStitcher(maxPixels: c.maxPixels * c.scale * c.scale)
            var results: [StepResult] = []
            var reached = 0
            for (i, o) in c.offsets.enumerated() {
                var f = scaled(frame(body: body, offset: o, header: c.header, footer: c.footer, noise: c.noiseAt(i)), c.scale)
                if c.horizontal { f = rotate90(f, clockwise: false)! }
                let r = st.add(f)
                results.append(r)
                if case .added = r { reached = o }
            }
            let steps = results.map { symbol($0, scale: c.scale) }.joined(separator: " ")
            let seqOK = steps == c.expect
            guard let out = st.compose() else { print("✗ \(c.name)：合成できない"); allOK = false; continue }
            // 正解＝本体の 0〜(reached+mid) 行を、ヘッダー（最初のコマ）とフッター（最後に継いだコマ）で挟む
            let mid = viewH - c.header - c.footer
            let expectH = c.header + reached + mid + c.footer
            let ctx = CGContext(data: nil, width: W, height: expectH, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(body.cropping(to: CGRect(x: 0, y: 0, width: W, height: reached + mid))!,
                     in: CGRect(x: 0, y: c.footer, width: W, height: reached + mid))
            let topF = frame(body: body, offset: 0, header: c.header, footer: c.footer)
            let botF = frame(body: body, offset: reached, header: c.header, footer: c.footer)
            if c.header > 0 {
                ctx.draw(topF.cropping(to: CGRect(x: 0, y: 0, width: W, height: c.header))!,
                         in: CGRect(x: 0, y: expectH - c.header, width: W, height: c.header))
            }
            if c.footer > 0 {
                ctx.draw(botF.cropping(to: CGRect(x: 0, y: viewH - c.footer, width: W, height: c.footer))!,
                         in: CGRect(x: 0, y: 0, width: W, height: c.footer))
            }
            var expect = scaled(ctx.makeImage()!, c.scale)
            if c.horizontal { expect = rotate90(expect, clockwise: false)! }
            let wantAxis: ScrollAxis = c.horizontal ? .horizontal : .vertical
            let axisOK = st.axis == nil || st.axis == wantAxis
            var pixOK = out.height == expect.height && out.width == expect.width
            var diffRows = 0
            if pixOK {
                let a = pixels(out), b = pixels(expect)
                let rowBytes = expect.width * 4, cmp = (expect.width - (c.horizontal ? 0 : c.ignoreRight * c.scale)) * 4
                for y in 0..<expect.height {
                    let r = y * rowBytes
                    if a[r..<(r + cmp)] != b[r..<(r + cmp)] { diffRows += 1 }
                }
                pixOK = diffRows == 0
            }
            let ok = seqOK && pixOK && axisOK
            print("\(ok ? "✓" : "✗") \(c.name)：\(out.width)×\(out.height)（正解 \(expect.width)×\(expect.height)・\(st.axis == .horizontal ? "横" : st.axis == .vertical ? "縦" : "未定")）違う行 \(diffRows)　[\(steps)]"
                  + (seqOK ? "" : "　期待 [\(c.expect)]"))
            if let dir = outDir, !ok {
                save(out, to: "\(dir)/\(c.name)_結果.png"); save(expect, to: "\(dir)/\(c.name)_正解.png")
            }
            allOK = allOK && ok
        }
        return allOK
    }

    static func save(_ img: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
