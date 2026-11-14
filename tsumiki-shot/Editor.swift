// 撮った画像に書き込む編集画面。
// 道具：選ぶ・矢印・線・四角・塗り・丸・ペン・蛍光ペン・文字・番号・モザイク・ぼかし・スポット・切り抜き。色と太さ・戻す/やり直す・背景（余白・角丸・影）。
// 書き込みは画像の画素の座標（左上が原点）で持ち、画面の表示と書き出しで同じ描き方（Annotate）を使う。
// 保存は元の画像を残し「〜 編集.png」を横に作る（＋クリップボード）。
import AppKit
import CoreImage

enum Shape: Equatable {
    case arrow(CGPoint, CGPoint)
    case line(CGPoint, CGPoint)
    case box(CGRect)
    case fill(CGRect)
    case oval(CGRect)
    case pen([CGPoint])
    case marker([CGPoint])
    case text(CGPoint, String)       // 文字の左上
    case number(CGPoint, Int)        // 丸の中心と番号
    case mosaic(CGRect)
    case blur(CGRect)
    case spot(CGRect)                // ここ以外を暗く
}

struct Mark: Equatable {
    var shape: Shape
    var color: Int = 0               // markColors の番号
    var size: Int = 1                // 0 細い・1 ふつう・2 太い
    init(_ shape: Shape, color: Int = 0, size: Int = 1) { self.shape = shape; self.color = color; self.size = size }
}

private func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// 書き込みの色（画像の上で目立つ色。並びは 赤・橙・黄・緑・青・墨・白）
let markColors: [(name: String, color: NSColor)] = [
    ("赤", NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)), ("橙", srgb(0xFF9500)), ("黄", srgb(0xFFCC00)),
    ("緑", srgb(0x34C759)), ("青", srgb(0x0A84FF)), ("墨", srgb(0x1D1A15)), ("白", srgb(0xFFFFFF)),
]
let markColor = markColors[0].color
let markSizes = ["細い", "ふつう", "太い"]

/// 背景（余白・角丸・影）。設定は覚えておく
struct Backdrop: Equatable {
    var on = false
    var pad: CGFloat = 48            // 見た目の大きさ（×倍率で画素）
    var fill = 0                     // backdropFills の番号
    var round = true
    var shadow = true
    func padPx(_ unit: CGFloat) -> CGFloat { on ? (pad * unit).rounded() : 0 }

    static func load() -> Backdrop {
        let d = UserDefaults.standard
        var b = Backdrop()
        if d.object(forKey: "editor.bg.pad") != nil { b.pad = CGFloat(d.double(forKey: "editor.bg.pad")) }
        b.fill = min(max(0, d.integer(forKey: "editor.bg.fill")), backdropFills.count - 1)
        if d.object(forKey: "editor.bg.round") != nil { b.round = d.bool(forKey: "editor.bg.round") }
        if d.object(forKey: "editor.bg.shadow") != nil { b.shadow = d.bool(forKey: "editor.bg.shadow") }
        return b                        // 「つける」は毎回オフから（勝手に余白が付かない）
    }
    func store() {
        let d = UserDefaults.standard
        d.set(Double(pad), forKey: "editor.bg.pad"); d.set(fill, forKey: "editor.bg.fill")
        d.set(round, forKey: "editor.bg.round"); d.set(shadow, forKey: "editor.bg.shadow")
    }
}

/// 背景の地（つみきの色から。上→下のグラデーション。空＝透明）
let backdropFills: [(name: String, colors: [NSColor])] = [
    ("紙", [srgb(0xF5F4F0), srgb(0xE2DED4)]), ("黄土", [srgb(0xF0E4D1), srgb(0xD59A4D)]), ("若草", [srgb(0xDDE9DD), srgb(0x63764E)]),
    ("藍", [srgb(0x7F93A6), srgb(0x2F4050)]), ("墨", [srgb(0x2B2619), srgb(0x0F0D07)]), ("透明", []),
]

/// モザイク・ぼかしの作り直しを省く入れ物（画面の表示用。書き出しは毎回作る）
final class HideCache {
    var gen = 0
    private var d: [String: CGImage] = [:]
    private var bytes = 0
    static let limit = 256 << 20          // 256MB を超えたら捨てて作り直す（大きなモザイクをドラッグしても溜まらない）
    func get(_ k: String, _ make: () -> CGImage?) -> CGImage? {
        if let v = d["\(gen)|" + k] { return v }
        let v = make()
        if let v {
            let b = v.bytesPerRow * v.height
            if bytes + b > Self.limit || d.count > 200 { d.removeAll(); bytes = 0 }
            d["\(gen)|" + k] = v; bytes += b
        }
        return v
    }
    var byteCount: Int { bytes }
    func reset() { gen += 1; d.removeAll(); bytes = 0 }
}

enum Annotate {
    static let ci = CIContext(options: [.cacheIntermediates: false])

