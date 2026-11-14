// スクロールキャプチャの「つなぐ」部分。画面のコマを順に受け取り、1枚の縦長画像にする。
// 方式：各行を横32区画の平均明るさ（行の指紋）にして、前のコマと今のコマで
//   ①上下の同じ位置に同じ行が並ぶ帯 ＝ 固定ヘッダー／フッター
//   ②真ん中の帯がどれだけ上にずれたか ＝ スクロール量 d
// を求め、今のコマの下 d 行だけを継ぎ足す。比べる相手は「最後に採ったコマ」なので、
// 戻る向きにスクロールしても、また進めば続きから継げる。
// 疑わしいとき（2番目に良いずれも同じくらい合う・合う行が少ない）は継がずに .lost を返す。
// 呼び出しは1本の列（同じスレッド）からだけ。
import CoreGraphics
import Foundation

final class Frame {
    let image: CGImage
    let width: Int
    let height: Int
    let rows: [[Float]]          // 行ごとの指紋（32区画の平均）
    let rowVar: [Float]          // 行の中のばらつき（真っ白な行の見分け）
    static let cells = 32

    /// barOnLeft＝左端を指紋から外す（横スクロールを回したコマ。元の下端のスクロールバーが左に来る）
    init?(_ image: CGImage, barOnLeft: Bool = false) {
        self.image = image
        let width = image.width, height = image.height
        self.width = width; self.height = height
        guard width >= 16, height >= 16 else { return nil }
        let bpr = width * 4
        var buf = [UInt8](repeating: 0, count: bpr * height)
        guard let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let cells = Frame.cells
        // 右端は指紋に入れない（スクロール中だけ出るスクロールバーが写るため）
        let skip = min(40, width / 16)
        let usable = width - skip, x0base = barOnLeft ? skip : 0
        var rs = [[Float]](), vs = [Float]()
        rs.reserveCapacity(height); vs.reserveCapacity(height)
        // CGContext の data は上の行から並ぶ
        buf.withUnsafeBufferPointer { p in
            for y in 0..<height {
                var v = [Float](repeating: 0, count: cells)
                let base = y * bpr
                for c in 0..<cells {
                    let x0 = x0base + c * usable / cells, x1 = max(x0 + 1, x0base + (c + 1) * usable / cells)
                    var s = 0
                    for x in x0..<x1 {
                        let i = base + x * 4
                        s += Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])
                    }
                    v[c] = Float(s) / Float((x1 - x0) * 10)
                }
                let m = v.reduce(0, +) / Float(cells)
                vs.append(v.reduce(0) { $0 + abs($1 - m) } / Float(cells))
                rs.append(v)
            }
        }
        rows = rs; rowVar = vs
    }

    @inline(__always) func rowDiff(_ a: Int, _ other: Frame, _ b: Int) -> Float {
        var s: Float = 0
        rows[a].withUnsafeBufferPointer { p in
            other.rows[b].withUnsafeBufferPointer { q in
                for i in 0..<p.count { s += abs(p[i] - q[i]) }
            }
        }
        return s / Float(Frame.cells)
    }
}

enum StepResult: Equatable {
    case first
    case added(Int)      // 継ぎ足した行数
    case still           // 動いていない（一部だけ変わった＝ホバーなども含む）
    case lost            // 重なりが見つからない・疑わしい（速すぎ・中身が変わった）
    case full            // 上限に達した
}

/// 8bit で描ける色空間。元が RGB ならそのまま（Display P3 の色を変えない）。
/// HDR の拡張色空間（16bit の浮動小数）は 8bit の器が作れないので、同じ色域の通常版に直す
func eightBitSpace(_ img: CGImage) -> CGColorSpace {
    guard let s = img.colorSpace, s.model == .rgb else { return CGColorSpace(name: CGColorSpace.sRGB)! }
    if !CGColorSpaceUsesExtendedRange(s) && img.bitsPerComponent <= 8 { return s }
    let n = (s.name as String?) ?? ""
    return CGColorSpace(name: n.contains("P3") ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
}

/// 画素を自分のバッファに写す（切り出しは元のコマ全体を抱えたままになるため）
func copyRows(_ img: CGImage, from y: Int, count: Int) -> CGImage? {
    guard count > 0, let part = img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: count)),
          let ctx = CGContext(data: nil, width: img.width, height: count, bitsPerComponent: 8, bytesPerRow: 0,
                              space: eightBitSpace(img),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(part, in: CGRect(x: 0, y: 0, width: img.width, height: count))
    return ctx.makeImage()
}

