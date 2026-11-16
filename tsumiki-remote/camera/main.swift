// つみきカメラ：内蔵カメラで1枚だけ撮って JPEG に書く小さなアプリ。
// つみきリモートのサーバー（launchd の node）はカメラの許可を持てない（許可を待ったまま止まる）。
// そこで `open -W -g -n -a つみきカメラ.app --args <出力先.jpg>` で起こし、
// このアプリ自身がカメラの許可を持つ。結果は <出力先>.jpg と、失敗したら <出力先>.err。
// ⚠️ 署名は build.sh が Developer ID の鍵で付ける（同じ鍵なら作り直しても許可は残る）。
import AVFoundation
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let out = URL(fileURLWithPath: args[1])
let errURL = URL(fileURLWithPath: args[1] + ".err")
let maxSide: CGFloat = 1280   // 長い辺をここまで縮める

func fail(_ msg: String, _ code: Int32) -> Never {
  try? msg.write(to: errURL, atomically: true, encoding: .utf8)
  exit(code)
}

final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let session = AVCaptureSession()
  var start = Date()
  var done = false
  let ctx = CIContext()
  var lastY: CGFloat = -1

  // 絵全体の明るさ（0〜1）。CIAreaAverage で1画素にして読む
  func luma(_ img: CIImage) -> CGFloat {
    guard let f = CIFilter(name: "CIAreaAverage",
      parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: img.extent)]),
      let o = f.outputImage else { return 0 }
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(o, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: nil)
    return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
  }

  func run() {
    guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
      ?? AVCaptureDevice.default(for: .video) else { fail("カメラが見つかりません", 4) }
    guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
      fail("カメラを開けません（ほかのアプリが使用中かもしれません）", 5)
    }
    session.beginConfiguration()
    session.addInput(input)
    let o = AVCaptureVideoDataOutput()
    o.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    o.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam"))
    guard session.canAddOutput(o) else { fail("カメラを開けません", 5) }
    session.addOutput(o)
    session.commitConfiguration()
    // 写す形。引数3つ目（例 1760x1328）で選べる。無ければ横長でいちばん面積が大きいもの
    // （MacBook の内蔵なら 1760×1328 の 4:3）。16:9 はセンサーの上下を切り落とした形で、写る範囲が狭い
    // （2026-11-16 本人「もっと広角で」）。⚠️ activeFormat は commit の後に入れる
    let want = args.count >= 3 ? args[2] : ""
    let pick = dev.formats.filter { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return want.isEmpty ? d.width >= d.height : "\(d.width)x\(d.height)" == want
    }.max { a, b in
      let x = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
      let y = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
      return Int(x.width) * Int(x.height) < Int(y.width) * Int(y.height)
    }
    // ⚠️ Mac では startRunning が形を preset に戻す。押さえたまま（lock 中に）点けて、点けた後に放す
    let locked = pick != nil && (try? dev.lockForConfiguration()) != nil
    if locked, let f = pick { dev.activeFormat = f }
    start = Date()   // 許可の窓を待った時間は数えない
    session.startRunning()
    if locked { dev.unlockForConfiguration() }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
    // 点けた直後は真っ黒・暗い（明るさ合わせの途中）。しばらく使っていないカメラを起こした
    // 1枚目は1秒待っても真っ黒だった（2026-11-16 実測。続けて撮ると1秒で写る）。
    // そこで、明るさが落ち着く（前の枚との差が小さい）まで待つ。暗い部屋でも4秒で諦めて撮る。
    let t = Date().timeIntervalSince(start)
    if done || t < 0.6 { return }
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    let src = CIImage(cvPixelBuffer: pb)
    let y = luma(src)
    let steady = y > 0.04 && abs(y - lastY) < 0.01
    lastY = y
    if !steady && t < 4.0 { return }
    done = true
    var img = src
    let side = max(img.extent.width, img.extent.height)
    if side > maxSide { img = img.transformed(by: CGAffineTransform(scaleX: maxSide / side, y: maxSide / side)) }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let opt = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]
    guard let data = ctx.jpegRepresentation(of: img, colorSpace: cs, options: opt) else { fail("絵を作れません", 6) }
    // 4秒待っても暗いまま＝写っていない見込み。写真は返すが、印（<出力>.dark）を置いて画面で知らせる
    if y <= 0.04 { FileManager.default.createFile(atPath: out.path + ".dark", contents: nil) }
    // ⚠️ stopRunning はここ（受け取りの列の中）で呼ばない。止まることがある。exit で閉じる
    do { try data.write(to: out, options: .atomic) } catch { fail("書けません", 7) }
    exit(0)
  }
}

let g = Grab()
func go() { g.run() }
// 時間切れ：許可済みなら15秒（サーバーは20秒で待つのをやめて止めに来る）。
// 許可の問い合わせは Mac の前で押されるまで待つので長め（このときサーバーは先に諦める）
var limit: Double = 15
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized: go()
case .notDetermined:
  limit = 90
  AVCaptureDevice.requestAccess(for: .video) { ok in
    if ok { DispatchQueue.main.async { go() } } else { fail("カメラが許可されていません（Mac の設定 > プライバシー > カメラ）", 3) }
  }
default: fail("カメラが許可されていません（Mac の設定 > プライバシー > カメラ）", 3)
}
DispatchQueue.main.asyncAfter(deadline: .now() + limit) { fail("時間切れ（カメラから絵が届きません）", 8) }
RunLoop.main.run()