    /// 左上原点の座標系（ctx は上下反転済み）に、画像を正しい向きで置く
    static func put(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// 範囲を粗いマス目にする（元の画素は残らない）
    static func pixelate(_ base: CGImage, _ r: CGRect, block: Int) -> CGImage? {
        let r = r.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 1, r.height >= 1, let part = base.cropping(to: r) else { return nil }
        let sw = max(1, Int(r.width) / max(1, block)), sh = max(1, Int(r.height) / max(1, block))
        guard let small = bitmap(sw, sh, base.colorSpace) else { return nil }   // 元と同じ色空間（P3 の色がずれない）
        small.interpolationQuality = .medium
        small.draw(part, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return small.makeImage()
    }

    /// ぼかし：先にマス目に縮めて細部を捨て（元に戻せない）、それをなめらかにぼかす
    static func blurred(_ base: CGImage, _ r: CGRect, block: Int) -> CGImage? {
        let rr = r.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard rr.width >= 1, rr.height >= 1, let p = pixelate(base, rr, block: block) else { return nil }
        let img = CIImage(cgImage: p).transformed(by: CGAffineTransform(scaleX: rr.width / CGFloat(p.width), y: rr.height / CGFloat(p.height)))
        let out = img.clampedToExtent().applyingGaussianBlur(sigma: Double(block) * 0.6).cropped(to: CGRect(origin: .zero, size: rr.size))
        return ci.createCGImage(out, from: out.extent, format: .RGBA8,
                                colorSpace: base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func bitmap(_ w: Int, _ h: Int, _ space: CGColorSpace?) -> CGContext? {
        let s = space.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: s,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // 太さ・大きさ（見た目の pt。×倍率で画素）
    static func lineWidth(_ m: Mark, _ unit: CGFloat) -> CGFloat { [2, 3, 5][m.size] * unit }
    static func markerWidth(_ m: Mark, _ unit: CGFloat) -> CGFloat { [12, 18, 26][m.size] * unit }
    static func fontSize(_ m: Mark, _ unit: CGFloat) -> CGFloat { [14, 20, 30][m.size] * unit }
    static func numberRadius(_ m: Mark, _ unit: CGFloat) -> CGFloat { [10, 13, 17][m.size] * unit }
    static func hideBlock(_ m: Mark, _ unit: CGFloat) -> Int {
        if case .blur = m.shape { return Int([6, 9, 14][m.size] * unit) }
        return Int([5, 8, 12][m.size] * unit)
    }
    static func color(_ m: Mark) -> NSColor { markColors[min(max(0, m.color), markColors.count - 1)].color }
    /// 色の上に乗せる文字・縁の色（明るい色には墨、それ以外は白）
    static func onColor(_ m: Mark) -> NSColor { [2, 6].contains(m.color) ? srgb(0x1D1A15) : .white }

    static func font(_ unit: CGFloat) -> NSFont { .systemFont(ofSize: 20 * unit, weight: .bold) }
    static func textAttrs(_ m: Mark, _ unit: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize(m, unit), weight: .bold), .foregroundColor: color(m),
         .strokeColor: m.color == 6 ? srgb(0x1D1A15) : NSColor.white, .strokeWidth: -3.0]
    }

    /// 書き込みが占める範囲（選ぶ・枠の表示に使う）
    static func bounds(_ m: Mark, unit: CGFloat) -> CGRect {
        func span(_ ps: [CGPoint], _ w: CGFloat) -> CGRect {
            guard let f = ps.first else { return .null }
            var r = CGRect(origin: f, size: .zero)
            for p in ps { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -w / 2, dy: -w / 2)
        }
        switch m.shape {
        case .arrow(let a, let b), .line(let a, let b): return span([a, b], max(lineWidth(m, unit), 16 * unit * 0.6))
        case .box(let r), .fill(let r), .oval(let r), .mosaic(let r), .blur(let r), .spot(let r): return r.standardized
        case .pen(let ps): return span(ps, lineWidth(m, unit))
        case .marker(let ps): return span(ps, markerWidth(m, unit))
        case .text(let p, let s): return CGRect(origin: p, size: (s as NSString).size(withAttributes: textAttrs(m, unit)))
        case .number(let c, _): let r = numberRadius(m, unit); return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
    }

    static func segDist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 押した所に当たるか。strict＝線そのもの（四角・丸の中は当たらない）
    static func hits(_ m: Mark, _ p: CGPoint, unit: CGFloat, slop: CGFloat, strict: Bool) -> Bool {
        func nearPath(_ ps: [CGPoint], _ w: CGFloat) -> Bool {
            if ps.count == 1 { return hypot(p.x - ps[0].x, p.y - ps[0].y) <= w / 2 + slop }
            for i in 1..<ps.count where segDist(p, ps[i - 1], ps[i]) <= w / 2 + slop { return true }
            return false
        }
        switch m.shape {
        case .arrow(let a, let b), .line(let a, let b): return nearPath([a, b], lineWidth(m, unit))
        case .pen(let ps): return nearPath(ps, lineWidth(m, unit))
        case .marker(let ps): return nearPath(ps, markerWidth(m, unit))
        case .box(let r), .oval(let r):
            let r = r.standardized
            if !strict { return r.insetBy(dx: -slop, dy: -slop).contains(p) }
            let outer = r.insetBy(dx: -slop, dy: -slop), inner = r.insetBy(dx: slop + lineWidth(m, unit), dy: slop + lineWidth(m, unit))
            return outer.contains(p) && !inner.contains(p)
        case .spot(let r):
            let r = r.standardized
            if !strict { return r.contains(p) }
            let inner = r.insetBy(dx: slop, dy: slop)
            return r.insetBy(dx: -slop, dy: -slop).contains(p) && !inner.contains(p)
        default: return bounds(m, unit: unit).insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    static func moved(_ m: Mark, _ dx: CGFloat, _ dy: CGFloat) -> Mark {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        func t(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        var n = m
        switch m.shape {
        case .arrow(let a, let b): n.shape = .arrow(t(a), t(b))
        case .line(let a, let b): n.shape = .line(t(a), t(b))
        case .box(let r): n.shape = .box(t(r))
        case .fill(let r): n.shape = .fill(t(r))
        case .oval(let r): n.shape = .oval(t(r))
        case .pen(let ps): n.shape = .pen(ps.map(t))
        case .marker(let ps): n.shape = .marker(ps.map(t))
        case .text(let p, let s): n.shape = .text(t(p), s)
        case .number(let p, let k): n.shape = .number(t(p), k)
        case .mosaic(let r): n.shape = .mosaic(t(r))
        case .blur(let r): n.shape = .blur(t(r))
        case .spot(let r): n.shape = .spot(t(r))
        }
        return n
    }

    /// 点の列をなめらかにつなぐ（中点を通る2次曲線）
    static func smoothPath(_ ps: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let f = ps.first else { return path }
        path.move(to: f)
        if ps.count == 1 { path.addLine(to: f); return path }
        if ps.count == 2 { path.addLine(to: ps[1]); return path }
        for i in 1..<(ps.count - 1) {
            let mid = CGPoint(x: (ps[i].x + ps[i + 1].x) / 2, y: (ps[i].y + ps[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: ps[i])
        }
        path.addLine(to: ps[ps.count - 1])
        return path
    }

    /// ctx は「画像の画素・左上原点」。画面表示では外側で縮尺をかけてから呼ぶ。
    /// 描く順：隠す（モザイク・ぼかし）→ スポットの暗がり → そのほか（置いた順）
    static func draw(_ marks: [Mark], base: CGImage, unit: CGFloat, in ctx: CGContext, cache: HideCache? = nil, clip: CGPath? = nil) {
        let img = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        for m in marks {
            switch m.shape {
            case .mosaic(let r), .blur(let r):
                let rr = r.standardized.integral.intersection(img)
                guard rr.width >= 1, rr.height >= 1 else { continue }
                let isBlur: Bool = { if case .blur = m.shape { return true }; return false }()
                let block = hideBlock(m, unit)
                let make = { isBlur ? blurred(base, rr, block: block) : pixelate(base, rr, block: block) }
                let key = "\(isBlur ? "b" : "m")\(rr)\(block)"
                if let p = cache.map({ $0.get(key, make) }) ?? make() {
                    ctx.saveGState()
                    if let clip { ctx.addPath(clip); ctx.clip() }
                    ctx.interpolationQuality = isBlur ? .high : .none
                    put(p, in: rr, ctx)
                    ctx.restoreGState()
                }
            default: break
            }
        }
        let spots = marks.compactMap { m -> CGRect? in if case .spot(let r) = m.shape { return r.standardized }; return nil }
        if !spots.isEmpty {
            var hole = CGPath(rect: .zero, transform: nil)
            for r in spots { hole = hole.union(CGPath(roundedRect: r, cornerWidth: 6 * unit, cornerHeight: 6 * unit, transform: nil)) }
            let dark = (clip ?? CGPath(rect: img, transform: nil)).subtracting(hole)
            ctx.saveGState()
            ctx.addPath(dark); ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        for m in marks {
            let c = color(m).cgColor
            let lw = lineWidth(m, unit)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch m.shape {
            case .mosaic, .blur, .spot: break
            case .box(let r):
                ctx.setStrokeColor(c); ctx.setLineWidth(lw)
                ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil))
                ctx.strokePath()
            case .fill(let r):
                ctx.setFillColor(c)
                ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil))
                ctx.fillPath()
            case .oval(let r):
                ctx.setStrokeColor(c); ctx.setLineWidth(lw)
                ctx.strokeEllipse(in: r.standardized)
            case .line(let a, let b):
                ctx.setStrokeColor(c); ctx.setLineWidth(lw)
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            case .arrow(let a, let b):
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 1 else { continue }
                let ang = atan2(b.y - a.y, b.x - a.x)
                let head = min(len * 0.6, (10 + 2 * lw / unit) * unit)
                let neck = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
                ctx.setStrokeColor(c); ctx.setFillColor(c); ctx.setLineWidth(lw)
                ctx.move(to: a); ctx.addLine(to: neck); ctx.strokePath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(ang - 0.45) * head, y: b.y - sin(ang - 0.45) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(ang + 0.45) * head, y: b.y - sin(ang + 0.45) * head))
                ctx.closePath(); ctx.fillPath()
            case .pen(let ps):
                ctx.setStrokeColor(c); ctx.setLineWidth(lw)
                ctx.addPath(smoothPath(ps)); ctx.strokePath()
            case .marker(let ps):
                // 蛍光ペン：半分透ける太い線。重ねても濃くならないよう、透明の層で1本として描く
                ctx.setAlpha(0.42)
                ctx.setBlendMode(.multiply)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setStrokeColor(c); ctx.setLineWidth(markerWidth(m, unit)); ctx.setLineCap(.butt)
                ctx.addPath(smoothPath(ps)); ctx.strokePath()
                ctx.endTransparencyLayer()
            case .number(let p, let k):
                let r = numberRadius(m, unit)
                let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                ctx.setFillColor(c); ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(onColor(m).withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5 * unit)
                ctx.strokeEllipse(in: circle.insetBy(dx: 0.75 * unit, dy: 0.75 * unit))
                let s = "\(k)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: r * (k >= 10 ? 0.95 : 1.15), weight: .bold),
                                                            .foregroundColor: onColor(m)]
                let sz = s.size(withAttributes: attrs)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            case .text(let p, let s):
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                (s as NSString).draw(at: p, withAttributes: textAttrs(m, unit))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// 背景を付けたときの全体の大きさ（画素）と、画像を置く場所
    static func layout(_ base: CGImage, _ bg: Backdrop, unit: CGFloat) -> (size: CGSize, image: CGRect) {
        let p = bg.padPx(unit)
        return (CGSize(width: CGFloat(base.width) + 2 * p, height: CGFloat(base.height) + 2 * p),
                CGRect(x: p, y: p, width: CGFloat(base.width), height: CGFloat(base.height)))
    }

    static func imageClip(_ base: CGImage, _ bg: Backdrop, unit: CGFloat) -> CGPath? {
        guard bg.on, bg.round else { return nil }
        let r = 10 * unit
        return CGPath(roundedRect: CGRect(x: 0, y: 0, width: base.width, height: base.height), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// 背景・画像・書き込みを描く（ctx は全体の左上原点）。shown は表示用に縮めた画像（書き出しは base）
    /// shadowScale：影の大きさは CTM がかからないので、画面表示では縮尺を渡す
    static func drawScene(base: CGImage, shown: CGImage, marks: [Mark], bg: Backdrop, unit: CGFloat,
                          in ctx: CGContext, cache: HideCache? = nil, shadowScale: CGFloat = 1) {
        let (size, imgR) = layout(base, bg, unit: unit)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: CGRect(origin: .zero, size: size))     // 書き込みは仕上がりの範囲の外に出さない（書き出しと同じ見え方）
        if bg.on {
            let fill = backdropFills[min(max(0, bg.fill), backdropFills.count - 1)].colors
            if fill.count >= 2, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                  colors: fill.map(\.cgColor) as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(origin: .zero, size: size))
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width * 0.35, y: size.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }
        let clip = imageClip(base, bg, unit: unit)
        ctx.saveGState()
        ctx.translateBy(x: imgR.minX, y: imgR.minY)
        let local = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        if bg.on && bg.shadow {
            // 影は「紙の重なり」＝墨色で、下に落とす
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * unit * shadowScale), blur: 28 * unit * shadowScale,
                          color: srgb(0x1D1A15).withAlphaComponent(0.38).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(clip ?? CGPath(rect: local, transform: nil)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if let clip { ctx.addPath(clip); ctx.clip() }
        put(shown, in: local, ctx)
        ctx.restoreGState()
        draw(marks, base: base, unit: unit, in: ctx, cache: cache, clip: clip)
        ctx.restoreGState()
    }

    /// 書き込みを焼き込んだ1枚（背景が付いていれば余白ごと）
    static func render(_ base: CGImage, _ marks: [Mark], bg: Backdrop = Backdrop(), unit: CGFloat) -> CGImage? {
        let (size, _) = layout(base, bg, unit: unit)
        guard let ctx = bitmap(Int(size.width), Int(size.height), base.colorSpace) else { return nil }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        drawScene(base: base, shown: base, marks: marks, bg: bg, unit: unit, in: ctx)
        return ctx.makeImage()
    }

    static func flatten(_ base: CGImage, _ marks: [Mark], unit: CGFloat) -> CGImage? { render(base, marks, unit: unit) }

    static func png(_ img: CGImage, unit: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        let dpi = 72 * max(1, unit)   // 撮った画面の倍率＝解像度（元の撮影と同じ）
        CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(d) ? data as Data : nil
    }
}

enum Tool: Int, CaseIterable {
    case select, arrow, line, box, fill, oval, pen, marker, text, number, mosaic, blur, spot, crop

    /// アイコン（SF Symbols の線画）・名前・1文字のキー
    var info: (symbol: String, name: String, key: String) {
        switch self {
        case .select: return ("cursorarrow", "選ぶ", "v")
        case .arrow: return ("arrow.up.right", "矢印", "a")
        case .line: return ("line.diagonal", "線", "l")
        case .box: return ("rectangle", "四角", "r")
        case .fill: return ("rectangle.fill", "塗り", "f")
        case .oval: return ("circle", "丸", "o")
        case .pen: return ("scribble", "ペン", "p")
        case .marker: return ("highlighter", "蛍光ペン", "h")
        case .text: return ("textformat", "文字", "t")
        case .number: return ("1.circle", "番号", "n")
        case .mosaic: return ("square.grid.3x3.fill", "モザイク", "m")
        case .blur: return ("drop", "ぼかし", "b")
        case .spot: return ("light.max", "スポット", "s")
        case .crop: return ("crop", "切り抜き", "c")
        }
    }
    var defaultColor: Int { self == .marker ? 2 : 0 }
}

/// 画像と書き込みを表示し、ドラッグで書き込む面（左上原点）
final class CanvasView: NSView, NSTextFieldDelegate {
    private(set) var base: CGImage
    let unit: CGFloat
    var marks: [Mark] = [] { didSet { needsDisplay = true; onChange?() } }
    var draft: Mark? { didSet { needsDisplay = true } }
    var cropDraft: CGRect? { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true; if oldValue != selected { onSelect?() } } }
    var backdrop = Backdrop() { didSet { relayout() } }
    var tool: Tool = .arrow {
        didSet {
            guard oldValue != tool else { return }
            commitText()
            if oldValue == .crop { applyCrop() }
            if tool != .select { selected = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    var color = 0
    var size = 1
    var onChange: (() -> Void)?
    var onSelect: (() -> Void)?
    var onToolKey: ((Tool) -> Void)?
    var onBaseChange: (() -> Void)?
    let cache = HideCache()

    private struct Snap { let base: CGImage; let marks: [Mark] }
    private var undoStack: [Snap] = []
    private var redoStack: [Snap] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var downAt: CGPoint?
    private var points: [CGPoint] = []
    private var moving: (index: Int, from: CGPoint, orig: Mark, pushed: Bool)?
    /// 保存中は書き込みを受け付けない（焼き込みに入らない変更を作らない）
    var locked = false
    /// ⌘Z（false）・⇧⌘Z（true）。ボタンの keyEquivalent では shift を見分けられないのでここで受ける
    var onUndoKey: ((Bool) -> Void)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .shift, .control, .option])
        if e.charactersIgnoringModifiers?.lowercased() == "z",
           m == .command || m == [.command, .shift] {
            onUndoKey?(m.contains(.shift)); return true
        }
        return super.performKeyEquivalent(with: e)
    }
    private var field: NSTextField?
    private var fieldMark = Mark(.text(.zero, ""))
    private var editingOriginal: Mark?
    /// 表示用に一度だけ縮めた画像（大きな縦長でも、描き直すたびに元の大きさを縮めない）
    private var shown: CGImage
    private var showWidth: Int
    /// 見える範囲（スクロールの窓の中）。ここに収まるよう縮める
    var fit: CGSize { didSet { if fit != oldValue { relayout() } } }
    private(set) var viewScale: CGFloat = 1
    private var origin = CGPoint.zero      // 画面上で全体（背景込み）を置く左上

    init(base: CGImage, unit: CGFloat, width: CGFloat) {
        self.base = base; self.unit = unit
        showWidth = Int(width * 2)
        shown = CanvasView.shrink(base, toWidth: showWidth) ?? base
        let s = width / CGFloat(base.width)
        fit = CGSize(width: width, height: CGFloat(base.height) * s)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(base.height) * s))
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    static func shrink(_ img: CGImage, toWidth w: Int) -> CGImage? {
        guard img.width > w else { return img }
        let h = max(1, Int(Double(img.height) * Double(w) / Double(img.width)))
        guard let c = Annotate.bitmap(w, h, img.colorSpace) else { return nil }
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var padPx: CGFloat { backdrop.padPx(unit) }

    /// 大きさの決め直し：窓の幅に収め、撮った見た目より大きくはしない。窓より小さければ真ん中に
    func relayout() {
        let (size, _) = Annotate.layout(base, backdrop, unit: unit)
        viewScale = min(fit.width / size.width, 1 / max(unit, 0.5) * 1.0001)
        let content = CGSize(width: size.width * viewScale, height: size.height * viewScale)
        setFrameSize(NSSize(width: max(fit.width, content.width), height: max(fit.height, content.height)))
        origin = CGPoint(x: ((frame.width - content.width) / 2).rounded(), y: ((frame.height - content.height) / 2).rounded())
        if let f = field { placeField(f) }
        needsDisplay = true
    }

    private func setBase(_ b: CGImage) {
        base = b
        shown = CanvasView.shrink(b, toWidth: showWidth) ?? b
        cache.reset()
        relayout()
        onBaseChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = .high
        let all = marks + (draft.map { [$0] } ?? [])
        Annotate.drawScene(base: base, shown: shown, marks: all, bg: backdrop, unit: unit, in: ctx, cache: cache, shadowScale: viewScale)
        // 選んでいる書き込みの枠・切り抜きの範囲（画像の座標）
        ctx.translateBy(x: padPx, y: padPx)
        let hair = 1 / viewScale
        if let i = selected, marks.indices.contains(i) {
            let r = Annotate.bounds(marks[i], unit: unit).insetBy(dx: -4 * hair, dy: -4 * hair)
            ctx.setLineWidth(1.5 * hair)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [4 * hair, 3 * hair])
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let c = cropDraft {
            let img = CGRect(x: 0, y: 0, width: base.width, height: base.height)
            ctx.saveGState()
            ctx.addRect(img); ctx.addRect(c)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5 * hair)
            ctx.setLineDash(phase: 0, lengths: [6 * hair, 4 * hair]); ctx.stroke(c)
            ctx.restoreGState()
            // 大きさ（画素）
            let label = "\(Int(c.width)) × \(Int(c.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * hair, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let sz = label.size(withAttributes: attrs)
            let lr = CGRect(x: c.minX, y: max(0, c.minY - sz.height - 8 * hair), width: sz.width + 10 * hair, height: sz.height + 4 * hair)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.addPath(CGPath(roundedRect: lr, cornerWidth: 4 * hair, cornerHeight: 4 * hair, transform: nil)); ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            label.draw(at: CGPoint(x: lr.minX + 5 * hair, y: lr.minY + 2 * hair), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }

    /// 画面の位置 → 画像の画素（左上原点）。背景の余白の中にも描ける
    func imagePoint(_ e: NSEvent) -> CGPoint { imagePoint(view: convert(e.locationInWindow, from: nil)) }
    func imagePoint(view p: CGPoint) -> CGPoint {
        let pad = padPx
        let x = (p.x - origin.x) / viewScale - pad, y = (p.y - origin.y) / viewScale - pad
        return CGPoint(x: min(max(x, -pad), CGFloat(base.width) + pad), y: min(max(y, -pad), CGFloat(base.height) + pad))
    }
    func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x + padPx) * viewScale, y: origin.y + (p.y + padPx) * viewScale)
    }

    // MARK: 戻す・やり直す
    func push() {
        undoStack.append(Snap(base: base, marks: marks))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    private func restore(_ s: Snap) {
        selected = nil
        moving = nil; downAt = nil; draft = nil; points = []
        if s.base !== base { setBase(s.base) }
        marks = s.marks
    }

    /// 文字を打っている最中の ⌘Z は、その文字の取り消し（確定済みの書き込みは消さない）
    func undo() {
        if locked { NSSound.beep(); return }
        if let f = field {
            if let um = f.currentEditor()?.undoManager, um.canUndo { um.undo(); return }
            cancelText(); return
        }
        if cropDraft != nil { cropDraft = nil; return }
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(Snap(base: base, marks: marks))
        restore(s)
    }
    func redo() {
        if locked { NSSound.beep(); return }
        if let f = field {
            if let um = f.currentEditor()?.undoManager, um.canRedo { um.redo(); return }
            commitText()
        }
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(Snap(base: base, marks: marks))
        restore(s)
    }

    // MARK: 選ぶ・動かす・消す
    func hitIndex(_ p: CGPoint) -> Int? {
        let slop = 5 / viewScale
        for strict in [true, false] {
            for i in marks.indices.reversed() where Annotate.hits(marks[i], p, unit: unit, slop: slop, strict: strict) { return i }
        }
        return nil
    }
    func deleteSelected() {
        guard let i = selected, marks.indices.contains(i) else { NSSound.beep(); return }
        push(); selected = nil; marks.remove(at: i)
    }
    func duplicateSelected() {
        guard let i = selected, marks.indices.contains(i) else { NSSound.beep(); return }
        push()
        var m = Annotate.moved(marks[i], 16 * unit, 16 * unit)
        if case .number(let p, _) = m.shape { m.shape = .number(p, nextNumber) }
        marks.append(m); selected = marks.count - 1
    }
    /// 選んでいる書き込みを少し動かす。何も選んでいなければ false（矢印キーはスクロールに回す）
    @discardableResult func nudge(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard !locked, let i = selected, marks.indices.contains(i) else { return false }
        push(); marks[i] = Annotate.moved(marks[i], dx, dy)
        return true
    }
    /// 次に描く色・太さを変える。「選ぶ」道具で書き込みを選んでいるときは、その書き込みも変える
    /// （描いた直後に色を押しても、描いたものは変わらない＝前と同じ「次に描く色」）
    func setStyle(color c: Int? = nil, size s: Int? = nil) {
        if let c { color = c }
        if let s { size = s }
        if !locked, tool == .select, let i = selected, marks.indices.contains(i) {
            var m = marks[i]
            if let c { m.color = c }
            if let s { m.size = s }
            if m != marks[i] { push(); marks[i] = m }
        }
        if let f = field { styleField(f) }
    }
    var nextNumber: Int { (marks.compactMap { m -> Int? in if case .number(_, let k) = m.shape { return k }; return nil }.max() ?? 0) + 1 }

    // MARK: 切り抜き
    func applyCrop() {
        guard let c = cropDraft else { return }
        cropDraft = nil
        let r = c.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 4, r.height >= 4, r.size != CGSize(width: base.width, height: base.height),
              let cut = base.cropping(to: r) else { return }
        push()
        selected = nil
        let moved = marks.map { Annotate.moved($0, -r.minX, -r.minY) }
        setBase(cut)
        marks = moved
    }

    // MARK: マウス
    private func make(_ a: CGPoint, _ b0: CGPoint, shift: Bool) -> Mark {
        var b = b0
        switch tool {
        case .arrow, .line:
            if shift {   // 45°ごとにそろえる
                let ang = (atan2(b.y - a.y, b.x - a.x) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(b.x - a.x, b.y - a.y)
                b = CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
            }
        case .box, .fill, .oval, .mosaic, .blur, .spot, .crop:
            if shift {   // 正方形・正円
                let d = max(abs(b.x - a.x), abs(b.y - a.y))
                b = CGPoint(x: a.x + (b.x >= a.x ? d : -d), y: a.y + (b.y >= a.y ? d : -d))
            }
        default: break
        }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let shape: Shape
        switch tool {
        case .arrow: shape = .arrow(a, b)
        case .line: shape = .line(a, b)
        case .box: shape = .box(r)
        case .fill: shape = .fill(r)
        case .oval: shape = .oval(r)
        case .mosaic: shape = .mosaic(r)
        case .blur: shape = .blur(r)
        case .spot: shape = .spot(r)
        case .pen: shape = .pen(points)
        case .marker: shape = .marker(points)
        case .text, .number, .select, .crop: shape = .box(r)
        }
        return Mark(shape, color: color, size: size)
    }

    override func mouseDown(with e: NSEvent) {
        if locked { NSSound.beep(); return }
        let hadField = field != nil
        commitText()
        window?.makeFirstResponder(self)
        let p = imagePoint(e)
        switch tool {
        case .text:
            if hadField { return }   // 打ち終わりのクリックで、もう1つ欄を開かない
            if let i = hitIndex(p), case .text = marks[i].shape { editText(i); return }
            beginText(at: p, mark: Mark(.text(p, ""), color: color, size: size))
        case .number:
            push()
            marks.append(Mark(.number(p, nextNumber), color: color, size: size))
            selected = marks.count - 1
        case .select:
            if let i = hitIndex(p) {
                selected = i
                if e.clickCount == 2, case .text = marks[i].shape { editText(i); return }
                moving = (i, p, marks[i], false)
            } else { selected = nil }
        case .crop:
            downAt = CGPoint(x: min(max(p.x, 0), CGFloat(base.width)), y: min(max(p.y, 0), CGFloat(base.height)))
            if e.clickCount == 2, cropDraft != nil { downAt = nil; applyCrop() }
        case .pen, .marker:
            downAt = p; points = [p]
        default:
            downAt = p
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = imagePoint(e)
        let shift = e.modifierFlags.contains(.shift)
        if let mv = moving {
            guard marks.indices.contains(mv.index) else { moving = nil; return }
            if !mv.pushed { push(); moving?.pushed = true }
            marks[mv.index] = Annotate.moved(mv.orig, p.x - mv.from.x, p.y - mv.from.y)
            return
        }
        guard let a = downAt else { return }
        switch tool {
        case .crop:
            let b = CGPoint(x: min(max(p.x, 0), CGFloat(base.width)), y: min(max(p.y, 0), CGFloat(base.height)))
            let m = make(a, b, shift: shift)
            if case .box(let r) = m.shape { cropDraft = r.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height)) }
        case .pen, .marker:
            if shift { points = [a, p] }   // まっすぐ
            else if let last = points.last, hypot(p.x - last.x, p.y - last.y) * viewScale >= 1.5 { points.append(p) }
            draft = make(a, p, shift: shift)
        default:
            draft = make(a, p, shift: shift)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if moving != nil { moving = nil; return }
        guard let a = downAt else { return }
        downAt = nil
        let d = draft; draft = nil
        let b = imagePoint(e)
        switch tool {
        case .crop:
            if let c = cropDraft, c.width * viewScale < 6 || c.height * viewScale < 6 { cropDraft = nil }
        case .pen, .marker:
            if points.count == 1 { points.append(CGPoint(x: a.x + 0.1, y: a.y)) }   // 1回押しは点
            push(); marks.append(make(a, b, shift: false).with(points: points)); selected = marks.count - 1
            points = []
        default:
            guard hypot(b.x - a.x, b.y - a.y) * viewScale >= 4, let m = d else { return }
            push(); marks.append(m); selected = marks.count - 1
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        // 右クリック＝そこにある書き込みを選ぶ（消す・複製は下のキーで）
        let p = imagePoint(e)
        if let i = hitIndex(p) { selected = i }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }

    // MARK: キー
    override func keyDown(with e: NSEvent) {
        if locked { NSSound.beep(); return }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let step: CGFloat = (e.modifierFlags.contains(.shift) ? 10 : 1) * unit
        switch e.keyCode {
        case 51, 117: deleteSelected(); return                       // delete
        case 53:                                                       // esc
            if cropDraft != nil { cropDraft = nil } else if selected != nil { selected = nil } else { super.keyDown(with: e) }
            return
        case 36, 76: if cropDraft != nil { applyCrop() }; return       // return
        case 123: if !nudge(-step, 0) { super.keyDown(with: e) }; return
        case 124: if !nudge(step, 0) { super.keyDown(with: e) }; return
        case 125: if !nudge(0, step) { super.keyDown(with: e) }; return
        case 126: if !nudge(0, -step) { super.keyDown(with: e) }; return
        default: break
        }
        if mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased(),
           let t = Tool.allCases.first(where: { $0.info.key == ch }) {
            onToolKey?(t); return
        }
        if mods.isEmpty, let ch = e.characters, let n = Int(ch), (1...3).contains(n) { setStyle(size: n - 1); onSelect?(); return }
        super.keyDown(with: e)
    }

    /// ⌘C（編集メニュー）＝いまの画像をコピー
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func delete(_ sender: Any?) { deleteSelected() }

    // MARK: 文字：押した所に入力欄を出し、Enter か他を押したら確定
    var isEditingText: Bool { field != nil }
    private func placeField(_ f: NSTextField) {
        guard case .text(let p, _) = fieldMark.shape else { return }
        let fs = Annotate.fontSize(fieldMark, unit) * viewScale
        let v = viewPoint(p)
        f.frame = NSRect(x: v.x - 3, y: v.y - 3, width: max(220, f.intrinsicContentSize.width + 30), height: max(22, fs * 1.35 + 6))
    }
    private func styleField(_ f: NSTextField) {
        fieldMark.color = color; fieldMark.size = size
        f.font = .systemFont(ofSize: max(12, Annotate.fontSize(fieldMark, unit) * viewScale), weight: .bold)
        f.textColor = Annotate.color(fieldMark)
        placeField(f)
    }
    func beginText(at p: CGPoint, mark: Mark, text: String = "") {
        fieldMark = mark
        fieldMark.shape = .text(p, "")
        let f = NSTextField(frame: .zero)
        f.placeholderString = "文字"
        f.stringValue = text
        f.delegate = self
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        color = mark.color; size = mark.size
        styleField(f)
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
        onSelect?()
    }
    private func editText(_ i: Int) {
        guard case .text(let p, let s) = marks[i].shape else { return }
        let m = marks[i]
        push()
        editingOriginal = m
        selected = nil
        marks.remove(at: i)
        beginText(at: p, mark: m, text: s)
    }
    func controlTextDidChange(_ n: Notification) { if let f = field { placeField(f) } }
    func commitText() {
        guard let f = field else { return }
        field = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        let wasEditing = editingOriginal != nil
        editingOriginal = nil
        if case .text(let p, _) = fieldMark.shape, !s.isEmpty {
            if !wasEditing { push() }
            var m = fieldMark; m.shape = .text(p, s)
            marks.append(m); selected = marks.count - 1
        }
        window?.makeFirstResponder(self)
    }
    func cancelText() {
        guard let f = field else { return }
        field = nil
        f.removeFromSuperview()
        if let o = editingOriginal { marks.append(o); _ = undoStack.popLast() }   // 直しかけをやめた＝元のまま
        editingOriginal = nil
        window?.makeFirstResponder(self)
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    /// 手で描かずに書き込みを足す（テスト・見本用）
    func add(_ m: Mark) { push(); marks.append(m) }
    func setCrop(_ r: CGRect) { cropDraft = r }
}

private extension Mark {
    func with(points ps: [CGPoint]) -> Mark {
        var m = self
        if case .marker = shape { m.shape = .marker(ps) } else { m.shape = .pen(ps) }
        return m
    }
}

/// ドラッグで他のアプリへ渡すつまみ（その時点の仕上がりを PNG にして渡す）
final class DragOutView: NSView, NSDraggingSource {
    var provide: (() -> URL?)?
    private var downAt: NSPoint?
    private let icon: NSImageView
    override init(frame: NSRect) {
        icon = NSImageView(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "ドラッグ")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))!)
        super.init(frame: frame)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        toolTip = "ドラッグで他のアプリへ"
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); icon.frame = bounds }
    override func updateLayer() { layer?.borderColor = NSColor.separatorColor.cgColor }
    override var wantsUpdateLayer: Bool { true }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 3 else { return }
        downAt = nil                              // 作れなかったときも、動かすたびに作り直さない
        guard let url = provide?() else { NSSound.beep(); return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: url))
        beginDraggingSession(with: [item], event: e, source: self)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// 色の丸・太さの点（つまみの絵）
private func swatch(_ c: NSColor, size: CGFloat = 14) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 1; p.stroke()
        return true
    }
}
private func dot(_ d: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
        return true
    }
    img.isTemplate = true
    return img
}
private func gradientSwatch(_ cs: [NSColor]) -> NSImage {
    NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        if cs.count >= 2 { NSGradient(colors: cs)?.draw(in: path, angle: -70) }
        else {   // 透明＝市松
            NSColor.white.setFill(); path.fill()
            NSColor.lightGray.setFill()
            for i in 0..<4 { for j in 0..<4 where (i + j) % 2 == 0 { NSRect(x: 1 + CGFloat(i) * 4, y: 1 + CGFloat(j) * 4, width: 4, height: 4).fill() } }
        }
        NSColor.black.withAlphaComponent(0.2).setStroke(); path.lineWidth = 1; path.stroke()
        return true
    }
}

