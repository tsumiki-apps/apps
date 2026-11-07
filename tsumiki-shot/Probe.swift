// `--probe <出力先.png>`：本物の撮影（ScreenCaptureKit）を通した通しテスト。
// 自分で見本の長いページを窓に出し、プログラムでスクロールさせながら撮って Stitcher でつなぐ。
// 合格の条件＝できあがりの高さが（スクロールした量＋見えている高さ）×倍率 と一致すること。
// 画面収録の許可が要るので `open -W --stdout 結果.txt TsumikiShot.app --args --probe 出力.png` で起動する。
import AppKit
import ScreenCaptureKit

final class FlippedImageView: NSView {
    let image: CGImage
    init(image: CGImage, scale: CGFloat) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }
}

enum Probe {
    static func run(out: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("画面収録の許可：", CGPreflightScreenCaptureAccess() ? "あり" : "なし")
        guard CGPreflightScreenCaptureAccess() else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screen = NSScreen.main!
        let scale = screen.backingScaleFactor
        // 見本を倍率ぶん大きく描いておき、1ポイント＝倍率画素で表示（拡大のにじみなし）
        let src = SelfTest.makeBody(height: 4000)
        let big = CGContext(data: nil, width: src.width * Int(scale), height: src.height * Int(scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        big.interpolationQuality = .none
        big.draw(src, in: CGRect(x: 0, y: 0, width: big.width, height: big.height))
        let doc = FlippedImageView(image: big.makeImage()!, scale: scale)

        let viewSize = NSSize(width: 480, height: 600)
        let vf = screen.visibleFrame
        let winRect = NSRect(x: vf.midX - viewSize.width / 2, y: vf.midY - viewSize.height / 2,
                             width: viewSize.width, height: viewSize.height)
        let win = NSWindow(contentRect: winRect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = .statusBar
        let sv = NSScrollView(frame: NSRect(origin: .zero, size: viewSize))
        sv.hasVerticalScroller = false
        sv.documentView = doc
        win.contentView = sv
        win.orderFrontRegardless()

        // スクロール量（ポイント）。戻る・止まるも混ぜる
        let offsets: [CGFloat] = [0, 40, 130, 130, 300, 260, 520, 800, 1100, 1400, 1700]
        let region = Region(screen: screen, rect: win.frame)
        let cap = Capturer(region: region)
        cap.includeSelf = true
        let st = Stitcher()
        var i = 0
        var log: [String] = []
        func next() {
            guard i < offsets.count else { finish(); return }
            sv.contentView.scroll(to: NSPoint(x: 0, y: offsets[i]))
            sv.reflectScrolledClipView(sv.contentView)
            sv.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                cap.shot { img in
                    guard let img else { print("✗ 撮れない"); exit(1) }
                    let r = st.add(img)
                    log.append(SelfTest.symbol(r, scale: 1))
                    i += 1; next()
                }
            }
        }
        func finish() {
            win.orderOut(nil)
            guard let img = st.compose() else { print("✗ 合成できない"); exit(1) }
            SelfTest.save(img, to: out)
            let expect = Int(((offsets.max()! + viewSize.height) * scale).rounded())
            // ずれの合計が、実際に進んだ量（画素）と同じか
            let ok = img.height == expect && img.width == Int(viewSize.width * scale)
            print("\(ok ? "✓" : "✗") 通しテスト：\(img.width)×\(img.height)（正解 \(Int(viewSize.width * scale))×\(expect)・倍率 \(scale)）[\(log.joined(separator: " "))]")
            exit(ok ? 0 : 1)
        }
        cap.prepare { err in
            if let err { print("✗ 準備できない：", err); exit(1) }
            next()
        }
        app.run()
    }
}
