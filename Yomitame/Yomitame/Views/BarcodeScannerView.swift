import SwiftUI
import AVFoundation

/// バーコードを読むだけのカメラビュー。読み取った ISBN を `onScan` に流す。
///
/// 日本の書籍は帯に **2段のバーコード**が付いている。
/// 上段が ISBN（978/979 で始まる）、下段は日本図書コード（192… の価格情報）。
/// 下段を拾うと書誌が引けないので、978/979 以外は捨てる。
struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class Coordinator: ScannerDelegate {
        private let onScan: (String) -> Void
        /// 同じ本を連続で読み続けてしまうので、一度読んだものは覚えておく
        private var seen = Set<String>()

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func scanner(didRead code: String) {
            guard code.hasPrefix("978") || code.hasPrefix("979") else { return }  // 価格コードを捨てる
            guard seen.insert(code).inserted else { return }
            AudioServicesPlaySystemSound(1057)
            onScan(code)
        }
    }
}

protocol ScannerDelegate: AnyObject {
    func scanner(didRead code: String)
}

final class ScannerViewController: UIViewController {
    weak var delegate: ScannerDelegate?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "yomitame.scanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // startRunning はブロックするのでメインスレッドで呼ばない
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }
}

extension ScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in objects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue else { continue }
            delegate?.scanner(didRead: value)
        }
    }
}