final class EditorWindow: NSWindowController, NSWindowDelegate {
    let url: URL
    let canvas: CanvasView
    let tools = NSSegmentedControl()
    let colors = NSSegmentedControl()
    let sizes = NSSegmentedControl()
    private var bgButton: NSButton!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let scroll: NSScrollView
    private var popover: NSPopover?
    private var frameObs: NSObjectProtocol?
    var onClose: (() -> Void)?
    var onSaved: ((CGImage, URL) -> Void)?
    var onPin: ((CGImage) -> Void)?
    /// 道具ごとに覚えている色（蛍光ペンは黄）
    private var toolColor: [Tool: Int] = [:]

    static let barH: CGFloat = 46

    init(image: CGImage, url: URL, unit: CGFloat) {
        self.url = url
        // 窓の幅：画像の見た目の幅（画素÷倍率）と画面の8割の小さいほう。道具が並ぶ幅は確保する
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let natural = CGFloat(image.width) / unit
        let width = max(640, min(natural, vf.width * 0.8))
        canvas = CanvasView(base: image, unit: unit, width: width)
        let barH = Self.barH
        let naturalH = CGFloat(image.height) / unit * min(1, width / natural)
        let height = max(260, min(naturalH, vf.height * 0.85 - barH * 2))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + barH * 2),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = url.deletingPathExtension().lastPathComponent
        win.contentMinSize = NSSize(width: 640, height: 260 + barH * 2)
        scroll = NSScrollView(frame: NSRect(x: 0, y: barH, width: width, height: height))
        super.init(window: win)
        win.delegate = self
        win.isReleasedWhenClosed = false

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = canvas
        scroll.autoresizingMask = [.width, .height]
        canvas.fit = scroll.contentSize
        canvas.scroll(.zero)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + barH * 2))
        root.addSubview(scroll)
        let top = makeToolBar()
        top.frame = NSRect(x: 12, y: height + barH + 7, width: width - 24, height: 32)
        top.autoresizingMask = [.width, .minYMargin]
        root.addSubview(top)
        let bottom = makeActionBar()
        bottom.frame = NSRect(x: 12, y: 7, width: width - 24, height: 32)
        bottom.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(bottom)
        win.contentView = root
        win.center()

        canvas.onToolKey = { [weak self] t in self?.choose(t) }
        canvas.onUndoKey = { [weak self] redo in if redo { self?.redoMark() } else { self?.undoMark() } }
        canvas.onSelect = { [weak self] in self?.syncStyle() }
        canvas.onChange = { [weak self] in self?.syncUndo() }
        canvas.onBaseChange = { [weak self] in self?.syncUndo() }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.backdrop = Backdrop.load()
        frameObs = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.canvas.fit = self.scroll.contentSize
        }
        scroll.postsFrameChangedNotifications = true
        choose(.arrow)
        syncUndo()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 上の段：道具（左から 選ぶ → 指す → 囲む → 描く → 書く → 隠す → 見せる → 切る）
    func makeToolBar() -> NSStackView {
        let all = Tool.allCases
        tools.segmentCount = all.count
        tools.trackingMode = .selectOne
        tools.segmentStyle = .texturedRounded
        for t in all {
            let i = t.rawValue
            let img = NSImage(systemSymbolName: t.info.symbol, accessibilityDescription: t.info.name)
                ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: t.info.name)!
            tools.setImage(img, forSegment: i)
            tools.setToolTip("\(t.info.name)（\(t.info.key.uppercased())）", forSegment: i)
            tools.setWidth(34, forSegment: i)
        }
        tools.target = self; tools.action = #selector(pickTool)
        let row = NSStackView()
        row.spacing = 8
        row.addView(tools, in: .center)
        return row
    }

    /// 下の段：色・太さ ／ 戻す・やり直す ／ 背景 ／ ドラッグ・ピン・コピー・保存
    func makeActionBar() -> NSStackView {
        colors.segmentCount = markColors.count
        colors.trackingMode = .selectOne
        for (i, c) in markColors.enumerated() {
            colors.setImage(swatch(c.color), forSegment: i)
            colors.setToolTip(c.name, forSegment: i)
            colors.setWidth(24, forSegment: i)
        }
        colors.target = self; colors.action = #selector(pickColor)
        sizes.segmentCount = markSizes.count
        sizes.trackingMode = .selectOne
        for (i, d) in [4.0, 7.0, 11.0].enumerated() {
            sizes.setImage(dot(d), forSegment: i)
            sizes.setToolTip("\(markSizes[i])（\(i + 1)）", forSegment: i)
            sizes.setWidth(26, forSegment: i)
        }
        sizes.target = self; sizes.action = #selector(pickSize)
        sizes.selectedSegment = 1

        undoButton = iconButton("arrow.uturn.backward", "戻す（⌘Z）", self, #selector(undoMark))
        redoButton = iconButton("arrow.uturn.forward", "やり直す（⇧⌘Z）", self, #selector(redoMark))
        bgButton = iconButton("photo.artframe", "背景（余白・角丸・影）", self, #selector(showBackdrop))
        let drag = DragOutView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        drag.provide = { [weak self] in self?.tempFile() }
        let pin = iconButton("pin", "画面に浮かべる", self, #selector(pinImage))
        let copy = iconButton("doc.on.doc", "コピー（⌘C）", self, #selector(copyImage))
        let save = iconButton("square.and.arrow.down", "保存（⌘S）＝元は残して「〜 編集.png」を作る", self, #selector(save), prominent: true)
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let row = NSStackView()
        row.spacing = 6
        row.addView(colors, in: .leading)
        row.addView(sizes, in: .leading)
        row.addView(undoButton, in: .leading)
        row.addView(redoButton, in: .leading)
        row.setCustomSpacing(14, after: sizes)
        row.addView(bgButton, in: .trailing)
        row.addView(drag, in: .trailing)
        row.addView(pin, in: .trailing)
        row.addView(copy, in: .trailing)
        row.addView(save, in: .trailing)
        return row
    }

    func choose(_ t: Tool) {
        if canvas.isEditingText { canvas.commitText() }
        canvas.tool = t
        tools.selectedSegment = t.rawValue
        if t != .select {
            let c = toolColor[t] ?? UserDefaults.standard.object(forKey: "editor.color.\(t.rawValue)") as? Int ?? t.defaultColor
            canvas.color = min(max(0, c), markColors.count - 1)
        }
        syncStyle()
    }

    /// 色・太さのつまみを、選んでいる書き込み（なければ次に描くもの）に合わせる
    func syncStyle() {
        if let i = canvas.selected, canvas.marks.indices.contains(i) {
            colors.selectedSegment = canvas.marks[i].color
            sizes.selectedSegment = canvas.marks[i].size
        } else {
            colors.selectedSegment = canvas.color
            sizes.selectedSegment = canvas.size
        }
    }
    func syncUndo() {
        undoButton?.isEnabled = true            // 文字の入力中・切り抜きの範囲も戻せるので常に押せる
        redoButton?.isEnabled = canvas.canRedo
    }

    @objc func pickTool() { choose(Tool(rawValue: tools.selectedSegment) ?? .arrow); focusCanvas() }
    private func focusCanvas() { if !canvas.isEditingText { window?.makeFirstResponder(canvas) } }
    @objc func pickColor() {
        let c = colors.selectedSegment
        canvas.setStyle(color: c)
        if canvas.tool != .select {
            toolColor[canvas.tool] = c
            UserDefaults.standard.set(c, forKey: "editor.color.\(canvas.tool.rawValue)")
        }
        focusCanvas()
    }
    @objc func pickSize() { canvas.setStyle(size: sizes.selectedSegment); focusCanvas() }
    @objc func undoMark() { canvas.undo(); syncStyle() }
    @objc func redoMark() { canvas.redo(); syncStyle() }

    // MARK: 背景
    @objc func showBackdrop() {
        if let p = popover, p.isShown { p.close(); return }
        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 168))
        let on = NSSwitch()
        on.state = canvas.backdrop.on ? .on : .off
        on.target = self; on.action = #selector(bgToggle(_:))
        let fills = NSSegmentedControl()
        fills.segmentCount = backdropFills.count
        fills.trackingMode = .selectOne
        for (i, f) in backdropFills.enumerated() {
            fills.setImage(gradientSwatch(f.colors), forSegment: i)
            fills.setToolTip(f.name, forSegment: i); fills.setWidth(32, forSegment: i)
        }
        fills.selectedSegment = canvas.backdrop.fill
        fills.target = self; fills.action = #selector(bgFill(_:))
        let pad = NSSlider(value: Double(canvas.backdrop.pad), minValue: 8, maxValue: 140, target: self, action: #selector(bgPad(_:)))
        pad.toolTip = "余白"
        let round = NSButton(checkboxWithTitle: "角丸", target: self, action: #selector(bgRound(_:)))
        round.state = canvas.backdrop.round ? .on : .off
        let shadow = NSButton(checkboxWithTitle: "影", target: self, action: #selector(bgShadow(_:)))
        shadow.state = canvas.backdrop.shadow ? .on : .off
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.textColor = .secondaryLabelColor; return l }
        let rows: [NSView] = [
            NSStackView(views: [label("背景"), on]),
            fills,
            NSStackView(views: [label("余白"), pad]),
            NSStackView(views: [round, shadow]),
        ]
        let col = NSStackView(views: rows)
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 12
        col.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        col.frame = v.bounds; col.autoresizingMask = [.width, .height]
        pad.widthAnchor.constraint(equalToConstant: 180).isActive = true
        v.addSubview(col)
        vc.view = v
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: bgButton.bounds, of: bgButton, preferredEdge: .maxY)
        popover = p
    }
    private func changeBackdrop(_ f: (inout Backdrop) -> Void) {
        var b = canvas.backdrop
        f(&b)
        canvas.backdrop = b
        b.store()
        bgButton.contentTintColor = b.on ? accent : nil
    }
    @objc func bgToggle(_ s: NSSwitch) { changeBackdrop { $0.on = s.state == .on } }
    @objc func bgFill(_ s: NSSegmentedControl) { changeBackdrop { $0.fill = s.selectedSegment; $0.on = true } }
    @objc func bgPad(_ s: NSSlider) { changeBackdrop { $0.pad = CGFloat(s.doubleValue.rounded()); $0.on = true } }
    @objc func bgRound(_ s: NSButton) { changeBackdrop { $0.round = s.state == .on } }
    @objc func bgShadow(_ s: NSButton) { changeBackdrop { $0.shadow = s.state == .on } }

    // MARK: 仕上がり
    /// いまの仕上がり（切り抜き中の範囲は先に確定する）
    func rendered() -> CGImage? {
        canvas.commitText()
        if canvas.cropDraft != nil { canvas.applyCrop() }
        return Annotate.render(canvas.base, canvas.marks, bg: canvas.backdrop, unit: canvas.unit)
    }

    /// 仕上がりを裏で作って渡す（縦に長い画像でも画面を止めない）
    private func renderInBackground(png: Bool, _ done: @escaping (CGImage?, Data?) -> Void) {
        canvas.commitText()
        if canvas.cropDraft != nil { canvas.applyCrop() }
        let base = canvas.base, marks = canvas.marks, unit = canvas.unit, bg = canvas.backdrop
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Annotate.render(base, marks, bg: bg, unit: unit)
            let data = png ? img.flatMap { Annotate.png($0, unit: unit) } : nil
            DispatchQueue.main.async { done(img, data) }
        }
    }
    @objc func copyImage() {
        renderInBackground(png: true) { _, data in
            guard let data else { NSSound.beep(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
            Toast.show("コピーしました", symbol: "doc.on.doc")
        }
    }
    @objc func pinImage() {
        renderInBackground(png: false) { [weak self] img, _ in
            guard let img else { NSSound.beep(); return }
            self?.onPin?(img)
        }
    }
    private var dragFile: URL?
    /// ドラッグで渡す一時ファイル（名前は「〜 編集.png」）
    func tempFile() -> URL? {
        guard let img = rendered(), let data = Annotate.png(img, unit: canvas.unit) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("つみきショット", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) 編集.png")
        guard (try? data.write(to: out)) != nil else { return nil }
        dragFile = out
        return out
    }

    /// 「〜 編集.png」として横に保存（元は残す）
    private var saving = false
    private var closed = false

    @objc func save() {
        canvas.commitText()
        if canvas.cropDraft != nil { canvas.applyCrop() }
        guard !saving else { return }
        saving = true
        canvas.locked = true
        let base = canvas.base, marks = canvas.marks, unit = canvas.unit, bg = canvas.backdrop
        window?.title = "保存中…"
        // 大きな画像でも画面が固まらないよう、焼き込みと PNG 化は裏で
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Annotate.render(base, marks, bg: bg, unit: unit)
            let data = img.flatMap { Annotate.png($0, unit: unit) }
            DispatchQueue.main.async { self.finishSave(data != nil ? img : nil, data ?? Data()) }
        }
    }

    private func finishSave(_ img: CGImage?, _ data: Data) {
        saving = false
        canvas.locked = false
        window?.title = url.deletingPathExtension().lastPathComponent
        guard let img else { failAlert("画像を作れませんでした（大きすぎる可能性があります）"); return }
        let stem = url.deletingPathExtension().lastPathComponent
        // 元の画像の隣に保存。書けない場所（App Store 版で選んだ別のフォルダの画像など）なら保存先に
        func write(in dir: URL) -> URL? {
            var out = dir.appendingPathComponent("\(stem) 編集.png")
            var n = 2
            while FileManager.default.fileExists(atPath: out.path) {
                out = dir.appendingPathComponent("\(stem) 編集 \(n).png"); n += 1
            }
            return (try? data.write(to: out, options: .withoutOverwriting)) != nil ? out : nil
        }
        guard let out = write(in: url.deletingLastPathComponent()) ?? write(in: saveDir) else {
            failAlert("保存できませんでした（保存先に書き込めません）"); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        let cb = onSaved                      // 閉じると自分が外されるので、先に控える
        if window?.isVisible == true { window?.close() }   // 保存中に閉じられていたら、もう閉じない
        cb?(img, out)
    }

    private func failAlert(_ why: String) {
        guard let w = window else { NSSound.beep(); return }
        let a = NSAlert(); a.messageText = "保存できませんでした"; a.informativeText = why
        a.beginSheetModal(for: w)
    }

    func show() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func windowWillClose(_ n: Notification) {
        popover?.close()
        if let o = frameObs { NotificationCenter.default.removeObserver(o); frameObs = nil }
        // ドラッグで渡した一時ファイルは片付ける（受け取った側は写しを持っている）
        if let f = dragFile { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: f) } }
        guard !closed else { return }
        closed = true
        onClose?()
    }
}
