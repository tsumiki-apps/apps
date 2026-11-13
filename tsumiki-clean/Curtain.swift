// 掃除中の幕：画面を夜の帳面の色で覆い（汚れが見やすい）、真ん中に残り時間と、押し続けの輪だけを出す。
// `--render out.png 幅 高さ 残り秒 押し続け(0〜1)` で画像にして見た目を確かめられる。
import AppKit

enum CurtainLook {
    static let paper: UInt32 = 0x0f0d07, ring: UInt32 = 0x443d2b, accent: UInt32 = 0xd59a4d
    static let ink: UInt32 = 0xefe8da, soft: UInt32 = 0x9f988a

    static func font(_ size: CGFloat, _ weight: String) -> NSFont {
        NSFont(name: "ZenMaruGothic-\(weight)", size: size)
            ?? NSFont(name: "HiraMaruProN-W4", size: size) ?? .systemFont(ofSize: size)
    }

    /// 左下原点の座標で描く（NSView の既定と同じ）
    static func draw(_ c: CGContext, _ size: CGSize, remain: Double, hold: Double) {
        c.setFillColor(AppIcon.color(paper)); c.fill(CGRect(origin: .zero, size: size))
        let cx = size.width / 2, cy = size.height / 2 + 14, r: CGFloat = 76
        c.setLineWidth(6); c.setLineCap(.round)
        c.setStrokeColor(AppIcon.color(ring))
        c.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); c.strokePath()
        if hold > 0 {
            c.setStrokeColor(AppIcon.color(accent))
            c.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * CGFloat(hold), clockwise: true)
            c.strokePath()
        }
        let g = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        let time = NSAttributedString(string: Core.mmss(remain), attributes: [
            .font: font(44, "Medium"), .foregroundColor: NSColor(cgColor: AppIcon.color(ink))!, .kern: 1])
        let ts = time.size()
        time.draw(at: CGPoint(x: cx - ts.width / 2, y: cy - ts.height / 2))
        let hint = NSAttributedString(string: "長押しで解除", attributes: [
            .font: font(16, "Regular"), .foregroundColor: NSColor(cgColor: AppIcon.color(soft))!])
        let hs = hint.size()
        hint.draw(at: CGPoint(x: cx - hs.width / 2, y: cy - r - 28 - hs.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func png(_ w: Int, _ h: Int, remain: Double, hold: Double) -> Data {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(c, CGSize(width: w, height: h), remain: remain, hold: hold)
        return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
    }
}

final class CurtainView: NSView {
    var remain: Double = 0 { didSet { needsDisplay = true } }
    var hold: Double = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        CurtainLook.draw(c, bounds.size, remain: remain, hold: hold)
    }
}

final class CurtainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    let view: CurtainView
    init(screen: NSScreen) {
        view = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true; hasShadow = false; ignoresMouseEvents = true; isReleasedWhenClosed = false
        backgroundColor = NSColor(cgColor: AppIcon.color(CurtainLook.paper))
        contentView = view
    }
}
