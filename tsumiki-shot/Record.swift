// 画面録画（範囲を MP4 に）と、撮った画像を画面に浮かべておく「ピン」。
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

// MARK: - MP4 に書く（録画と自己テストで共通）

final class MovieWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private(set) var frames = 0
    private var started = false
    private var lastTime = CMTime.invalid

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)   // 途中で落ちても、2秒ごとまでは再生できる
        let w = max(2, width & ~1), h = max(2, height & ~1)     // H.264 は偶数の大きさ
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 4),
                                              AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// 書き手が壊れた（容量不足・大きすぎるなど）。録画側はこれを見て止める
    var failed: Bool { writer.status == .failed }

    func append(_ pb: CVPixelBuffer, at t: CMTime) {
        if !started {
            guard writer.startWriting() else { return }        // 失敗は failed に出る
            writer.startSession(atSourceTime: t); started = true
        }
        guard input.isReadyForMoreMediaData, !lastTime.isValid || t > lastTime else { return }
        if adaptor.append(pb, withPresentationTime: t) { frames += 1; lastTime = t }
    }

    /// H.264 の大きさの上限（4096×2304）に収まる倍率
    static func fit(_ w: Int, _ h: Int) -> (Int, Int) {
        let k = min(1, 4096 / Double(max(w, h)), 2304 / Double(min(w, h)))
        return (Int(Double(w) * k) & ~1, Int(Double(h) * k) & ~1)
    }

    /// end：止めた時刻（画面が動かず最後のコマが古くても、そこまでの長さにする）
    func finish(end: CMTime?, _ done: @escaping (Bool) -> Void) {
        guard started, frames > 0, writer.status == .writing else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: writer.outputURL); done(false); return
        }
        let tail = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 30))
        writer.endSession(atSourceTime: end.map { CMTimeMaximum($0, tail) } ?? tail)
        input.markAsFinished()
        writer.finishWriting {
            let ok = self.writer.status == .completed
            if !ok { try? FileManager.default.removeItem(at: self.writer.outputURL) }   // 壊れた動画を残さない
            done(ok)
        }
    }
}

