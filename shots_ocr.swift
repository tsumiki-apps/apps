// 画像に焼かれた文字を読んで、入っていてはいけない語を探す道具。
// 説明書やお返事カードは公開されるので、お客様の実名・店名が画面に写っていないかを
// 出す前に確かめる。grep はPNGの中の文字を読めない。目で58枚見るのも見落とす。
//
// 使い方:
//   swift shots_ocr.swift "探す語,探す語2" <画像...>
//   swift shots_ocr.swift --dump <画像>          （読めた文字を全部出す）
//
// 見つかったら終了コード1。見つからなければ0。

import Foundation
import Vision
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("使い方: swift shots_ocr.swift \"探す語,探す語2\" <画像...>")
    exit(2)
}

let dumpMode = args[0] == "--dump"
let needles: [String] = dumpMode ? [] :
    args[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let files = Array(args.dropFirst())

func readText(_ path: String) -> [String] {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("読めません: \(path)\n".data(using: .utf8)!)
        return []
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["ja-JP", "en-US"]
    req.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req]) } catch { return [] }
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

var hitCount = 0
for f in files {
    let lines = readText(f)
    if dumpMode {
        print("── \(URL(fileURLWithPath: f).lastPathComponent)")
        lines.forEach { print("   " + $0) }
        continue
    }
    // 読み取りは字の切れ目が入ることがあるので、空白を除いた1本の文字列でも照合する
    let flat = lines.joined().replacingOccurrences(of: " ", with: "")
    for n in needles where flat.contains(n) {
        let where_ = lines.first { $0.replacingOccurrences(of: " ", with: "").contains(n) } ?? ""
        print("🔴 \(URL(fileURLWithPath: f).lastPathComponent) に「\(n)」  → \(where_)")
        hitCount += 1
    }
}

if !dumpMode {
    if hitCount == 0 {
        print("✓ \(files.count)枚を読みました。探した語は入っていません。")
    } else {
        print("\(hitCount)件 見つかりました。出す前に直してください。")
    }
}
exit(hitCount == 0 ? 0 : 1)
