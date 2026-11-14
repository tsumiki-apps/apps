// `--selftest`：架空の縦長ページを作り、窓の位置をずらしたコマを Stitcher に流して確かめる。
// 確かめること：①各コマの判定が期待どおりの並びか（継げるのに × にしていないか）
//               ②できあがりが正解と1画素も違わないか（つなぎ間違いがないか）
// 画面の許可は要らない。
import AppKit
import CoreText

enum SelfTest {
    static let W = 480, viewH = 600, header = 56, footer = 40

    enum Look { case light, dark, sparse, periodic, blankTop, table }

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
        var y = look == .blankTop ? 420 : 12, i = 0     // blankTop＝ページの先頭が白い余白
        let words = ["見積", "納品", "請求", "在庫", "予約", "会計", "日報", "手配"]
        while y < height - 30 {
            i += 1
            switch look {
            case .periodic:                       // 同じ行が52画素ごとに繰り返す
                text("同じ行 ■■■ 1234", x: 18, y: y); y += 52; continue
            case .table:                          // 表：33画素ごとに同じ形の行（罫線・数字だけ違う）
                ctx.setFillColor(CGColor(gray: 0.7, alpha: 1)); ctx.fill(CGRect(x: 0, y: height - y - 21, width: W, height: 1))
                for col in 0..<4 { ctx.fill(CGRect(x: col * 120, y: height - y - 20, width: 1, height: 33))
                    text("\((i * 7919 + col * 104729) % 90000 + 10000)", x: 14 + col * 120, y: y) }
                y += 33; continue
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

    struct Noise {
        var scrollbar = false; var hover = false; var scrollbarLeft = false
        var sidebar = false          // 縦の固定サイドバー（左60画素・項目つき）
        var glass = false            // 透けるヘッダー（下の本文が透けて見える＝スクロールで中身が変わる）
        var band = -1                // 画面の同じ位置で毎コマ中身が変わる帯（動画・広告）。値＝コマ番号
    }

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
        if noise.scrollbarLeft {                  // 左端の濃いバー＝横向きに回すと下端の横スクロールバーになる
            let thumb = 120, track = mid - thumb
            let pos = min(track, offset * track / 3400)
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 0.9))
            ctx.fill(CGRect(x: 3, y: ftr + mid - thumb - pos, width: 12, height: thumb))
        }
        if noise.band >= 0 {
            var r = UInt64(noise.band + 1) &* 0x9E3779B97F4A7C15
            for k in 0..<24 {
                r = r &* 6364136223846793005 &+ 1442695040888963407
                ctx.setFillColor(CGColor(gray: CGFloat(r >> 56) / 255, alpha: 1))
                ctx.fill(CGRect(x: W / 2 + k * 8, y: ftr + 200, width: 8, height: 120))
            }
        }
        if noise.sidebar {
            ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: ftr, width: 60, height: mid))
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
            for k in 0..<(mid / 34) { ctx.fill(CGRect(x: 8, y: ftr + mid - 24 - k * 34, width: 20 + (k * 13) % 30, height: 10)) }
        }
        if hdr > 0 && noise.glass {
            ctx.draw(body.cropping(to: CGRect(x: 0, y: max(0, offset - hdr), width: W, height: hdr))!, in: CGRect(x: 0, y: viewH - hdr, width: W, height: hdr))
            ctx.setFillColor(CGColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 0.4))
            ctx.fill(CGRect(x: 0, y: viewH - hdr, width: W, height: hdr))
        } else if hdr > 0 {
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
        var ignoreLeft = 0           // 同じく左端（横の下端スクロールバー）
        var horizontal = false       // 横スクロール：コマを左に90°回して流す（ヘッダー→左のサイドバー）
        var sizeOnly = false         // 画素は比べず、できあがりの大きさ（＝継いだ量）だけ正解と比べる（飾りが本文に重なる型）
    }

    static func slowWide() -> Bool {
        let w = 1000, h = 600, side = 60, pageW = 3000
        let page = CGContext(data: nil, width: pageW, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        page.setFillColor(CGColor(gray: 0.98, alpha: 1)); page.fill(CGRect(x: 0, y: 0, width: pageW, height: h))
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 26, nil)
        var seed: UInt64 = 66
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        var y = 30
        while y < h - 40 {
            let str = String((0..<(3 + rnd(60))).map { _ in Character(UnicodeScalar(0x3041 + rnd(80))!) })
            let attr = NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)])
            page.textPosition = CGPoint(x: 36 + rnd(4) * 20, y: h - y); CTLineDraw(CTLineCreateWithAttributedString(attr), page)
            y += 40 + (rnd(6) == 0 ? 60 : 0)
        }
        let body = page.makeImage()!
        let st = AutoStitcher()
        var steps: [String] = []
        for i in 0..<12 {
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(body.cropping(to: CGRect(x: i * 5, y: 0, width: w, height: h))!, in: CGRect(x: 0, y: 0, width: w, height: h))
            c.setFillColor(CGColor(red: 0.3, green: 0.1, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: side, height: h))
            steps.append(symbol(st.add(c.makeImage()!), scale: 1))
        }
        let out = st.compose()
        let ok = st.axis == .horizontal && out?.width == w + 55 && out?.height == h
        print("\(ok ? "✓" : "✗") 横に長いページをゆっくり送る（縦と取り違えない）：\(out?.width ?? 0)×\(out?.height ?? 0)（正解 \(w + 55)×\(h)・\(st.axis == .horizontal ? "横" : st.axis == .vertical ? "縦" : "未定")）　[\(steps.joined(separator: " "))]")
        return ok
    }

    static func symbol(_ r: StepResult, scale: Int) -> String {
        switch r { case .first: return "始"; case .added(let n): return "+\(n / scale)"
        case .still: return "止"; case .lost: return "×"; case .back: return "戻"; case .full: return "満" }
    }

    static func run(outDir: String?) -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        let cases = [
            Case(name: "ふつう（固定ヘッダー・フッターあり）", offsets: [0, 37, 120, 121, 260, 410, 410, 655, 900, 1180, 1500, 1820],
                 expect: "始 +37 +83 +1 +139 +150 止 +245 +245 +280 +320 +320"),
            Case(name: "途中で戻る・止まる", offsets: [0, 200, 120, 80, 200, 330, 330, 330, 520, 700],
                 expect: "始 +200 戻 戻 止 +130 止 止 +190 +180"),
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
            Case(name: "縦の固定サイドバー（その列を外して比べる）", offsets: [0, 70, 200, 390, 600, 820], expect: "始 +70 +130 +190 +210 +220",
                 noiseAt: { _ in Noise(sidebar: true) }, ignoreLeft: 60),
            Case(name: "透けるヘッダー（下の本文が透ける・ゆっくりなら継げる）", offsets: [0, 70, 200, 330, 460, 590, 720], expect: "始 +70 +130 +130 +130 +130 +130",
                 noiseAt: { _ in Noise(glass: true) }, sizeOnly: true),
            Case(name: "表（数字だけ違う行）", offsets: [0, 70, 200, 390, 600, 820], expect: "始 +70 +130 +190 +210 +220", look: .table),
            Case(name: "動く帯（動画・広告）で継ぎ間違えない", offsets: [0, 70, 200, 390, 600, 820], expect: "BAND",
                 noiseAt: { i in Noise(band: i) }, sizeOnly: true),
            Case(name: "表＋動く帯（別の周期のずれで継がない）", offsets: [0, 100, 230, 400, 640], expect: "BAND",
                 look: .table, noiseAt: { i in Noise(band: i) }, sizeOnly: true),
            Case(name: "先頭が白い余白（固定ヘッダーと取り違えない）", offsets: [0, 300, 700, 1100, 1500, 1800], expect: "始 +300 +400 +400 +400 +300",
                 header: 0, footer: 0, look: .blankTop),
            Case(name: "横：左右に固定サイドバー", offsets: [0, 37, 120, 121, 260, 410, 410, 655, 900, 1180, 1500, 1820],
                 expect: "始 +37 +83 +1 +139 +150 止 +245 +245 +280 +320 +320", horizontal: true),
            Case(name: "横：途中で戻る・止まる", offsets: [0, 200, 120, 80, 200, 330, 330, 330, 520, 700],
                 expect: "始 +200 戻 戻 止 +130 止 止 +190 +180", horizontal: true),
            Case(name: "横：サイドバーなし", offsets: [0, 90, 250, 251, 500, 760, 1010], expect: "始 +90 +160 +1 +249 +260 +250",
                 header: 0, footer: 0, horizontal: true),
            Case(name: "横：Retina（2倍）", offsets: [0, 45, 200, 420, 700], expect: "始 +45 +155 +220 +280", scale: 2, horizontal: true),
            Case(name: "横：ゆっくり送る（縦と取り違えない）", offsets: Array(stride(from: 0, through: 200, by: 5)),
                 expect: (["始"] + Array(repeating: "+5", count: 40)).joined(separator: " "), horizontal: true),
            Case(name: "横：下端のスクロールバー", offsets: [0, 70, 200, 390, 600, 820], expect: "始 +70 +130 +190 +210 +220",
                 noiseAt: { _ in Noise(scrollbarLeft: true) }, ignoreLeft: 16, horizontal: true),
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
            // BAND＝継げなくてもよい（×は安全側）。継いだときは正しい量であること（大きさの比較で見る）
            let seqOK = c.expect == "BAND" ? !results.contains(.full) : steps == c.expect
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
            let expectV = scaled(ctx.makeImage()!, c.scale)
            let expect = c.horizontal ? rotate90(expectV, clockwise: false)! : expectV
            let wantAxis: ScrollAxis = c.horizontal ? .horizontal : .vertical
            let axisOK = st.axis == nil || st.axis == wantAxis
            var pixOK = out.height == expect.height && out.width == expect.width
            var diffRows = 0
            if pixOK && !c.sizeOnly {
                // 横は縦の向きに戻して比べる（見ない端を縦と同じに扱える）
                let a = pixels(c.horizontal ? rotate90(out, clockwise: true)! : out), b = pixels(expectV)
                let rowBytes = expectV.width * 4
                let from = c.ignoreLeft * c.scale * 4, to = (expectV.width - c.ignoreRight * c.scale) * 4
                for y in 0..<expectV.height {
                    let r = y * rowBytes
                    if a[(r + from)..<(r + to)] != b[(r + from)..<(r + to)] { diffRows += 1 }
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
        // 横に長い本物らしいページ（横書きの行が並ぶ）をゆっくり横に送る。
        // 縦のページを回しただけのテストでは、行が縦になるので「縦が1行ずれで継ぐ」誤判定が起きない
        let wideOK = slowWide()
        allOK = allOK && wideOK
        // 回す向きそのもの：右回りは「左端が上」に来る（往復だけでは向きの取り違えが見えない）
        let lr = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        lr.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); lr.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        lr.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); lr.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let px = pixels(rotate90(lr.makeImage()!, clockwise: true)!)     // 1×2・上の行から
        let dirOK = px.count == 8 && px[0] > 200 && px[2] < 50 && px[6] > 200
        print("\(dirOK ? "✓" : "✗") 回す向き：右回りで左端（赤）が上・右端（青）が下")
        allOK = allOK && dirOK
        return allOK
    }

    static func save(_ img: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
