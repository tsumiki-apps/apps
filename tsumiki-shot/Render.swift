// `--render <出力.png>`：画面に出さずに、範囲選択の幕・スクロールの札・撮影直後の小窓を1枚の画像に描く。
// 画面収録の許可は要らない（自分の部品を自分で描くだけ）。背景は架空の見本ページ。
import AppKit

enum Render {
    static func snapshot(_ v: NSView) -> CGImage {
        v.layoutSubtreeIfNeeded()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage!
    }

    /// HUD の代わり（画面外では NSVisualEffectView が描けないので、暗い板で近づける）
    static func hud(_ views: [NSView], size: NSSize, radius: CGFloat) -> NSView {
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.94).cgColor
        box.layer?.cornerRadius = radius
        views.forEach { box.addSubview($0) }
        return box
    }

    static func run(out: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        NSAppearance.current = NSAppearance(named: .darkAqua)
        let W = 1200, H = 760
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let page = SelfTest.makeBody(height: 2000)
        func drawPage(_ r: CGRect, offset: Int) {
            ctx.saveGState(); ctx.clip(to: r)
            let part = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: Int(r.height)))!
            ctx.draw(part, in: CGRect(x: r.minX, y: r.minY, width: CGFloat(part.width), height: r.height))
            ctx.restoreGState()
        }
        func label(_ s: String, _ x: CGFloat, _ y: CGFloat) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                               .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            let line = CTLineCreateWithAttributedString(a)
            ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
        }

        // ① 範囲選択の幕（左）
        let r1 = CGRect(x: 20, y: 40, width: 380, height: 660)
        drawPage(r1, offset: 0)
        let sel = SelectView(frame: NSRect(origin: .zero, size: r1.size), tracking: true)
        sel.start = NSPoint(x: 40, y: 560); sel.current = NSPoint(x: 330, y: 220)
        ctx.draw(snapshot(sel), in: r1)
        label("1 範囲", r1.minX, 716)

        // ② スクロール中の枠と札（真ん中）
        let r2 = CGRect(x: 420, y: 40, width: 380, height: 660)
        drawPage(r2, offset: 300)
        let area = CGRect(x: r2.minX + 30, y: r2.minY + 190, width: 320, height: 400)
        let fv = FrameView(frame: NSRect(origin: .zero, size: area.insetBy(dx: -4, dy: -4).size))
        ctx.draw(snapshot(fv), in: area.insetBy(dx: -4, dy: -4))
        let screen = NSScreen.main ?? NSScreen.screens[0]
        for (i, lost) in [false, true].enumerated() {
            let s = ScrollSession(region: Region(screen: screen, rect: area))
            let bar = s.makeBar()
            s.showState(height: lost ? 0 : 3420, lost: lost)
            let size = bar.fittingSize
            bar.frame = NSRect(origin: .zero, size: size)
            let box = hud([bar], size: size, radius: 12)
            let y = i == 0 ? area.minY - size.height - 14 : r2.minY + 10
            ctx.draw(snapshot(box), in: CGRect(x: r2.midX - size.width / 2, y: y, width: size.width, height: size.height))
        }
        label("2 スクロール（下＝速すぎ）", r2.minX, 716)

        // ③ 撮影直後の小窓（右）
        let r3 = CGRect(x: 820, y: 40, width: 360, height: 660)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.24, blue: 0.3, alpha: 1)); ctx.fill(r3)
        let shot = page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: 1600))!
        let pv = PreviewPanel()
        let (views, size) = pv.makeContent(image: shot, url: URL(fileURLWithPath: "/tmp/見本.png"))
        let box = hud(views, size: size, radius: 14)
        ctx.draw(snapshot(box), in: CGRect(x: r3.minX + 20, y: r3.minY + 20, width: size.width, height: size.height))
        label("3 撮影直後", r3.minX, 716)

        SelfTest.save(ctx.makeImage()!, to: out)
        print("OK", out)
        exit(0)
    }
}