final class Stitcher {
    private(set) var first: Frame?
    private(set) var last: Frame?        // 最後に採ったコマ
    private var strips: [CGImage] = []   // 継ぎ足した帯（自前のバッファ）
    private(set) var top = -1             // 固定ヘッダーの行数（未確定は -1）
    private(set) var bottom = -1          // 固定フッターの行数
    private(set) var bodyHeight = 0
    private(set) var isFull = false       // 一度上限に達したら、以後は継がない
    let maxPixels: Int                    // できあがりの画素数の上限（メモリを守る）
    let tolerance: Float = 2.0

    let barOnLeft: Bool
    init(maxPixels: Int = 160_000_000, barOnLeft: Bool = false) { self.maxPixels = maxPixels; self.barOnLeft = barOnLeft }

    var height: Int {
        guard first != nil else { return 0 }
        return max(top, 0) + bodyHeight + max(bottom, 0)
    }

    /// 本体 [t0, h-b0) の中で、今のコマが前のコマから何行ずれたか。疑わしければ nil
    /// 比べ方は「崩れに強く」してある：
    ///  ・ページが動いたのに同じ位置で変わらない区画（縦の固定サイドバー）は外す
    ///  ・行の指紋から行の平均を引いて比べる（背景の縦グラデで明るさがずれても合う）
    ///  （平均を引くと、透けるヘッダーや動く帯がある表で「別の周期のずれ」を選ばず、継がない側に倒れる）
    private func findShift(_ cur: Frame, _ prev: Frame, top t0: Int, bottom b0: Int) -> Int? {
        let h = cur.height
        let mid = h - t0 - b0
        guard mid > 16 else { return nil }
        let minOverlap = max(16, mid / 6)
        let maxD = mid - minOverlap
        guard maxD >= 1 else { return nil }
        let mask = movingCells(cur, prev, t0, b0)
        let step = mid > 400 ? 3 : 1
        var errs = [Float](repeating: .greatestFiniteMagnitude, count: maxD + 1)
        var best = Float.greatestFiniteMagnitude, bestD = -1
        var buf = [Float](); buf.reserveCapacity(mid)
        for d in 1...maxD {
            var s: Float = 0
            buf.removeAll(keepingCapacity: true)
            var y = t0
            while y < h - b0 - d {
                if prev.rowVar[y + d] > 0.5 || cur.rowVar[y] > 0.5 {     // 模様のある行だけ
                    let e = Self.diff(cur.rows[y], prev.rows[y + d], mask)
                    s += e; buf.append(e)
                    if buf.count > 24 && s / Float(buf.count) > best * 4 + 8 { break }   // 見込みなし
                }
                y += step
            }
            let need = max(6, (h - b0 - d - t0) / step / 20)          // 合わせた行が少なすぎるずれは採らない
            guard buf.count >= need else { continue }
            errs[d] = s / Float(buf.count)
            if errs[d] < best { best = errs[d]; bestD = d }
        }
        guard bestD > 0, best <= tolerance * 1.5 else { return nil }
        // 離れたずれ（±3行より外）にも同じくらい合うものがあれば、どちらか決められない＝継がない
        var second = Float.greatestFiniteMagnitude
        for d in 1...maxD where abs(d - bestD) > 3 { second = min(second, errs[d]) }
        if second - best < max(0.6, best * 0.5) { return nil }
        guard step > 1 else { return bestD }
        // 1行刻みで詰め直す
        var fine = bestD, fineErr = Float.greatestFiniteMagnitude
        for d in max(1, bestD - step)...min(maxD, bestD + step) {
            buf.removeAll(keepingCapacity: true)
            for y in t0..<(h - b0 - d) where prev.rowVar[y + d] > 0.5 || cur.rowVar[y] > 0.5 {
                buf.append(Self.diff(cur.rows[y], prev.rows[y + d], mask))
            }
            if !buf.isEmpty { let e = buf.reduce(0, +) / Float(buf.count); if e < fineErr { fineErr = e; fine = d } }
        }
        return fine
    }

    /// ページが動いた（本体の大半の区画が変わった）のに、同じ位置で変わらない区画＝固定の列。比べる区画から外す
    private func movingCells(_ cur: Frame, _ prev: Frame, _ t0: Int, _ b0: Int) -> [Int] {
        let n = Frame.cells
        var sum = [Float](repeating: 0, count: n), cnt: Float = 0
        for y in Swift.stride(from: t0, to: cur.height - b0, by: 2) {
            let a = cur.rows[y], b = prev.rows[y]
            for c in 0..<n { sum[c] += abs(a[c] - b[c]) }
            cnt += 1
        }
        guard cnt > 0 else { return Array(0..<n) }
        let fixed = (0..<n).map { sum[$0] / cnt <= 0.4 }
        // 固定の列の隣も外す（固定の帯の端が区画の途中にかかると、その区画は半分だけ動く）
        let moving = (0..<n).filter { c in !fixed[c] && !(c > 0 && fixed[c - 1]) && !(c < n - 1 && fixed[c + 1]) }
        // 動いた区画が少なすぎる（ほぼ無地のページなど）ときは全部で比べる
        guard moving.count >= max(4, n / 4) else { return Array(0..<n) }
        return moving.count == n ? moving : withBlank(moving, cur, t0, b0)
    }

