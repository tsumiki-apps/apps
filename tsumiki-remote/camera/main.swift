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
  // 明るさは見た目の値（sRGB）で測る。⚠️ colorSpace: nil だと光の量そのもの（リニア）が返り、
  // 見た目 0.38 がリニア 0.12 になって、暗い・明るいの判定がずれた（2026-11-16）
  let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
  var lastY: CGFloat = -1
  // 暗いとき（夜）に重ねるコマ。Mac では露出補正・ISO・シャッターを直接いじれない（API が macOS で無効）。
  // そこで ①コマを 15fps に落として1コマの露光を伸ばし ②数コマを平均してざらつきを減らし
  // ③暗さに応じて持ち上げる（2026-11-16 本人「夜暗くなった時画質悪くなる、露出上げて」）
  var stack: [CIImage] = []
  var firstY: CGFloat = 0
  let stackN = 8          // 暗いときに重ねる枚数（15fps で約0.5秒）
  let darkBelow: CGFloat = 0.32   // これより暗ければ重ねて持ち上げる
  let target: CGFloat = 0.45      // 持ち上げる先の明るさ（見た目の値）

  // 絵全体の明るさ（0〜1）。CIAreaAverage で1画素にして読む
  func luma(_ img: CIImage) -> CGFloat {
    guard let f = CIFilter(name: "CIAreaAverage",
      parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: img.extent)]),
      let o = f.outputImage else { return 0 }
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(o, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: srgb)
    return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
  }

  // 何コマかを足して枚数で割る（動かない物はそのまま、ざらつきは √枚数 分の1に）
  func average(_ xs: [CIImage]) -> CIImage {
    guard var sum = xs.first else { return CIImage() }
    if xs.count == 1 { return sum }
    for x in xs.dropFirst() {
      sum = CIFilter(name: "CIAdditionCompositing", parameters: [kCIInputImageKey: x, kCIInputBackgroundImageKey: sum])!.outputImage!
    }
    let k = CGFloat(1) / CGFloat(xs.count)
    return sum.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
  }

  // 暗さに応じて持ち上げる（2026-11-16 夜の部屋で撮り比べて詰めた）。
  // ・倍にするだけ（露出）や全体にかける曲線だと、天井・布団が先に白く飛んだ
  // ・露出は控えめにし、暗い所だけ周りを見て持ち上げる（CIHighlightShadowAdjust の影）と自然だった
  // ・段数は 0.5 段ずつ上げ、平均が target に近いものを選ぶ。ただし広い面（ぼかした最大）が
  //   白くなりかけたらそこで止める
  func lift(_ img: CIImage, _ ev: Double) -> CIImage {
    img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
      .applyingFilter("CIColorClamp")
      .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 1.0, "inputHighlightAmount": 0.7, "inputRadius": 10])
      .cropped(to: img.extent)
  }
  // 広い面の明るさの最大（点の電球は数えない）
  func broadMax(_ img: CIImage) -> CGFloat {
    let b = img.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 40]).cropped(to: img.extent)
    guard let o = CIFilter(name: "CIAreaMaximum", parameters: [kCIInputImageKey: b, kCIInputExtentKey: CIVector(cgRect: b.extent)])?.outputImage else { return 0 }
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(o, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
    return (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
  }
  func brighten(_ img: CIImage, y: CGFloat) -> CIImage {
    var best = lift(img, 0), bestD = abs(luma(best) - target)
    for ev in stride(from: 0.5, through: 4.0, by: 0.5) {
      let o = lift(img, ev)
      if broadMax(o) > 0.9 { break }        // これ以上上げると広い面が飛ぶ
      let d = abs(luma(o) - target)
      if d < bestD { best = o; bestD = d }
    }
    return best.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04, "inputSharpness": 0.4])
      .cropped(to: img.extent)
  }

  func run() {
    guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
      ?? AVCaptureDevice.default(for: .video) else { fail("カメラが見つかりません", 4) }
    guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
      fail("カメラを開けません", 5)   // Mac の内蔵カメラは他のアプリと共有できる＝使用中でもここは通る
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
    let locked = (try? dev.lockForConfiguration()) != nil
    if locked, let f = pick { dev.activeFormat = f }
    // コマの速さをいちばん遅く（内蔵は 15fps）＝自動露出が1コマに長く光を当てられる（30fps の倍）
    if locked, let r = dev.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
      dev.activeVideoMinFrameDuration = r.maxFrameDuration
      dev.activeVideoMaxFrameDuration = r.maxFrameDuration
    }
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
    if stack.isEmpty && !steady && t < 5.0 { return }
    // 先に縮める（重ねる手間とメモリを減らす）
    var small = src
    let side = max(small.extent.width, small.extent.height)
    if side > maxSide { small = small.transformed(by: CGAffineTransform(scaleX: maxSide / side, y: maxSide / side)) }
    if stack.isEmpty { firstY = y }
    // 明るければ1コマでよい。暗ければ stackN コマ集める（受け取った絵は使い回されるので、写し取って持つ）
    if firstY < darkBelow {
      let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
      guard let cg = ctx.createCGImage(small, from: small.extent, format: .RGBAh, colorSpace: lin) else { return }
      stack.append(CIImage(cgImage: cg))
      if stack.count < stackN && t < 12 { return }
    } else {
      stack = [small]
    }
    done = true
    var img = average(stack)
    // 調整用：TSUMIKI_CAM_RAW に置き場があれば、持ち上げる前の絵（重ねただけ）を TIFF で置く
    if let raw = ProcessInfo.processInfo.environment["TSUMIKI_CAM_RAW"] {
      try? ctx.writeTIFFRepresentation(of: img, to: URL(fileURLWithPath: raw), format: .RGBAh,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }
    if firstY < darkBelow { img = brighten(img, y: firstY) }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let opt = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]
    guard let data = ctx.jpegRepresentation(of: img, colorSpace: cs, options: opt) else { fail("絵を作れません", 6) }
    // 持ち上げても暗いまま＝ほぼ写っていない見込み。写真は返すが、印（<出力>.dark）を置いて画面で知らせる
    // （持ち上げる前の明るさで決めると、見えるようになった写真にも「暗い」と出た）
    if luma(img) < 0.15 { FileManager.default.createFile(atPath: out.path + ".dark", contents: nil) }
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
