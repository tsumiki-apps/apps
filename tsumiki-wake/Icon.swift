// アイコン：アプリ（明るい地に積み木ひとつと、上に差す光）と、メニューバー（1色のテンプレート画像・状態で3通り）。
// どちらもコードで描く＝画像ファイルを持たない。`--icons <フォルダ>` で .iconset 用の PNG を書き出す（build.sh が .icns にする）
//   眠れる      … 線だけの積み木
//   起きている  … 塗った積み木
//   画面も      … 塗った積み木＋上に光の線3本
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

    /// 光の線3本（真上・左上・右上）。cx,cy＝光の中心、r0〜r1＝線の内側と外側
    static func rays(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r0: CGFloat, _ r1: CGFloat) {
        for deg in [-90.0, -145.0, -35.0] {
            let a = deg * .pi / 180
            c.move(to: CGPoint(x: cx + r0 * cos(a), y: cy + r0 * sin(a)))
            c.addLine(to: CGPoint(x: cx + r1 * cos(a), y: cy + r1 * sin(a)))
        }
        c.strokePath()
    }

    /// アプリのアイコン（100×100・左上原点。角丸の板を含む）
    static func drawApp(_ c: CGContext) {
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        c.setFillColor(color(0xf5f4f0)); c.fillPath()
        c.setLineJoin(.round); c.setLineCap(.round)
        c.setLineWidth(4.5); c.setStrokeColor(color(0x8a5a24)); c.setFillColor(color(0xf0e4d1))
        for f in cubeFaces(50, 40, 20) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        c.setLineWidth(5); c.setStrokeColor(color(0x1d1a15))
        rays(c, 50, 42, 16, 28)
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
    /// 積み木の位置は3通りとも同じ（状態が変わってもアイコンが跳ねない）
    static func drawMenu(_ c: CGContext, _ look: Look) {
        let (x, t, s): (CGFloat, CGFloat, CGFloat) = (50, 38, 22)
        c.setLineCap(.round); c.setLineJoin(.round)
        c.setStrokeColor(.black); c.setFillColor(.black)
        if look == .asleep {
            c.setLineWidth(7)
            for f in cubeFaces(x, t, s) { c.addLines(between: f); c.closePath() }
            c.strokePath()
            return
        }
        c.setLineWidth(8)
        for f in cubeFaces(x, t, s) { c.addLines(between: f); c.closePath(); c.drawPath(using: .fillStroke) }
        // 面の境目を抜いて立体に見せる
        c.setBlendMode(.clear); c.setLineWidth(5)
        c.move(to: CGPoint(x: x - s + 3, y: t + s / 2 + 1.5)); c.addLine(to: CGPoint(x: x, y: t + s)); c.addLine(to: CGPoint(x: x + s - 3, y: t + s / 2 + 1.5))
        c.move(to: CGPoint(x: x, y: t + s)); c.addLine(to: CGPoint(x: x, y: t + 2 * s - 4)); c.strokePath()
        c.setBlendMode(.normal)
        if look == .display { c.setLineWidth(8); rays(c, x, t + 6, 20, 34) }
    }

    static func menuImage(_ look: Look) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: 0.18, y: 0.18)
            drawMenu(c, look)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = ["眠れる", "起きている", "画面も起きている"][[Look.asleep, .system, .display].firstIndex(of: look)!]
        return img
    }

    /// 確かめる用：メニューのアイコンを size 画素で描いて、黒い画素の数を返す
    static func menuPixels(_ look: Look, size: Int = 72) -> (count: Int, data: [UInt8]) {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: 1, y: -1)
        c.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)
        drawMenu(c, look)
        let p = c.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let alpha = (0..<(size * size)).map { p[$0 * 4 + 3] }
        return (alpha.filter { $0 > 128 }.count, alpha)
    }
}