    /// 動いた区画に、本体の中でずっと無地の区画（余白）も足す（余白どうしは合うので害がなく、外すと指紋が細る）
    private func withBlank(_ moving: [Int], _ cur: Frame, _ t0: Int, _ b0: Int) -> [Int] {
        let n = Frame.cells
        var lo = [Float](repeating: .greatestFiniteMagnitude, count: n), hi = [Float](repeating: -1, count: n)
        for y in Swift.stride(from: t0, to: cur.height - b0, by: 2) {
            let a = cur.rows[y]
            for c in 0..<n { lo[c] = min(lo[c], a[c]); hi[c] = max(hi[c], a[c]) }
        }
        let set = Set(moving)
        return (0..<n).filter { set.contains($0) || hi[$0] - lo[$0] < 1 }
    }

    /// 2行の違い（選んだ区画だけ・それぞれの平均を引いてから）
    @inline(__always) static func diff(_ a: [Float], _ b: [Float], _ m: [Int]) -> Float {
        var ma: Float = 0, mb: Float = 0
        let k = Float(m.count)
        for i in m { ma += a[i]; mb += b[i] }
        ma /= k; mb /= k
        var s: Float = 0
        for i in m { s += abs((a[i] - ma) - (b[i] - mb)) }
        return s / k
    }

    @discardableResult
    func add(_ img: CGImage) -> StepResult {
        if isFull { return .full }
        guard let cur = Frame(img, barOnLeft: barOnLeft) else { return .lost }
        guard let prev = last else {
            first = cur; last = cur
            bodyHeight = cur.height
            return .first
        }
        guard cur.width == prev.width, cur.height == prev.height else { return .lost }
        let h = cur.height

        // 同じ位置で同じ行の帯（上から・下から）
        var t = 0
        while t < h && cur.rowDiff(t, prev, t) <= tolerance { t += 1 }
        if t == h { return .still }
        var b = 0
        while b < h - t && cur.rowDiff(h - 1 - b, prev, h - 1 - b) <= tolerance { b += 1 }
        // 変わったのが一部の帯だけ（ホバー・点滅・動画など）なら、継げなくても「止まっている」扱い
        let local = h - t - b < h / 5

        let t0: Int, b0: Int, d: Int
        if top < 0 {
            // 固定帯は「継げたとき」に初めて確定する。外れたら次のコマで測り直す
            let ct = min(t, h / 3), cb = min(b, h / 3)
            if let dd = findShift(cur, prev, top: ct, bottom: cb) { t0 = ct; b0 = cb; d = dd }
            else if ct + cb > 0, let dd = findShift(cur, prev, top: 0, bottom: 0) { t0 = 0; b0 = 0; d = dd }
            else { return local ? .still : .lost }
        } else {
            b0 = bottom
            // 上の固定帯は比べる範囲を狭めるだけ（継ぐ帯は下から取る）。合わなければ上も含めて探し直す
            if let dd = findShift(cur, prev, top: top, bottom: b0) { t0 = top; d = dd }
            else if top > 0, let dd = findShift(cur, prev, top: 0, bottom: b0) { t0 = 0; d = dd }
            else { return local ? .still : .lost }
        }
        if ((top < 0 ? h : height) + d) * cur.width > maxPixels { isFull = true; return .full }
        guard let strip = copyRows(cur.image, from: h - b0 - d, count: d) else { return .lost }
        if top < 0 { top = t0; bottom = b0; bodyHeight = h - t0 - b0 }
        strips.append(strip)
        bodyHeight += d
        last = cur
        return .added(d)
    }

