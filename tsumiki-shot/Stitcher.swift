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

    init?(_ image: CGImage) {
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
        let usable = width - min(40, width / 16)
        var rs = [[Float]](), vs = [Float]()
        rs.reserveCapacity(height); vs.reserveCapacity(height)
        // CGContext の data は上の行から並ぶ
        buf.withUnsafeBufferPointer { p in
            for y in 0..<height {
                var v = [Float](repeating: 0, count: cells)
                let base = y * bpr
                for c in 0..<cells {
                    let x0 = c * usable / cells, x1 = max(x0 + 1, (c + 1) * usable / cells)
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

/// 画素を自分のバッファに写す（切り出しは元のコマ全体を抱えたままになるため）
func copyRows(_ img: CGImage, from y: Int, count: Int) -> CGImage? {
    guard count > 0, let part = img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: count)),
          let ctx = CGContext(data: nil, width: img.width, height: count, bitsPerComponent: 8, bytesPerRow: 0,
                              space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
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

    init(maxPixels: Int = 160_000_000) { self.maxPixels = maxPixels }

    var height: Int {
        guard first != nil else { return 0 }
        return max(top, 0) + bodyHeight + max(bottom, 0)
    }

    /// 本体 [t0, h-b0) の中で、今のコマが前のコマから何行ずれたか。疑わしければ nil
    private func findShift(_ cur: Frame, _ prev: Frame, top t0: Int, bottom b0: Int) -> Int? {
        let h = cur.height
        let mid = h - t0 - b0
        guard mid > 16 else { return nil }
        let minOverlap = max(16, mid / 6)
        let maxD = mid - minOverlap
        guard maxD >= 1 else { return nil }
        let step = mid > 400 ? 3 : 1
        var errs = [Float](repeating: .greatestFiniteMagnitude, count: maxD + 1)
        var best = Float.greatestFiniteMagnitude, bestD = -1
        for d in 1...maxD {
            var s: Float = 0, n = 0
            var y = t0
            while y < h - b0 - d {
                if prev.rowVar[y + d] > 0.5 || cur.rowVar[y] > 0.5 {     // 模様のある行だけ
                    s += cur.rowDiff(y, prev, y + d); n += 1
                    if n > 24 && s / Float(n) > best * 4 + 8 { break }   // 見込みなし
                }
                y += step
            }
            let need = max(6, (h - b0 - d - t0) / step / 20)          // 合わせた行が少なすぎるずれは採らない
            guard n >= need else { continue }
            errs[d] = s / Float(n)
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
            var s: Float = 0, n = 0
            for y in t0..<(h - b0 - d) where prev.rowVar[y + d] > 0.5 || cur.rowVar[y] > 0.5 {
                s += cur.rowDiff(y, prev, y + d); n += 1
            }
            if n > 0, s / Float(n) < fineErr { fineErr = s / Float(n); fine = d }
        }
        return fine
    }

    @discardableResult
    func add(_ img: CGImage) -> StepResult {
        if isFull { return .full }
        guard let cur = Frame(img) else { return .lost }
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
            t0 = top; b0 = bottom
            guard let dd = findShift(cur, prev, top: t0, bottom: b0) else { return local ? .still : .lost }
            d = dd
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