// MARK: - 録画の進行（赤い枠＋経過時間と停止の札）

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let region: Region
    let url: URL
    private let capturer: Capturer
    private var stream: SCStream?
    private var writer: MovieWriter?
    private let queue = DispatchQueue(label: "record")
    private var frameWin: NSWindow?
    private var panel: NSPanel?
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var clock: Timer?
    private var began = Date()
    private var thumb: CGImage?
    private var stopping = false            // record の列だけで触る
    private var ended = false
    var onFinish: ((URL?, CGImage?, Bool) -> Void)?    // (動画, 見出し画像, 撮れなかった)

    init(region: Region, url: URL) {
        self.region = region; self.url = url
        capturer = Capturer(region: region)
        super.init()
    }

    func start() {
        // 枠（範囲の外側）
        let fr = region.rect.insetBy(dx: -4, dy: -4)
        let fw = NSWindow(contentRect: fr, styleMask: .borderless, backing: .buffered, defer: false)
        fw.isOpaque = false; fw.backgroundColor = .clear; fw.ignoresMouseEvents = true; fw.level = .statusBar
        fw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fv = FrameView(frame: NSRect(origin: .zero, size: fr.size)); fv.warn = true
        fw.contentView = fv; fw.orderFrontRegardless(); frameWin = fw
        // 札（範囲の下。入らなければ上、それも無理なら内側の下）
        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle", accessibilityDescription: "録画中")!)
        dot.contentTintColor = .systemRed
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let stop = iconButton("stop.fill", "停止（ショートカットをもう一度でも）", self, #selector(finish))
        stop.contentTintColor = .systemRed
        dot.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        let row = NSStackView(views: [dot, timeLabel, stop]); row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        let size = row.fittingSize
        let vf = region.screen.visibleFrame
        var y = fr.minY - size.height - 10
        if y < vf.minY { y = fr.maxY + 10 }
        if y + size.height > vf.maxY { y = region.rect.minY + 10 }
        let p = NSPanel(contentRect: NSRect(x: region.rect.midX - size.width / 2, y: y, width: size.width, height: size.height),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        row.frame = fx.bounds; fx.addSubview(row)
        p.contentView = fx; p.orderFrontRegardless(); panel = p

        capturer.prepare { [weak self] err in
            guard let self, !self.ended else { return }
            guard err == nil, let filter = self.capturer.filter else { self.end(nil, failed: true); return }
            let s = self.region.scale
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = self.region.sourceRect
            // 5K など大きな画面は H.264 の上限に収まるよう縮めて撮る
            (cfg.width, cfg.height) = MovieWriter.fit(Int((self.region.rect.width * s).rounded()), Int((self.region.rect.height * s).rounded()))
            cfg.scalesToFit = true
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true
            cfg.queueDepth = 6
            do {
                self.writer = try MovieWriter(url: self.url, width: cfg.width, height: cfg.height)
                let st = SCStream(filter: filter, configuration: cfg, delegate: self)
                try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = st
                st.startCapture { e in if e != nil { DispatchQueue.main.async { self.end(nil, failed: true) } } }
            } catch { self.end(nil, failed: true); return }
            self.began = Date()
            self.clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let t = Int(Date().timeIntervalSince(self.began))
                self.timeLabel.stringValue = String(format: "%d:%02d", t / 60, t % 60)
            }
        }
    }

    // 撮れたコマ（record の列で呼ばれる）
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer,
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        guard let w = writer else { return }
        w.append(pb, at: sb.presentationTimeStamp)
        if w.failed, !stopping { stopping = true; DispatchQueue.main.async { self.finish() } }   // 書けなくなったらすぐ止めて知らせる
        if thumb == nil { thumb = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CIImage(cvPixelBuffer: pb).extent) }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.finish() }
    }

    @objc func finish() {
        guard !ended else { return }
        ended = true
        clock?.invalidate(); clock = nil
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())   // 画面のコマと同じ時計
        guard let st = stream else { end(nil, failed: false); return }
        st.stopCapture { _ in
            self.queue.async {
                guard let w = self.writer else { DispatchQueue.main.async { self.end(nil, failed: true) }; return }
                w.finish(end: endTime) { ok in
                    DispatchQueue.main.async { self.end(ok ? self.url : nil, failed: !ok) }
                }
            }
        }
    }

    private var delivered = false
    private func end(_ out: URL?, failed: Bool) {
        guard !delivered else { return }
        delivered = true; ended = true
        clock?.invalidate(); clock = nil
        frameWin?.orderOut(nil); panel?.orderOut(nil)
        stream = nil                         // SCStream が自分を抱えたままにならないように
        onFinish?(out, thumb, failed)
    }
}

// MARK: - ピン（画面にずっと浮かべておく）

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PinView: NSImageView {
    var onClose: (() -> Void)?
    let cg: CGImage
    init(image: CGImage, size: NSSize) {
        cg = image
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = NSImage(cgImage: image, size: size)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true; layer?.cornerRadius = 6; layer?.masksToBounds = true
        layer?.borderColor = accent.cgColor; layer?.borderWidth = 1
        toolTip = "ドラッグで移動・ダブルクリックか Esc で閉じる"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        if e.clickCount == 2 { onClose?() } else { window?.performDrag(with: e) }
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onClose?() } else { super.keyDown(with: e) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let c = NSMenuItem(title: "コピー", action: #selector(copyImage), keyEquivalent: ""); c.target = self; m.addItem(c)
        let x = NSMenuItem(title: "閉じる", action: #selector(closePin), keyEquivalent: ""); x.target = self; m.addItem(x)
        return m
    }
    @objc func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: .zero)])
    }
    @objc func closePin() { onClose?() }
}

/// 見た目の大きさ（画素÷倍率）で、画面の6割に収まるように浮かべる
func makePin(_ img: CGImage, unit: CGFloat, onClose: @escaping (NSPanel) -> Void) -> NSPanel {
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
    let vf = screen.visibleFrame
    var size = NSSize(width: CGFloat(img.width) / unit, height: CGFloat(img.height) / unit)
    let k = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
    size = NSSize(width: size.width * k, height: size.height * k)        // 縦横比は保つ（細長い画像は細長いまま）
    let p = PinPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height),
                     styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.isReleasedWhenClosed = false
    let v = PinView(image: img, size: size)
    v.onClose = { [weak p] in if let p { p.orderOut(nil); onClose(p) } }
    p.contentView = v
    return p
}
