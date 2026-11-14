// アイコン：アプリ（明るい地に、半分に分けたウインドウと、左半分に収まった積み木）と、メニューバー（1色のテンプレート画像）。
// つみきホバー・ショットと同じく、コードで描く＝画像ファイルを持たない。`--icons <フォルダ>` で .iconset 用の PNG を書き出す（build.sh が .icns にする）
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

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        // 左半分（寄せた先）を薄く塗る
        let frame = CGRect(x: 18, y: 24, width: 64, height: 52)
        c.addPath(CGPath(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height),
                         cornerWidth: 6, cornerHeight: 6, transform: nil))
        c.setFillColor(color(0xf0e4d1)); c.fillPath()
        // ウインドウの枠と、まん中の仕切り
        c.setLineWidth(4.5); c.setStrokeColor(color(0x1d1a15))
        c.addPath(CGPath(roundedRect: frame, cornerWidth: 7, cornerHeight: 7, transform: nil)); c.strokePath()
        c.move(to: CGPoint(x: frame.midX, y: frame.minY)); c.addLine(to: CGPoint(x: frame.midX, y: frame.maxY)); c.strokePath()
        // 左半分に収まった積み木
        c.setLineWidth(4); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(34, 38, 12) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
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
        try? png(1024).write(to: URL(fileURLWithPath: "\(dir)/../icon_1024.png"))
    }

    /// メニューバー用（18pt・テンプレート）。ウインドウの枠と仕切り、左半分に積み木（許可がないときは「！」）
    static func menuImage(trusted: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(.black); c.setFillColor(.black); c.setLineWidth(8)
            c.addPath(CGPath(roundedRect: CGRect(x: 6, y: 14, width: 88, height: 72), cornerWidth: 12, cornerHeight: 12, transform: nil))
            c.strokePath()
            c.move(to: CGPoint(x: 50, y: 14)); c.addLine(to: CGPoint(x: 50, y: 86)); c.strokePath()
            if trusted {
                // 塗った積み木（面の境目を抜いて立体に見せる）
                for f in cubeFaces(28, 26, 13) { c.addLines(between: f); c.closePath() }
                c.drawPath(using: .fillStroke)
                c.setBlendMode(.clear); c.setLineWidth(4)
                c.move(to: CGPoint(x: 15, y: 32.5)); c.addLine(to: CGPoint(x: 28, y: 39)); c.addLine(to: CGPoint(x: 41, y: 32.5))
                c.move(to: CGPoint(x: 28, y: 39)); c.addLine(to: CGPoint(x: 28, y: 52)); c.strokePath()
                c.setBlendMode(.normal)
            } else {
                // 許可がない：左半分に「！」
                c.setLineWidth(10)
                c.move(to: CGPoint(x: 28, y: 30)); c.addLine(to: CGPoint(x: 28, y: 56)); c.strokePath()
                c.fillEllipse(in: CGRect(x: 22, y: 64, width: 12, height: 12))
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = trusted ? "つみきスナップ" : "つみきスナップ（許可が必要）"
        return img
    }

    /// 見本：アプリのアイコンとメニューバーの絵（許可あり・なし）を並べた PNG（確かめる用）
    static func preview(_ path: String) {
        let w = 420, h = 200
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSImage(data: png(400))!.draw(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        menuImage(trusted: true).draw(in: NSRect(x: 215, y: 55, width: 90, height: 90))
        menuImage(trusted: false).draw(in: NSRect(x: 320, y: 55, width: 90, height: 90))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
