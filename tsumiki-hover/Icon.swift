// アイコン：アプリ（明るい地に積み木ひとつとカーソル）と、メニューバー（1色のテンプレート画像）。
// どちらもコードで描く＝画像ファイルを持たない。`--icons <フォルダ>` で .iconset 用の PNG を書き出す（build.sh が .icns にする）
import AppKit

enum AppIcon {
    static func color(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// 等角の立方体（上の頂点 x,t・一辺 s）。上面・左面・右面
    static func cubeFaces(_ x: CGFloat, _ t: CGFloat, _ s: CGFloat) -> [[CGPoint]] {
        [[(x, t), (x + s, t + s / 2), (x, t + s), (x - s, t + s / 2)],
         [(x - s, t + s / 2), (x, t + s), (x, t + 2 * s), (x - s, t + 1.5 * s)],
         [(x + s, t + s / 2), (x, t + s), (x, t + 2 * s), (x + s, t + 1.5 * s)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
    }

    /// カーソル（先端 x,y・大きさ k。左上原点）
    static func pointer(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) -> [CGPoint] {
        [(0, 0), (0, 34), (9, 26), (15, 39), (21, 36), (15, 24), (27, 23)].map { CGPoint(x: x + $0.0 * k, y: y + $0.1 * k) }
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        c.setLineWidth(4.5); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(44, 18, 22) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        c.setLineWidth(4); c.setStrokeColor(color(0xf5f4f0)); c.setFillColor(color(0x1d1a15))
        c.addLines(between: pointer(58, 48, 1.05)); c.closePath(); c.drawPath(using: .fillStroke)
    }

    /// size×size の PNG。macOS の決まりに合わせて板は 824/1024 に縮め、下に薄い影
    static func png(_ size: Int) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size), inner = s * 824 / 1024, pad = (s - inner) / 2
        c.translateBy(x: 0, y: s); c.scaleBy(x: 1, y: -1)
        c.setShadow(offset: CGSize(width: 0, height: s * 0.01), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.3))
        c.translateBy(x: pad, y: pad); c.scaleBy(x: inner / 100, y: inner / 100)
        c.beginTransparencyLayer(auxiliaryInfo: nil); drawApp(c); c.endTransparencyLayer()
        let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    static func writeIconset(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for b in [16, 32, 128, 256, 512] {
            try! png(b).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b).png"))
            try! png(b * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b)@2x.png"))
        }
    }

    /// メニューバー用（18pt・テンプレート）。動いているとき＝塗った積み木、止まっているとき＝線だけの積み木
    static func menuImage(active: Bool, warn: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setFillColor(.black); c.setLineWidth(8)
            for f in cubeFaces(40, 8, 24) { c.addLines(between: f); c.closePath() }
            c.drawPath(using: active ? .fillStroke : .stroke)
            if active {           // 面の境目を抜いて立体に見せる
                c.setBlendMode(.clear); c.setLineWidth(5)
                c.move(to: CGPoint(x: 16, y: 20)); c.addLine(to: CGPoint(x: 40, y: 32)); c.addLine(to: CGPoint(x: 64, y: 20))
                c.move(to: CGPoint(x: 40, y: 32)); c.addLine(to: CGPoint(x: 40, y: 56)); c.strokePath()
                c.setBlendMode(.normal)
            }
            // カーソル：まわりを抜いてから塗る（積み木と重なっても形が見える）
            let p = pointer(60, 50, 1.2)
            c.setBlendMode(.clear); c.setLineWidth(14); c.addLines(between: p); c.closePath(); c.drawPath(using: .fillStroke)
            c.setBlendMode(.normal); c.setLineWidth(6); c.addLines(between: p); c.closePath(); c.drawPath(using: active ? .fillStroke : .stroke)
            if warn {             // 右上に点（まわりを抜いてから塗る）＝前に出せない窓がある
                let dot = CGRect(x: 72, y: 2, width: 26, height: 26)
                c.setBlendMode(.clear); c.fillEllipse(in: dot.insetBy(dx: -8, dy: -8))
                c.setBlendMode(.normal); c.fillEllipse(in: dot)
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "つみきホバー"
        return img
    }

    /// 見本：メニューバーの絵（オン・オフ）を拡大して PNG に（確かめる用）
    static func menuPreview(_ path: String) {
        let w = 200, h = 100
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        menuImage(active: true).draw(in: NSRect(x: 5, y: 5, width: 90, height: 90))
        menuImage(active: false).draw(in: NSRect(x: 105, y: 5, width: 90, height: 90))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
