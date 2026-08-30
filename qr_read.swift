// QRコードの中身を読む（お客様に渡す前の確認用）
//   使い方: swiftc -O -o /tmp/qr qr_read.swift && /tmp/qr <画像ファイル>
//   なぜ要るか: 2026-08-31、プロダクトキー証明書のQRが鍵のかかっていない別アプリを
//   指していた。見た目では分からないので、渡す前に必ず自分で読む。→ mistakes.md P0
import Foundation
import CoreImage

guard CommandLine.arguments.count > 1 else {
    print("使い方: qr_read <画像ファイル>"); exit(1)
}
let path = CommandLine.arguments[1]
guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
    print("画像を読めません: \(path)"); exit(1)
}
let det = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                     options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let feats = det.features(in: img)
if feats.isEmpty { print("QRコードが見つかりません"); exit(2) }
for f in feats {
    if let q = f as? CIQRCodeFeature, let s = q.messageString { print("QRの中身: \(s)") }
}
