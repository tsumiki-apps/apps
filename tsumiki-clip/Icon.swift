// アイコン：アプリ（明るい地に重なった2枚のカードと積み木ひとつ）と、メニューバー（1色のテンプレート画像）。
// どちらもコードで描く＝画像ファイルを持たない。`--icons <フォルダ>` で .iconset 用の PNG を書き出す（build.sh が .icns にする）
import AppKit

enum AppIcon {
    static func color(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// 等角の立方体（上の頂点 x,t・一辺 s）。上面・左面・右面（つみきショットと同じ形）
    static func cubeFaces(_ x: CGFloat, _ t: CGFloat, _ s: CGFloat) -> [[CGPoint]] {
        [[(x, t), (x + s, t + s / 2), (x, t + s), (x - s, t + s / 2)],
         [(x - s, t + s / 2), (x, t + s), (x, t + 2 * s), (x - s, t + 1.5 * s)],
         [(x + s, t + s / 2), (x, t + s), (x, t + 2 * s), (x + s, t + 1.5 * s)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
    }

    static func card(_ c: CGContext, _ r: CGRect, _ radius: CGFloat) {
        c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        card(c, CGRect(x: 0, y: 0, width: 100, height: 100), 22.5)
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        // 後ろのカード（前にコピーしたもの）
        c.setLineWidth(4); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xefece5))
        card(c, CGRect(x: 30, y: 17, width: 54, height: 46), 8); c.drawPath(using: .fillStroke)
        // 前のカード
        c.setLineWidth(5); c.setStrokeColor(color(0x1d1a15)); c.setFillColor(color(0xfffefb))
        card(c, CGRect(x: 16, y: 31, width: 60, height: 52), 9); c.drawPath(using: .fillStroke)
        // 積み木
        c.setLineWidth(4); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(46, 42, 12) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
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

    static func writeIconset(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for b in [16, 32, 128, 256, 512] {
            try! png(b).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b).png"))
            try! png(b * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b)@2x.png"))
        }
    }

    /// メニューバー用（18pt・テンプレート）。後ろのカードは上と右の縁だけ、前のカードは線、積み木は塗って面の境目を抜く
    static func menuImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setFillColor(.black)
            c.setLineWidth(8)
            c.move(to: CGPoint(x: 30, y: 18)); c.addLine(to: CGPoint(x: 80, y: 18))
            c.addQuadCurve(to: CGPoint(x: 90, y: 28), control: CGPoint(x: 90, y: 18))
            c.addLine(to: CGPoint(x: 90, y: 66)); c.strokePath()
            c.setLineWidth(9)
            card(c, CGRect(x: 8, y: 32, width: 68, height: 60), 12); c.strokePath()
            c.setLineWidth(6)
            for f in cubeFaces(42, 44, 14) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
            c.setBlendMode(.clear); c.setLineWidth(4)
            c.move(to: CGPoint(x: 28, y: 51)); c.addLine(to: CGPoint(x: 42, y: 58)); c.addLine(to: CGPoint(x: 56, y: 51))
            c.move(to: CGPoint(x: 42, y: 58)); c.addLine(to: CGPoint(x: 42, y: 76)); c.strokePath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "つみきクリップ"
        return img
    }
}
