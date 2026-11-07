// アイコン：アプリ（明るい地に積み木ひとつと撮影の枠）と、メニューバー（1色のテンプレート画像）。
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

    /// 撮影の枠の四隅（100×100・左上原点）
    static func corners(_ c: CGContext, _ r: CGRect, _ arm: CGFloat) {
        for (px, py, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            c.move(to: CGPoint(x: px + dx * arm, y: py)); c.addLine(to: CGPoint(x: px, y: py)); c.addLine(to: CGPoint(x: px, y: py + dy * arm))
        }
        c.strokePath()
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        c.setLineWidth(4.5); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(50, 30, 17) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        c.setLineWidth(5); c.setStrokeColor(color(0x1d1a15))
        corners(c, CGRect(x: 18, y: 18, width: 64, height: 64), 14)
    }

    /// size×size の PNG。macOS の決まりに合わせて板は 824/1024 に縮め、下に薄い影
    static func png(_ size: Int) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size), k = s * 824 / 1024 / 100, inset = s * 100 / 1024
        c.translateBy(x: 0, y: s); c.scaleBy(x: 1, y: -1)
        c.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.3))
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.translateBy(x: inset, y: inset * 0.9); c.scaleBy(x: k, y: k)
        drawApp(c)
        c.endTransparencyLayer()
        return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// .iconset の中身（16〜512 の1倍・2倍）
    static func writeIconset(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for b in [16, 32, 128, 256, 512] {
            try! png(b).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b).png"))
            try! png(b * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b)@2x.png"))
        }
    }

    /// メニューバー用（18pt・テンプレート＝明るい/暗いメニューバーで色が自動で変わる）。
    /// 枠の四隅と、塗った積み木。面の境目は抜いて立体に見せる
    static func menuImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setFillColor(.black); c.setLineWidth(9)
            corners(c, CGRect(x: 6, y: 6, width: 88, height: 88), 24)
            c.setLineWidth(8)
            for f in cubeFaces(50, 27, 19) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
            c.setBlendMode(.clear); c.setLineWidth(5)
            c.move(to: CGPoint(x: 31, y: 36.5)); c.addLine(to: CGPoint(x: 50, y: 46)); c.addLine(to: CGPoint(x: 69, y: 36.5))
            c.move(to: CGPoint(x: 50, y: 46)); c.addLine(to: CGPoint(x: 50, y: 70)); c.strokePath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "つみきショット"
        return img
    }
}
