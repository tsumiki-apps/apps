// 決まりごと（画面にも許可にも触らない純粋な部分）。自己テストはここを中心に確かめる。
import Foundation
import CoreGraphics

enum Core {
    /// 自動で解除するまでの秒数の選択肢・既定・上限（上限は設定ファイルを書き換えても超えない）
    static let durations: [Int] = [60, 120, 180, 300, 600]
    static let defaultDuration = 120
    static let maxDuration = 600
    /// クリック（どのボタンでも）をこの秒数押し続けると解除
    static let holdSeconds: Double = 3.0
    /// 自動解除の時刻を過ぎても掃除が続いていたら、見張り（別の糸）がアプリごと終わらせる＝入力を必ず戻す
    static let watchdogGrace: Double = 3.0

    static func clamp(_ s: Int) -> Int { s <= 0 ? defaultDuration : min(s, maxDuration) }

    static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.up)))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    // 止める入力の種類（CGEventType の番号）
    /// キー・修飾キー・メディアキー（音量・明るさなど＝NX_SYSDEFINED 14）
    static let keyTypes: [UInt32] = [10, 11, 12, 14]
    /// クリック・移動・ドラッグ・スクロール・ペン
    static let pointerTypes: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 22, 23, 24, 25, 26, 27]
    /// トラックパッドの手の動き（回転・拡大・スワイプ・強く押す など）
    static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 33, 34, 37, 38]
    /// 押し続けの判定に使う：押した／離した
    static let downTypes: Set<UInt32> = [1, 3, 25]
    static let upTypes: Set<UInt32> = [2, 4, 26]

    static var allTypes: [UInt32] { keyTypes + pointerTypes + gestureTypes }

    static var mask: CGEventMask {
        allTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }

    /// Mac が起きてからこの秒数のうちに開かれたら、自動では始めない（ログイン項目・再起動後の復元で入力が止まるのを防ぐ）
    static let bootQuiet: Double = 180

    /// 開いたときにすぐ始めるか。ログイン時に開かれた・起動直後のときは始めない
    static func shouldAutoStart(pref: Bool, loginLaunch: Bool, uptime: Double = .infinity) -> Bool {
        pref && !loginLaunch && uptime >= bootQuiet
    }
}

/// 押し続けの数え。ボタンごとに押しているかを覚え、どれか1つでも押しているあいだは数え続ける。
/// 全部離したら消す。押したまま動かしても続く
struct Hold {
    var since: Double?
    var pressed: Set<Int64> = []
    mutating func down(_ t: Double, _ button: Int64 = 0) {
        pressed.insert(button)
        if since == nil { since = t }
    }
    mutating func up(_ button: Int64 = 0) {
        pressed.remove(button)
        if pressed.isEmpty { since = nil }
    }
    func progress(_ t: Double) -> Double {
        guard let s = since else { return 0 }
        return min(1, max(0, (t - s) / Core.holdSeconds))
    }
    func done(_ t: Double) -> Bool { progress(t) >= 1 }
}
