// アイコン：アプリ（明るい地に積み木ひとつと、きらめきふたつ）と、メニューバー（1色のテンプレート画像）。
// どちらもコードで描く＝画像ファイルを持たない。`--icons <フォルダ>` で .iconset 用の PNG を書き出す（build.sh が .icns にする）
import AppKit

enum AppIcon {
    static func color(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }

    /// 等角の立方体（上の頂点 x,t・一辺 s）。上面・左面・右面
    static func cubeFaces(_ x: CGFloat, _ t: CGFloat, _ s: CGFloat) -> [[CGPoint]] {
        [[(x, t), (x + s, t + s / 2), (x, t + s), (x - s, t + s / 2)],
         [(x - s, t + s / 2), (x, t + s), (x, t + 2 * s), (x - s, t + 1.5 * s)],
         [(x + s, t + s / 2), (x, t + s), (x, t + 2 * s), (x + s, t + 1.5 * s)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
    }

    /// きらめき（四つ角の星。辺は内側へ反る）。塗りで描く
    static func sparkle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        let k = r * 0.16
        c.move(to: CGPoint(x: x, y: y - r))
        c.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x + k, y: y - k))
        c.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x + k, y: y + k))
        c.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x - k, y: y + k))
        c.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x - k, y: y - k))
        c.closePath(); c.fillPath()
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        c.setLineWidth(4.5); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(44, 34, 19) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        c.setFillColor(color(0x1d1a15))
        sparkle(c, 75, 25, 13)
        sparkle(c, 84, 47, 7)
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

    /// メニューバー用（18pt・テンプレート＝明るい/暗いメニューバーで色が自動で変わる）。線の積み木ときらめき
    static func menuImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setLineWidth(8)
            for f in cubeFaces(40, 30, 26) { c.addLines(between: f); c.closePath(); c.strokePath() }
            c.setFillColor(.black); sparkle(c, 82, 18, 16)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "つみきそうじ"
        return img
    }
}
