// アイコン：アプリ（明るい地に、トレイのくぼみに積み木ひとつ）と、メニューバー（1色のテンプレート画像）。
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

    /// トレイ（上の縁の真ん中がくぼんだ箱）。100×100・左上原点。y0＝縁の高さ
    static func trayPath(y0: CGFloat, dip: CGFloat, bottom: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 14, y: y0))
        p.addLine(to: CGPoint(x: 31, y: y0))
        p.addLine(to: CGPoint(x: 37, y: y0 + dip))
        p.addLine(to: CGPoint(x: 63, y: y0 + dip))
        p.addLine(to: CGPoint(x: 69, y: y0))
        p.addLine(to: CGPoint(x: 86, y: y0))
        p.addLine(to: CGPoint(x: 86, y: bottom - 8))
        p.addQuadCurve(to: CGPoint(x: 78, y: bottom), control: CGPoint(x: 86, y: bottom))
        p.addLine(to: CGPoint(x: 22, y: bottom))
        p.addQuadCurve(to: CGPoint(x: 14, y: bottom - 8), control: CGPoint(x: 14, y: bottom))
        p.closeSubpath()
        return p
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        // 積み木（トレイのくぼみに乗る）
        c.setLineWidth(4.5); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(50, 21, 16) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        // トレイ
        c.addPath(trayPath(y0: 50, dip: 9, bottom: 80))
        c.setFillColor(color(0xf5f4f0)); c.setStrokeColor(color(0x1d1a15)); c.setLineWidth(5)
        c.drawPath(using: .fillStroke)
    }

    /// size×size の PNG。macOS の決まりに合わせて板は 824/1024 に縮め、下に薄い影
    static func png(_ size: Int) -> Data {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
    /// トレイの線と、塗った積み木。積み木の面の境目は抜いて立体に見せる
    static func menuImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setFillColor(.black)
            c.setLineWidth(7)
            for f in cubeFaces(50, 6, 19) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
            c.setBlendMode(.clear); c.setLineWidth(5)
            c.move(to: CGPoint(x: 31, y: 15.5)); c.addLine(to: CGPoint(x: 50, y: 25)); c.addLine(to: CGPoint(x: 69, y: 15.5))
            c.move(to: CGPoint(x: 50, y: 25)); c.addLine(to: CGPoint(x: 50, y: 48)); c.strokePath()
            c.setBlendMode(.normal)
            c.addPath(trayPath(y0: 50, dip: 9, bottom: 92).copy(using: nil)!)
            c.setLineWidth(9); c.strokePath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "つみきトレイ"
        return img
    }
}
