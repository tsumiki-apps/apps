// `--selftest`：一時フォルダに架空のファイルを作り、トレイの中身の扱いを確かめる（本物のトレイの中身・設定には触らない）。
// 一番大事なのは「元のファイルを動かさない・消さない・書き換えない」こと。
// `--render <出力.png>`：棚を画面に出さずに1枚の画像に描く（配布ページ・見た目の確認用。中身は架空）。
import AppKit

enum SelfTest {
    static var failed = 0
    static func check(_ name: String, _ ok: Bool, _ note: String = "") {
        print(ok ? "✓ \(name)" : "✗ \(name) \(note)")
        if !ok { failed += 1 }
    }

    /// ファイルの「元のまま」を確かめる指紋（中身・更新日時・ファイル番号）
    static func print_(_ u: URL) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
        let d = (try? Data(contentsOf: u)) ?? Data()
        return "\(d.count)-\(d.hashValue)-\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(a[.systemFileNumber] ?? 0)"
    }

    static func samplePNG(_ w: Int = 120, _ h: Int = 90) -> Data {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pig: [UInt32] = [0xb06f26, 0xa4492f, 0x2f4f6f, 0x5d7a4a]
        for (k, v) in pig.enumerated() {
            c.setFillColor(AppIcon.color(v)); c.fill(CGRect(x: k * w / 4, y: 0, width: w / 4, height: h))
        }
        return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// 架空のファイル置き場
    static func makeFixtures(_ root: URL) -> [URL] {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root.appendingPathComponent("フォルダ_架空"), withIntermediateDirectories: true)
        let a = root.appendingPathComponent("見積書_架空.txt")
        let b = root.appendingPathComponent("写真_架空.png")
        let c = root.appendingPathComponent("フォルダ_架空")
        try! "架空の見積書です。\n金額 12,000円（架空）\n".write(to: a, atomically: true, encoding: .utf8)
        try! samplePNG().write(to: b)
        try! "中身（架空）".write(to: c.appendingPathComponent("メモ_架空.txt"), atomically: true, encoding: .utf8)
        return [a, b, c]
    }

    static func tempPasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("tsumiki-tray-test-\(UUID().uuidString)")) }

    static func run() -> Bool {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tsumiki-tray-selftest-\(getpid())")
        let storeDir = root.appendingPathComponent("store")
        let files = makeFixtures(root.appendingPathComponent("架空"))
        let (a, b, c) = (files[0], files[1], files[2])
        defer { try? fm.removeItem(at: root) }

        print("── 中身の扱い（元のファイルを守る）")
        let before = [print_(a), print_(b)]
        var s = Store(dir: storeDir); s.purgeDelay = 0
        check("本物のトレイとは別の置き場で試している", !storeDir.path.hasPrefix(Store.defaultDir.path))
        let stack = s.addFiles([a, b])!
        check("2つまとめて置くと1つの山になる", s.items.count == 1 && stack.count == 2)
        check("山の中身の場所が引ける", s.urls(stack).compactMap { $0?.resolvingSymlinksInPath().path } == [a, b].map { $0.resolvingSymlinksInPath().path })
        check("置いても元のファイルは同じ中身・同じ日時・同じファイル番号", [print_(a), print_(b)] == before)
        check("置き場（items/）に元のファイルの写しを作っていない",
              ((try? fm.contentsOfDirectory(atPath: s.itemsDir.path)) ?? []).isEmpty)

        s = Store(dir: storeDir); s.purgeDelay = 0
        check("終わって開き直しても残っている", s.items.count == 1 && s.items[0].count == 2)

        print("── 元を動かした・消したとき")
        let moved = root.appendingPathComponent("架空/フォルダ_架空/見積書_架空_移動.txt")
        try! fm.moveItem(at: a, to: moved)
        let afterMove = s.urls(s.items[0])
        check("元を別の場所に動かしても追いかける", afterMove.first??.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path,
              "\(String(describing: afterMove.first ?? nil))")
        check("動いた先が控えに書き戻される", s.items[0].paths.first?.hasSuffix("見積書_架空_移動.txt") == true)
        try! fm.removeItem(at: b)
        check("消えた元は「見つからない」になる（もう1つは引ける）", s.urls(s.items[0]).map { $0 != nil } == [true, false])
        check("1つでも残っていれば薄くしない", !s.isMissing(s.items[0]))
        try! fm.moveItem(at: moved, to: a)
        try! samplePNG().write(to: b)

        print("── 消す・ばらす")
        let only = s.addFiles([a])!
        s.remove(only.id)
        check("トレイから消しても元のファイルは残る", fm.fileExists(atPath: a.path) && s.items.count == 1)
        s.removeAll()
        check("全部消しても元のファイルは残る", fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path) && fm.fileExists(atPath: c.path))
        let three = s.addFiles([a, b, c])!
        s.split(three.id)
        check("山をばらすと3つになり、並びは同じ", s.items.map { s.title($0) } == ["見積書_架空.txt", "写真_架空.png", "フォルダ_架空"])
        check("フォルダも置ける", s.urls(s.items[2]).first??.hasDirectoryPath == true)
        s.removeAll()

        print("── 文字・URL・画像")
        let t = s.addText("打ち合わせメモ（架空）\n2行目")
        let u = s.addURL(URL(string: "https://example.com/tsumiki")!)
        let im = s.addImage(png: samplePNG())!
        check("文字を置ける", t.kind == .text && s.title(t).hasPrefix("打ち合わせメモ"))
        check("URL を置ける（名前はドメイン）", u.kind == .url && s.title(u) == "example.com")
        let imURL = s.urls(im).first ?? nil
        check("画像は中身をアプリ側に持つ", imURL.map { fm.fileExists(atPath: $0.path) && $0.path.hasPrefix(s.itemsDir.path) } == true)
        s = Store(dir: storeDir); s.purgeDelay = 0
        check("文字・URL・画像も開き直して残る", s.items.map(\.kind) == [.image, .url, .text] && s.items[2].text == "打ち合わせメモ（架空）\n2行目")
        s.remove(im.id)
        check("画像を消すとアプリ側の中身も消える", imURL.map { !fm.fileExists(atPath: $0.path) } == true)
        s.removeAll()
        let orphan = s.ownedDir(UUID())
        try? fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        s = Store(dir: storeDir)
        check("どこからも指されていない中身は起動時に片付く", !fm.fileExists(atPath: orphan.path))

        print("── ドロップの中身の見分け")
        func kind(_ fill: (NSPasteboard) -> Void) -> Payload {
            let pb = tempPasteboard(); pb.clearContents(); fill(pb)
            defer { pb.releaseGlobally() }
            return Intake.read(pb)
        }
        check("ファイル2つ", kind { $0.writeObjects([a as NSURL, b as NSURL]) } == .files([a, b]))
        check("Web の URL", kind { $0.writeObjects([URL(string: "https://example.com")! as NSURL]) } == .url(URL(string: "https://example.com")!))
        check("URL だけの文字は URL", kind { $0.setString("https://example.com/a", forType: .string) } == .url(URL(string: "https://example.com/a")!))
        check("ふつうの文字", kind { $0.setString("メモ（架空） https://example.com", forType: .string) } == .text("メモ（架空） https://example.com"))
        if case .image = kind({ $0.setData(samplePNG(), forType: .png) }) { check("画像（PNG）", true) } else { check("画像（PNG）", false) }
        if case .image = kind({ pb in pb.setData(NSImage(data: samplePNG())!.tiffRepresentation!, forType: .tiff) }) { check("画像（TIFF→PNG）", true) } else { check("画像（TIFF→PNG）", false) }
        check("空なら何もしない", kind { _ in } == .none)
        // ブラウザのリンク：URL・文字と一緒に「約束のファイル」（.webloc）も付く → URL を採る
        check("リンク＋約束のファイルは URL", kind { pb in
            pb.declareTypes([.URL, .string, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                             NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")], owner: nil)
            pb.setString("https://example.com/b", forType: .URL); pb.setString("https://example.com/b", forType: .string)
            pb.setString("com.apple.web-internet-location", forType: NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"))
        } == .url(URL(string: "https://example.com/b")!))
        check("相手がリンクしか許さなくても受ける", Intake.operation(.link) == .link)
        check("コピーを許すならコピー", Intake.operation([.copy, .move, .link]) == .copy)
        check("移動しか許さないものは受けない（元を消させない）", Intake.operation(.move) == [])

        print("── 取り出し（元を動かさない）")
        check("取り出しはコピーだけを許す（移動・削除・ゴミ箱を許さない）",
              Shelf.outgoingMask == .copy && !Shelf.outgoingMask.contains(.move) && !Shelf.outgoingMask.contains(.delete) && !Shelf.outgoingMask.contains(.generic))
        let shelf = Shelf(store: s)
        shelf.hide()
        _ = s.addFiles([a])
        shelf.announceAdded()
        check("しまっている間に入ったら、取っ手を出してまたたく（棚は出さない）", shelf.state == .tucked && shelf.tabLit)
        s.removeAll()
        let st = s.addFiles([a, b])!
        check("山は2つのファイルとして出る", shelf.writers(st).count == 2)
        try! fm.removeItem(at: b)
        check("見つからない元は出さない", shelf.writers(s.items[0]).count == 1)
        try! samplePNG().write(to: b)
        check("文字は文字として出る", shelf.writers(s.addText("架空")).first is NSString)
        check("URL は URL として出る", (shelf.writers(s.addURL(URL(string: "https://example.com")!)).first as? NSURL)?.absoluteString == "https://example.com")
        let pbF = tempPasteboard(); pbF.clearContents(); pbF.writeObjects([c as NSURL])
        let n0 = s.items.count
        check("ドロップで棚に入る", shelf.take(pbF) && s.items.count == n0 + 1 && s.items[0].kind == .files); pbF.releaseGlobally()
        shelf.dragOutEnded(s.items[0], operation: .copy)
        check("取り出したら消える（元は残る）", s.items.count == n0 && fm.fileExists(atPath: c.path))
        shelf.dragOutEnded(s.items[0], operation: [])
        check("落とすのをやめたら消えない", s.items.count == n0)
        check("棚の項目の数と画面の項目の数が同じ", shelf.trayView.list.subviews.count == s.items.count)

        print("── 位置・見張り")
        let vf = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        let r = Shelf.frames(screen: vf, right: true)
        check("右端に出る", r.shown.maxX == vf.maxX - 8 && r.shown.minX > vf.midX)
        check("縦の真ん中", abs(r.shown.midY - vf.midY) <= 1)
        check("しまうと画面の外", r.away.minX >= vf.maxX)
        check("取っ手は端に接する", r.tab.maxX == vf.maxX && r.tab.width < 20)
        let l = Shelf.frames(screen: vf, right: false)
        check("左にも出せる", l.shown.minX == vf.minX + 8 && l.away.maxX <= vf.minX && l.tab.minX == vf.minX)
        let second = NSRect(x: 1800, y: 200, width: 1440, height: 900)
        check("2枚目の画面でもその画面の右端", Shelf.frames(screen: second, right: true).shown.maxX == second.maxX - 8)
        check("一度に3つ見える高さ", Int((Shelf.size.height - 50) / (ItemCell.size.height + 4)) == 3)
        check("Fn を押しながらのドラッグでは出さない", DragWatcher.ignored(.function) && !DragWatcher.ignored([]) && !DragWatcher.ignored(.command))

        print("── アイコン")
        let png = AppIcon.png(64)
        let rep = NSBitmapImageRep(data: png)!
        check("アプリのアイコンが描ける", rep.pixelsWide == 64 && rep.colorAt(x: 32, y: 32)!.alphaComponent > 0.9)
        check("メニューバーのアイコンは1色（テンプレート）", AppIcon.menuImage().isTemplate)

        print(failed == 0 ? "自己テスト OK" : "自己テスト ✗ \(failed) 件")
        return failed == 0
    }

    // MARK: - 見本の絵

    static func render(to out: String) {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tsumiki-tray-render-\(getpid())")
        defer { try? fm.removeItem(at: root) }
        let files = makeFixtures(root.appendingPathComponent("架空"))
        let more = root.appendingPathComponent("架空/議事録_架空.txt")
        try! "議事録（架空）".write(to: more, atomically: true, encoding: .utf8)
        let empty = Store(dir: root.appendingPathComponent("empty"))
        let full = Store(dir: root.appendingPathComponent("full"))
        full.addURL(URL(string: "https://example.com/tsumiki")!)
        full.addFiles([files[1]])
        full.addText("打ち合わせは金曜 15:00（架空）")
        full.addFiles([files[0], files[1], more])
        let e = Shelf(store: empty), f = Shelf(store: full)
        // 縮小画像は裏で作られるので、少し待ってから描く
        for v in [e.trayView, f.trayView] { v.reload(selected: nil); v.display() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        f.trayView.reload(selected: full.items[1].id)

        let pad: CGFloat = 28, gap: CGFloat = 24
        let sz = Shelf.size, tab = Shelf.tabSize
        let colW = sz.width * 2 + gap + tab.width + gap
        let W = pad * 2 + colW * 2 + gap, H = pad * 2 + sz.height
        let img = NSImage(size: NSSize(width: W, height: H))
        let scale: CGFloat = 2
        let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bmp.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        for (k, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let ap = NSAppearance(named: name)!
            let x0 = pad + CGFloat(k) * (colW + gap)
            ap.performAsCurrentDrawingAppearance {
                Palette.paper.setFill()
                NSRect(x: x0 - pad / 2, y: 0, width: colW + pad, height: H).fill()
            }
            func put(_ v: NSView, _ x: CGFloat, _ y: CGFloat) {
                v.appearance = ap
                v.needsDisplay = true; v.layoutSubtreeIfNeeded()
                let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)!          // 透明の下地（角の外を白くしない）
                r.size = v.bounds.size
                v.cacheDisplay(in: v.bounds, to: r)
                let dest = NSRect(x: x, y: y, width: v.bounds.width, height: v.bounds.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: dest, xRadius: v is TabView ? 8 : 16, yRadius: v is TabView ? 8 : 16).addClip()   // 窓の外の角は透明
                r.draw(in: dest)
                NSGraphicsContext.restoreGraphicsState()
            }
            put(e.trayView, x0, pad)
            put(f.trayView, x0 + sz.width + gap, pad)
            put(f.tabView, x0 + sz.width * 2 + gap * 2, pad + (sz.height - tab.height) / 2)
        }
        NSGraphicsContext.restoreGraphicsState()
        try! bmp.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("OK \(out)")
    }
}