    /// できあがりの1枚。ヘッダー＋最初の本体は最初のコマ、フッターは最後のコマから。
    func compose() -> CGImage? {
        guard let f = first, let l = last else { return nil }
        if strips.isEmpty { return f.image }
        let w = f.width, b = max(bottom, 0)
        let H = height
        guard let ctx = CGContext(data: nil, width: w, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: f.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext は下が原点。上から dstY 行目に置く
        func put(_ img: CGImage, srcY: Int, rows: Int, at dstY: Int) {
            guard rows > 0, let part = img.cropping(to: CGRect(x: 0, y: srcY, width: w, height: rows)) else { return }
            ctx.draw(part, in: CGRect(x: 0, y: H - dstY - rows, width: w, height: rows))
        }
        put(f.image, srcY: 0, rows: f.height - b, at: 0)
        var y = f.height - b
        for s in strips { put(s, srcY: 0, rows: s.height, at: y); y += s.height }
        put(l.image, srcY: l.height - b, rows: b, at: y)
        return ctx.makeImage()
    }
}

// MARK: - 横スクロール（画像を90°回して縦として継ぎ、できあがりを戻す）

import Accelerate

/// 90°回す。clockwise＝右回り（左端が上に来る＝左へ流れる中身が上へ流れる）
func rotate90(_ img: CGImage, clockwise: Bool) -> CGImage? {
    let w = img.width, h = img.height
    // 元の色空間のまま回す（Display P3 の色が縦と横で変わらないように）
    let space = eightBitSpace(img)
    var src = [UInt8](repeating: 0, count: w * h * 4)
    guard let sctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    sctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var dst = [UInt8](repeating: 0, count: w * h * 4)
    let err: vImage_Error = src.withUnsafeMutableBytes { sp in
        dst.withUnsafeMutableBytes { dp in
            var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(w), width: vImagePixelCount(h), rowBytes: h * 4)
            var bg: [UInt8] = [0, 0, 0, 0]
            return vImageRotate90_ARGB8888(&s, &d, UInt8(clockwise ? kRotate90DegreesClockwise : kRotate90DegreesCounterClockwise),
                                           &bg, vImage_Flags(kvImageNoFlags))
        }
    }
    guard err == kvImageNoError else { return nil }
    return dst.withUnsafeMutableBytes { dp in
        CGContext(data: dp.baseAddress, width: h, height: w, bitsPerComponent: 8, bytesPerRow: h * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}

enum ScrollAxis { case vertical, horizontal }

/// 縦と横を両方で試し、はっきり多く進んだほうの向きに決める（決まったら、もう片方は捨てる）。
/// 「先に継げたほう」で決めると、ゆっくり横に送ったとき縦が1行ずれの誤判定で先に継いでしまう。
/// 横では左右の固定サイドバーが「固定ヘッダー／フッター」として外れる。
final class AutoStitcher {
    private var v: Stitcher
    private var h: Stitcher
    private(set) var axis: ScrollAxis?
    private var vFirst = 0, hFirst = 0     // 最初のコマの長さ（縦は高さ・横は幅）
    static let decide = 24          // この長さ（画素）以上進み、もう片方の2倍以上なら決める
    static let force = 64           // ここまで進んだら多いほうに決める

    init(maxPixels: Int = 160_000_000) {
        v = Stitcher(maxPixels: maxPixels)
        // 横は回して戻す分だけメモリを多く使うので、上限を縦の半分に
        h = Stitcher(maxPixels: maxPixels / 2, barOnLeft: true)
    }

    private var vGain: Int { max(0, v.height - vFirst) }
    private var hGain: Int { max(0, h.height - hFirst) }
    /// 決まる前は、多く進んだほう（同じなら縦）
    private var leader: ScrollAxis { axis ?? (hGain > vGain ? .horizontal : .vertical) }

    var isFull: Bool { leader == .horizontal ? h.isFull : v.isFull }
    /// 継いだ向きの長さ（縦なら高さ、横なら幅）
    var length: Int { leader == .horizontal ? h.height : v.height }

    @discardableResult
    func add(_ img: CGImage) -> StepResult {
        switch axis {
        case .vertical: return v.add(img)
        case .horizontal: return rotate90(img, clockwise: true).map { h.add($0) } ?? .lost
        case nil:
            let rv = v.add(img)
            let rh = rotate90(img, clockwise: true).map { h.add($0) } ?? .lost
            if case .first = rv { vFirst = v.height; hFirst = h.height; return rv }
            let a = vGain, b = hGain
            if (a >= Self.decide && a >= 2 * b) || (a >= Self.force && a >= b) { lock(.vertical) }
            else if (b >= Self.decide && b >= 2 * a) || (b >= Self.force && b > a) { lock(.horizontal) }
            let mine = leader == .horizontal ? rh : rv, other = leader == .horizontal ? rv : rh
            if case .added = mine { return mine }
            if case .full = mine { return mine }
            if mine == .still || other == .still { return .still }
            return mine
        }
    }

    /// 向きを先に決めておく（札で縦・横を選んだとき）。1コマ目より前に呼ぶ
    func force(_ a: ScrollAxis) { if axis == nil { lock(a) } }

    /// 向きを決め、使わないほうを捨てる（画像を持ち続けない）
    private func lock(_ a: ScrollAxis) {
        axis = a
        if a == .vertical { h = Stitcher(maxPixels: 1) } else { v = Stitcher(maxPixels: 1) }
    }

    func compose() -> CGImage? {
        if leader == .horizontal { return h.compose().flatMap { rotate90($0, clockwise: false) } }
        return v.compose()
    }
}
