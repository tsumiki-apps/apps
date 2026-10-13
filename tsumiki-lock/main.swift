// つみきロック — Mac の画面に全画面の幕をかけ、中（Claude・tmux）は動かしたままにする。
// 解除は Touch ID か合言葉（数字）。iPhone からはつみきリモート（server.js）経由で
// 127.0.0.1:8797 を叩いて掛け外しする。詳しくは README.md。
//
// ⚠️ これは「画面を貸さない」ための幕で、macOS のログインの鍵ではない。
//    電源の長押しで再起動されれば幕は消える（再起動後は macOS のログインが守る）。

import AppKit
import SwiftUI
import Network
import LocalAuthentication
import Security
import CommonCrypto

// MARK: - 置き場

let HOME = FileManager.default.homeDirectoryForCurrentUser
// 試験では別の置き場を使う（本番の状態・鍵に触らない）
let CONF = ProcessInfo.processInfo.environment["TSUMIKI_LOCK_CONF"].map { URL(fileURLWithPath: $0) } ?? HOME.appendingPathComponent(".tsumiki-remote")
let STATE_FILE = CONF.appendingPathComponent("lock-state.json")
let KEY_FILE = CONF.appendingPathComponent("lock-key")
let TOKEN_FILE = CONF.appendingPathComponent("token")
let PORT: UInt16 = UInt16(ProcessInfo.processInfo.environment["TSUMIKI_LOCK_PORT"] ?? "") ?? 8797
let REMOTE = ProcessInfo.processInfo.environment["TSUMIKI_REMOTE_URL"] ?? "http://127.0.0.1:8787"
// 試験用：幕を出してから N 秒で勝手に外す（本番では使わない）
let AUTO_UNLOCK = Double(ProcessInfo.processInfo.environment["TSUMIKI_LOCK_AUTOUNLOCK"] ?? "") ?? 0
// 試験用：鍵束の名前を変える（本番の合言葉に触らない）
let KC_SERVICE = ProcessInfo.processInfo.environment["TSUMIKI_LOCK_KC"] ?? "com.tsumiki.lock"

// 幕で指紋が合わない・合言葉を間違えたら iPhone に知らせる（本人の要望 2026-10-14）。
// つみきリモートと同じ ntfy の話題（~/.tsumiki-remote/ntfy-topic）。外のサーバーなので決まり文句だけ送る
// （合言葉の値・鍵・作業の題名は送らない）。試験は別の置き場＝話題が無ければ送らない
func pushPhone(_ title: String, _ body: String) {
  guard let t = try? String(contentsOf: CONF.appendingPathComponent("ntfy-topic"), encoding: .utf8)
                       .trimmingCharacters(in: .whitespacesAndNewlines),
        !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return }
  // 日本語の見出しは curl で送る（つみきリモートと同じ道）
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
  p.arguments = ["-s", "-m", "5", "-o", "/dev/null", "-H", "Title: " + title, "-H", "Tags: lock",
                 "-H", "Priority: high", "-d", body, "https://ntfy.sh/" + t]
  p.terminationHandler = { _ in }   // 終わった curl を片付ける
  try? p.run()
}

func log(_ s: String) {
  let f = ISO8601DateFormatter()
  FileHandle.standardError.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// 掛け外しの鍵（server.js と共有・0600）。無ければ作る
func lockKey() -> String {
  if let s = try? String(contentsOf: KEY_FILE, encoding: .utf8), s.count >= 32 {
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var b = [UInt8](repeating: 0, count: 32)
  _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
  let s = b.map { String(format: "%02x", $0) }.joined()
  try? FileManager.default.createDirectory(at: CONF, withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: KEY_FILE.path, contents: s.data(using: .utf8),
                                 attributes: [.posixPermissions: 0o600])
  return s
}

// MARK: - 合言葉（数字4〜8桁）。鍵束に「塩＋PBKDF2」だけを置く

enum Pin {
  static let rounds: UInt32 = 200_000

  static func derive(_ pin: String, salt: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    let p = Array(pin.utf8)
    _ = p.withUnsafeBufferPointer { pp in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                           UnsafeRawPointer(pp.baseAddress!).assumingMemoryBound(to: Int8.self), p.count,
                           salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                           rounds, &out, out.count)
    }
    return out
  }

  // ⚠️ 鍵束はこのキューでしか触らない。鍵束が「許可しますか」で止まったとき、
  //    主のスレッド（幕・iPhone からの解除の口）まで止まらないようにする（反証役）
  static let q = DispatchQueue(label: "com.tsumiki.lock.pin")

  enum Read { case ok([UInt8]), missing, failed }

  // 保存の形：[長さ1][塩16][鍵32]。q の上で呼ぶ
  static func load() -> Read {
    let qq: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: KC_SERVICE, kSecAttrAccount as String: "pin",
                             kSecReturnData as String: true]
    var r: CFTypeRef?
    let st = SecItemCopyMatching(qq as CFDictionary, &r)
    if st == errSecItemNotFound { return .missing }
    guard st == errSecSuccess, let d = r as? Data, d.count == 49 else { return .failed }
    return .ok(Array(d))
  }

  // 主のスレッドで読む写し。読めなかったとき（failed）は前の値のまま＝覚え違いを作らない
  static var isSet = false
  // 塩と鍵の写し（主のスレッドだけで触る）。幕の上で合言葉を確かめるときは鍵束を読まず、これと比べる
  // ＝鍵束が「許可しますか」で止まっても、Mac の前の合言葉は効く（反証役）
  static var blob: [UInt8]?
  static func refresh(_ done: (() -> Void)? = nil) {
    q.async {
      let r = load()
      DispatchQueue.main.async {
        switch r {
        case .ok(let b): isSet = true; blob = b
        case .missing: isSet = false; blob = nil
        case .failed: log("鍵束が読めません")
        }
        done?()
      }
    }
  }

  static func set(_ pin: String) -> Bool {
    guard (4...8).contains(pin.count), pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    var salt = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, 16, &salt)
    let blob = Data([UInt8(pin.count)] + salt + derive(pin, salt: salt))
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: KC_SERVICE, kSecAttrAccount as String: "pin"]
    // ⚠️ 先に消さない。書き換え（Update）を先に試し、無ければ足す。消してから足すと、
    //    足すのに失敗したとき合言葉が無いのに「ある」ことになり、そのまま掛けられた（反証役）
    let up = SecItemUpdate(q as CFDictionary, [kSecValueData as String: blob] as CFDictionary)
    if up == errSecSuccess { return true }
    guard up == errSecItemNotFound else { return false }
    var add = q
    add[kSecValueData as String] = blob
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  // 写し（blob）と比べる。鍵束は読まないので、どのキューで呼んでもよい
  static func check(_ pin: String, against b: [UInt8]) -> Bool {
    guard b.count == 49 else { return false }
    let salt = Array(b[1..<17]), want = Array(b[17..<49])
    let got = derive(pin, salt: salt)
    var diff: UInt8 = 0
    for i in 0..<32 { diff |= got[i] ^ want[i] }   // 時間を一定にする比べ方
    return diff == 0
  }
}

// MARK: - 状態（幕が落ちて立ち上がっても、掛かっていたら掛け直す）

struct Persist: Codable { var locked: Bool; var since: Double; var fails: Int; var waitUntil: Double }

struct Seat: Identifiable { let id: String; let title: String; let status: String }

final class Model: ObservableObject {
  @Published var locked = false
  @Published var since = Date()
  @Published var typed = ""
  @Published var shake = 0
  @Published var note = ""
  @Published var seats: [Seat] = []
  @Published var now = Date()
  @Published var waitUntil = Date.distantPast
  @Published var checking = false
  // 合言葉の欄を出すか。ふだんは Touch ID だけ。Touch ID が断ったとき（指が合わない・
  // ロックアウト・使えない）に出す。外れたら隠し直す
  @Published var showPin = false
  @Published var showPad = false   // マウスで打つ数字の板（合言葉の欄の左端で出し入れ）
  @Published var armed = false   // Touch ID を待ち受けている（指を置けば外れる）
  // 指紋の絵の結末："" ＝待ち受け／"ok" ＝通った（緑に満ちる）／"ng" ＝通らなかった（赤く揺れる）
  @Published var scan = ""
  @Published var scanAt = Date()
  var renderAt: Date? = nil   // 見本の書き出し用
  var fails = 0

  func load() {
    guard let d = try? Data(contentsOf: STATE_FILE) else { return }   // 無い＝初めて
    guard let p = try? JSONDecoder().decode(Persist.self, from: d) else {
      log("状態ファイルが読めない → 掛かっているものとして扱う")
      locked = true; return
    }
    locked = p.locked; since = Date(timeIntervalSince1970: p.since)
    fails = p.fails; waitUntil = Date(timeIntervalSince1970: p.waitUntil)
  }
  func save() {
    let p = Persist(locked: locked, since: since.timeIntervalSince1970, fails: fails, waitUntil: waitUntil.timeIntervalSince1970)
    if let d = try? JSONEncoder().encode(p) {
      try? d.write(to: STATE_FILE, options: .atomic)
      chmod(STATE_FILE.path, 0o600)
    }
  }
}

// MARK: - 見た目（DESIGN.md のダーク）

extension Color {
  init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
  static let paper = Color(hex: 0x0f0d07), surface = Color(hex: 0x211d14), surface2 = Color(hex: 0x2b2619)
  static let ink = Color(hex: 0xefe8da), mid = Color(hex: 0xa89e8b), accent = Color(hex: 0xd59a4d)
  static let good = Color(hex: 0x7fae82), goodWash = Color(hex: 0x23301f), warn = Color(hex: 0xd9825a)
}

func zen(_ size: CGFloat, _ bold: Bool = false) -> Font {
  .custom(bold ? "ZenMaruGothic-Bold" : "ZenMaruGothic-Medium", size: size)
}

struct Curtain: View {
  @ObservedObject var m: Model
  let onKey: (String) -> Void
  let onTouch: () -> Void
  let touchOK: Bool

  var clock: String { let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: m.now) }
  var day: String { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月d日 EEEE"; return f.string(from: m.now) }
  var waitLeft: Int { max(0, Int(ceil(m.waitUntil.timeIntervalSince(m.now)))) }

  var body: some View {
    GeometryReader { g in
      let u = min(g.size.width / 1440, g.size.height / 900) // 1440×900 を基準に伸び縮み
      lockScreen(g.size, u)
    }
  }

  // 待機の画面：全体を中央そろえ。時計は上、Touch ID の丸は画面のちょうど真ん中（本人の指定）、
  // 状態の札は下。合言葉の欄は Touch ID が通らなかったときだけ（lockScreen の真ん中が入れ替わる）
  // macOS のロック画面に寄せた形（本人の指定）：上に日付と大きな時刻、下に人の丸と横長の欄。
  // 欄はふだん「Touch ID で解除」（指を置けば外れる・常に待ち受け）。Touch ID が通らなかったとき
  // （か Esc）だけ、同じ欄が合言葉の入力欄に変わる（キーボードで数字＋Enter）。作業の数は一番下に小さく
  var usePin: Bool { m.showPin || !touchOK }

  func lockScreen(_ size: CGSize, _ u: CGFloat) -> some View {
    // 日付の下〜真ん中〜札の上を同じ間にする（上下の Spacer を同じ重さに・本人の指定）。
    // 真ん中はふだん動く指紋、合言葉のときは入力欄。知らせの文字は下に重ねるだけ＝間を崩さない
    VStack(spacing: 0) {
      Text(clock).font(zen(120 * u, true)).foregroundColor(.ink).monospacedDigit()
      Text(day).font(zen(26 * u)).foregroundColor(.mid).padding(.top, 4 * u)
      Spacer(minLength: 24 * u)
      Group {
        if usePin { field(u) } else {
          Button(action: onTouch) {
            ScanPrint(scan: m.scan, scanAt: m.scanAt, at: m.renderAt)
              .frame(width: 92 * u, height: 92 * u).contentShape(Circle())
          }.buttonStyle(.plain)
        }
      }
      .overlay(alignment: .bottom) {
        let padOn = usePin && (m.showPad || !touchOK)
        Text(waitLeft > 0 ? "\(waitLeft) 秒 お待ちください" : m.checking ? "確かめています" : m.note)
          .font(zen(16 * u)).foregroundColor(.warn).fixedSize().offset(y: padOn ? -70 * u : 34 * u)
      }
      Spacer(minLength: 24 * u)
      // 数字の板を出しているあいだは札を隠す（板と重なるため。場所は残して真ん中の位置を変えない）
      chips(u).opacity(usePin && (m.showPad || !touchOK) ? 0 : 1)
    }
    .padding(.top, 70 * u).padding(.bottom, 80 * u)
    .frame(width: size.width, height: size.height)
    .background(Color.paper)
  }

  // 合言葉の欄（usePin のときだけ出る）。キーボードで数字＋Enter。マウスだけでも打てるよう、
  // 左端の枡の絵で小さな数字の板を出し入れできる（Touch ID が使えないときは最初から出す・反証役）
  func field(_ u: CGFloat) -> some View {
    let w = 250 * u, h = 38 * u
    return HStack(spacing: 0) {
      // Touch ID が使えないときは板が常に出ている＝押しても変わらないので隠す（場所は残す）
      Button(action: { m.showPad.toggle() }) {
        Image(systemName: "circle.grid.3x3").font(.system(size: 14 * u)).foregroundColor(.mid)
          .frame(width: 28 * u, height: 28 * u).contentShape(Circle())
      }.buttonStyle(.plain).padding(.leading, 6 * u).opacity(touchOK ? 1 : 0).disabled(!touchOK)
      ZStack(alignment: .leading) {
        if m.typed.isEmpty {
          // 打つ前は「合言葉を入力」だけ（文字は最小限）。Esc で指紋に戻る
          Text("合言葉を入力").font(zen(14 * u)).foregroundColor(.mid.opacity(0.8))
        } else {
          HStack(spacing: 7 * u) {
            ForEach(0..<m.typed.count, id: \.self) { _ in Circle().fill(Color.ink).frame(width: 8 * u, height: 8 * u) }
          }
        }
      }
      .padding(.leading, 6 * u)
      Spacer(minLength: 0)
      // 右端の丸：打ったときだけ →（決定）。指紋のボタンは置かない（本人「不要」）
      Button(action: { onKey("enter") }) {
        ZStack {
          Circle().fill(Color.ink.opacity(0.18))
          Image(systemName: "arrow.right").font(.system(size: 13 * u, weight: .semibold)).foregroundColor(.ink)
        }.frame(width: 28 * u, height: 28 * u).contentShape(Circle())
      }.buttonStyle(.plain).opacity(m.typed.isEmpty ? 0 : 1).disabled(m.typed.isEmpty).padding(.trailing, 5 * u)
    }
    .frame(width: w, height: h)
    .background(Capsule().fill(m.scan == "ok" ? Color.good.opacity(0.25) : Color.ink.opacity(0.08)))
    .offset(x: m.shake % 2 == 1 ? 10 * u : 0)
    .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: m.shake)
    .opacity(waitLeft > 0 ? 0.4 : 1)
    // 数字の板は欄の下に重ねる（中央の位置を崩さない）
    .overlay(alignment: .top) {
      if m.showPad || !touchOK {
        let ks = max(46 * u, 44)   // 小さい画面でも押せる大きさ（44 より小さくしない・反証役）
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(ks), spacing: 10 * u), count: 3), spacing: 8 * u) {
          ForEach(["1","2","3","4","5","6","7","8","9","del","0","enter"], id: \.self) { k in
            Button(action: { onKey(k) }) {
              ZStack {
                Circle().fill(k == "del" ? Color.clear : k == "enter" ? Color.accent : Color.surface2)
                if k == "del" { Image(systemName: "delete.left").font(.system(size: 16 * u)).foregroundColor(.mid) }
                else if k == "enter" { Image(systemName: "arrow.right").font(.system(size: 15 * u, weight: .semibold)).foregroundColor(.paper) }
                else { Text(k).font(zen(20 * u, true)).foregroundColor(.ink) }
              }.frame(width: ks, height: ks).contentShape(Circle())
            }.buttonStyle(.plain)
          }
        }
        .offset(y: h + 18 * u)
      }
    }
  }

  // 状態ごとの数（作業の題名は出さない＝お客様の名前が入ることがある）
  func chips(_ u: CGFloat) -> some View {
    HStack(spacing: 14 * u) {
      ForEach(["busy", "waiting", "idle", "paused"], id: \.self) { st in
        let n = m.seats.filter { $0.status == st }.count
        if n > 0 {
          HStack(spacing: 12 * u) {
            Circle().fill(dot(st)).frame(width: 14 * u, height: 14 * u)
              .overlay(Circle().stroke(wash(st), lineWidth: 5 * u))
            Text(label(st)).font(zen(20 * u)).foregroundColor(.mid)
            Text("\(n)").font(zen(24 * u, true)).foregroundColor(.ink).monospacedDigit()
          }
          .padding(.horizontal, 20 * u).padding(.vertical, 12 * u)
          .background(RoundedRectangle(cornerRadius: 14 * u).fill(Color.surface))
        }
      }
    }
  }



  func dot(_ s: String) -> Color { s == "busy" ? .good : s == "waiting" ? .accent : .mid }
  func wash(_ s: String) -> Color { s == "busy" ? .goodWash : .surface2 }
  func label(_ s: String) -> String { ["busy": "作業中", "waiting": "返答待ち", "idle": "待機", "paused": "中断"][s] ?? "" }
}

// MARK: - 指紋（Apple の Touch ID の記号そのもの）
struct ScanPrint: View {
  let scan: String
  let scanAt: Date
  var at: Date? = nil   // 見本の書き出し用：時刻を決め打ちにする

  // ふだんは止まった橙の指紋（本人の指定：動くのは指を置いたときだけ）。
  // 通った：橙の上に、中心から緑が広がって満ちる（0.35秒）／合わなかった：赤くなって揺れる。
  // Touch ID は「指が触れた瞬間」を知らせないので、指を置いたあとの結果で動かす
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scan.isEmpty && at == nil)) { tl in
      let date = at ?? tl.date
      let since = max(0, date.timeIntervalSince(scanAt))
      let grow = scan == "ok" ? min(1, since / 0.35) : 0
      GeometryReader { g in
        let d = g.size.width
        let mark = Image(systemName: "touchid").font(.system(size: d * 0.56, weight: .light))
        ZStack {
          Circle().fill(scan == "ok" ? Color.goodWash : Color.surface2)
          mark.foregroundColor(scan == "ng" ? Color.warn : Color.accent)
          if scan == "ok" {
            mark.foregroundColor(Color.good)
              .mask(Circle().frame(width: d * 0.7 * grow, height: d * 0.7 * grow))
          }
        }
        .scaleEffect(scan == "ok" ? 1 + 0.06 * sin(min(1, since / 0.35) * .pi) : 1)
        .offset(x: scan == "ng" ? CGFloat(sin(since * 40) * max(0, 1 - since / 0.5) * 6) : 0)
      }
    }
  }
}

// MARK: - 幕の窓

final class CurtainWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class App: NSObject, NSApplicationDelegate {
  let m = Model()
  var windows: [NSWindow] = []
  var listener: NSListener?
  var timer: Timer?
  var keyMon: Any?
  var authing = false
  var authCtx: LAContext?
  var status: NSStatusItem?
  let key = lockKey()
  var touchOK = false
  var checkToken: UUID?
  var lastAuthEnd = Date.distantPast
  var failStreak = 0
  var fingerFails = 0   // 続けて指が合わなかった数（3で合言葉へ）
  var lastFingerFail = Date.distantPast
  var lastErr: LAError.Code?
  var authStart = Date.distantPast
  var lastFrontName = "", lastFrontLog = Date.distantPast
  // iPhone への知らせ：1回の掛けにつき5分に1回まで（指を何度も置かれても鳴り続けない）。
  // 黙っていた分は5分たったら1通にまとめる（morningReport）
  var lastAlert = Date.distantPast, quietAlerts = 0
  // 夜（22時〜8時・つみきリモートと同じ）は鳴らさず数えるだけ。朝8時を過ぎたら1通にまとめて送る（本人の選択）。
  // 数えはメモリだけ（夜のあいだに幕のアプリが起き直すと消える）
  var nightTally: [String: Int] = [:]
  var morningTimer: Timer?
  func isNight(_ d: Date = Date()) -> Bool {
    if let f = ProcessInfo.processInfo.environment["TSUMIKI_LOCK_NIGHT"], KC_SERVICE != "com.tsumiki.lock" {   // 試験用
      return FileManager.default.fileExists(atPath: f)
    }
    let h = Calendar.current.component(.hour, from: d); return h < 8 || h >= 22 }
  func morningReport() {
    // 昼の5分の間引きで黙っていた分は、5分たったら1通にして出す（次の失敗が来なくても届く・反証役）
    if !isNight(), quietAlerts > 0, Date().timeIntervalSince(lastAlert) >= 300 {
      let n = quietAlerts; quietAlerts = 0; lastAlert = Date()
      log("iPhone に知らせた：そのあとの失敗 \(n) 回")
      pushPhone("Mac の幕", "そのあとも失敗が \(n) 回ありました")
    }
    guard !isNight(), !nightTally.isEmpty else { return }
    let parts = ["指紋": "指紋が合わない", "ロック": "Touch ID のロック", "合言葉": "合言葉ちがい"]
      .compactMap { k, v in nightTally[k].map { "\(v) \($0) 回" } }.sorted()
    nightTally = [:]
    log("iPhone に知らせた：夜のあいだの失敗（\(parts.joined(separator: "・"))）")
    pushPhone("Mac の幕（夜のあいだ）", parts.joined(separator: "・") + " がありました")
  }

  // 幕の高さ。常に一番上（どのアプリの全画面の窓より上）。Touch ID の確認（coreautha・1000）は
  // 幕の裏に隠れたまま待ち受ける（touch() の説明）
  let topLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

  func checkTouch() {
    var e: NSError?
    let now = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    if now != touchOK {
      touchOK = now
      // 画面は幕を作ったときの値を写して持つ。変わったら作り直す（Touch ID が使えなくなったのに
      // 待機の画面のまま、見えない板に打つことになるのを防ぐ・反証役）
      if m.locked && !windows.isEmpty { log("Touch ID が使える／使えないが変わった（\(now)）→ 幕を描き直す"); showCurtain() }
    }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.setActivationPolicy(.accessory)
    // launchd が作る記録は 0644 になる。前に出たアプリの名前や時刻が残るので自分だけに
    chmod(CONF.appendingPathComponent("lock.log").path, 0o600)
    m.load()
    checkTouch()
    Pin.refresh()
    startServer()
    makeStatusItem()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      if self?.m.locked == true { self?.showCurtain() }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.reassert()
    }
    // ほかのアプリが前に出たら、Touch ID の確認中でも打ち切って前に戻る。
    // 確認の窓を出したまま ⌘Tab で裏のアプリに移り、見えないまま打つ道を塞ぐ（反証役）
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
      guard let self = self, self.m.locked,
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      if a.processIdentifier == ProcessInfo.processInfo.processIdentifier || self.isAuthAgent(a)
          || a.bundleIdentifier == Bundle.main.bundleIdentifier { return }   // 自分（試験で2つ動かしたとき）は数えない
      // 記録は同じアプリなら10秒に1行（前に出続けるアプリと並んでも記録が膨らまない・反証役）
      let name = a.localizedName ?? "?"
      if name != self.lastFrontName || Date().timeIntervalSince(self.lastFrontLog) > 10 {
        log("ほかのアプリが前に出た（\(name)）→ 前に戻る")
        self.lastFrontName = name; self.lastFrontLog = Date()
      }
      self.endAuth()
      self.reassert()
    }
    if m.locked { log("起動時に幕が掛かっていた → 掛け直す"); showCurtain() }
    // 朝のまとめは幕が外れていても送る（幕の tick は掛けているあいだしか回らないので別に回す）
    morningTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.morningReport() }
  }

  func isAuthAgent(_ a: NSRunningApplication) -> Bool {
    let n = a.executableURL?.lastPathComponent ?? a.localizedName ?? ""
    // 実物は coreautha（com.apple.LocalAuthentication.UIAgent）＝この Mac で確認
    return n == "coreautha" || a.bundleIdentifier == "com.apple.LocalAuthentication.UIAgent"
  }

  // メニューバーの鍵（Mac の前で掛けるとき）
  func makeStatusItem() {
    let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    s.button?.image = NSImage(systemSymbolName: "lock", accessibilityDescription: "つみきロック")
    let menu = NSMenu()
    let it = NSMenuItem(title: "今すぐロック", action: #selector(menuLock), keyEquivalent: "")
    it.target = self
    menu.addItem(it)
    s.menu = menu
    status = s
  }
  @objc func menuLock() {
    if !Pin.isSet { alertNoPin(); return }
    lock(by: "メニュー")
  }
  func alertNoPin() {
    let a = NSAlert()
    a.messageText = "先に合言葉を決めてください"
    a.informativeText = "つみきリモートの ⋯ → Mac の幕 で決められます"
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }

  // MARK: 掛け外し

  func lock(by who: String) {
    guard !m.locked else { return }
    Pin.refresh()
    m.locked = true; m.since = Date(); m.typed = ""; m.note = ""; m.showPin = false; m.showPad = false
    fingerFails = 0
    lastAlert = .distantPast; quietAlerts = 0
    m.save()
    log("ロック（\(who)）")
    showCurtain()
  }

  func unlock(by who: String) {
    guard m.locked else { return }
    endAuth()
    m.locked = false; m.typed = ""; m.fails = 0; m.waitUntil = .distantPast; m.checking = false
    m.showPin = false; m.showPad = false
    failStreak = 0; lastErr = nil; fingerFails = 0
    m.save()
    log("解除（\(who)）")
    hideCurtain()
  }

  func showCurtain() {
    checkTouch()
    windows.forEach { $0.orderOut(nil) }
    windows = NSScreen.screens.map { sc in
      let w = CurtainWindow(contentRect: sc.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      w.level = topLevel
      w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
      w.isOpaque = true
      w.backgroundColor = NSColor(red: 0x0f / 255, green: 0x0d / 255, blue: 0x07 / 255, alpha: 1)
      w.hasShadow = false
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: Curtain(m: m, onKey: { [weak self] k in self?.press(k) },
                                                     onTouch: { [weak self] in self?.touch() }, touchOK: touchOK))
      w.setFrame(sc.frame, display: true)
      w.makeKeyAndOrderFront(nil)
      return w
    }
    clampDown()
    if keyMon == nil {
      keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
        guard let self = self, self.m.locked else { return e }
        if !self.m.showPin && self.touchOK {
          // Esc は確認の窓に届けば userCancel で板になる。幕が前にいて届かないときもここで板にする
          if e.keyCode == 53 { self.toPin(); return nil }
          self.touch(); return nil
        }
        if e.keyCode == 53 { self.backToTouch(); return nil }            // Esc：指紋に戻る（反証役）
        if e.keyCode == 51 { self.press("del") }                         // ⌫
        else if e.keyCode == 36 || e.keyCode == 76 {                      // Enter：打っていれば決定（空なら何もしない）
          if !self.m.typed.isEmpty { self.press("enter") }   // 空の Enter では確認を始めない（数字が確認の窓に取られる）
        }
        else if let c = e.charactersIgnoringModifiers, c.count == 1, c.first!.isNumber, c.first!.isASCII { self.press(c) }
        return nil   // 幕の上では、ほかのキーは全部捨てる
      }
    }
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }
    tick()
    pollSeats()
    if AUTO_UNLOCK > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + AUTO_UNLOCK) { [weak self] in self?.unlock(by: "試験の自動解除") }
    }
  }

  // 前に出て、切り替え・強制終了・Dock・メニューを止める
  func clampDown() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                 .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
    windows.first?.makeKey()
  }

  // ⚠️ Touch ID の待ち受け中は前に出ない（activate しない）。幕のアプリが前に出ると、確認の窓
  // （coreautha）が数十ミリ秒で指の読み取りを止める＝指を置いても何も起きない（2026-10-14 本人の実機で
  // 指が全く効かなくなった・反証役が log show の biometrickitd で裏を取った）。窓を上に重ねるだけ
  // （orderFrontRegardless）なら止まらない（10/13 夜の版で通っていた）
  func reassert() {
    guard m.locked, !authing else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self = self, self.m.locked, !self.authing else { return }
      self.windows.forEach { $0.level = self.topLevel; $0.orderFrontRegardless() }
      self.clampDown()
    }
  }

  func hideCurtain() {
    timer?.invalidate(); timer = nil
    if let k = keyMon { NSEvent.removeMonitor(k); keyMon = nil }
    NSApp.presentationOptions = []
    windows.forEach { $0.orderOut(nil) }
    windows = []
    NSApp.hide(nil)
  }

  var lastPoll = Date.distantPast
  var tickCount = 0
  func tick() {
    // 時計は分が変わったときだけ描き直す（待たせている秒を数えているときは毎回）。
    // 0.5秒ごとに m.now を変えると、幕の全体を描き直し続けて CPU を約9%使っていた（実測）
    let now = Date()
    let minuteChanged = Int(now.timeIntervalSince1970 / 60) != Int(m.now.timeIntervalSince1970 / 60)
    // 待たせる秒を出しているあいだ（m.now がまだ waitUntil より前）は毎回。明けた最初の回にも入れて
    // 「1 秒 お待ちください」を残さない（反証役）
    if minuteChanged || m.waitUntil > m.now || !m.locked { m.now = now }
    guard m.locked else { return }
    // 幕はいちばん上の高さにいるので、前に出し直すのは2秒に1回で足りる（0.5秒ごとだと
    // WindowServer の仕事が増え続ける・反証役の指摘で測った）
    tickCount += 1
    if tickCount % 4 == 0 { windows.forEach { $0.orderFrontRegardless() } }
    if !authing && !NSApp.isActive { reassert() }
    // Touch ID は常に待ち受ける（本人の要望）。合言葉の板を出しているあいだは待ち受けない
    // （待ち受け中はキーが確認の窓に取られ、合言葉が打てないため）
    if !authing && !m.showPin { touch() }
    if now.timeIntervalSince(lastPoll) >= 3 { lastPoll = now; pollSeats() }
  }

  // MARK: 合言葉・Touch ID

  func alertPhone(_ what: String, kind: String) {
    guard m.locked else { return }
    if isNight() { nightTally[kind, default: 0] += 1; return }
    if Date().timeIntervalSince(lastAlert) < 300 { quietAlerts += 1; return }
    lastAlert = Date()
    log("iPhone に知らせた：\(what)")
    pushPhone("Mac の幕", what)
  }

  func press(_ k: String) {
    guard m.locked, Date() >= m.waitUntil, !m.checking else { return }
    guard m.showPin || !touchOK else { return }   // 板が隠れているあいだは数字を受けない
    m.note = ""
    if k == "del" { if !m.typed.isEmpty { m.typed.removeLast() }; return }
    if k == "enter" { if m.typed.count >= 4 { tryPin() } else if !m.typed.isEmpty { m.note = "4桁以上です" }; return }
    guard m.typed.count < 8 else { return }
    m.typed += k
  }

  // 鍵束は別のキューで確かめる（主のスレッドを止めない）
  // PBKDF2（20万回）は重いので別のキューで。鍵束は読まない（Pin.blob の写しと比べる）
  let checkQ = DispatchQueue(label: "com.tsumiki.lock.check")
  func tryPin() {
    let t = m.typed
    guard let b = Pin.blob else {
      // 写しが無い＝鍵束が読めていない。まちがいとして数えない（数えると正しい合言葉でも待たされる）
      m.typed = ""
      m.note = touchOK ? "合言葉を読めません。Esc で指紋に戻れます" : "合言葉を読めません。iPhone から外してください"
      Pin.refresh()
      return
    }
    m.checking = true
    // 万一返ってこなくても、5秒で入力を戻す
    let token = UUID()
    checkToken = token
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self = self, self.checkToken == token, self.m.checking else { return }
      self.m.checking = false; self.m.typed = ""; self.m.note = "もう一度どうぞ"
    }
    checkQ.async {
      let ok = Pin.check(t, against: b)
      DispatchQueue.main.async {
        guard self.checkToken == token else { return }
        self.checkToken = nil
        self.m.checking = false
        guard self.m.locked else { return }
        if ok { self.unlock(by: "合言葉"); return }
        self.m.fails += 1
        self.m.typed = ""
        self.m.shake += 1
        // 5回目から待たせる：30秒・60秒・120秒…（上限10分）
        if self.m.fails >= 5 {
          let s = min(600.0, 30 * pow(2, Double(self.m.fails - 5)))
          self.m.waitUntil = Date().addingTimeInterval(s)
          self.m.now = Date()   // 古い時刻で秒を多く出さない
        }
        self.m.note = "違います"
        self.alertPhone("合言葉が違いました（\(self.m.fails) 回目）", kind: "合言葉")
        self.m.save()
        log("合言葉ちがい（\(self.m.fails) 回目）")
      }
    }
  }

  // Touch ID の待ち受け。幕は一番上のまま＝確認の窓（coreautha・1000）は幕の裏に隠れるが、
  // 指を置けば通る。窓を見せるために幕を下げると、ずっと待ち受ける今の作りでは
  // 幕がほぼ常に下がったままになり、1000 以上の窓（全画面のアプリなど）が上に出る恐れがある。
  // 待ち受け中はキーが確認の窓に行く＝Esc で確認をやめると合言葉の板に切り替わる。
  // 終わってから0.3秒は次を始めない（連打で確認を作り続けさせない・続けて失敗したら2→60秒）。60秒ごとに張り直す
  func touch() {
    // 張り直しの継ぎ目は短く（確認の窓が無いあいだに Touch ID を押し込むと、幕の裏で macOS がロックされる・反証役）
    let wait = failStreak == 0 ? 0.3 : min(60.0, 2 * pow(2, Double(max(0, failStreak - 1))))
    guard m.locked, !authing, Date().timeIntervalSince(lastAuthEnd) > wait else { return }
    checkTouch()
    guard touchOK else { return }
    authing = true
    authStart = Date()
    m.armed = true
    let c = LAContext()
    c.localizedFallbackTitle = ""   // 「パスワードを入力」は出さない（幕の合言葉を使う）
    authCtx = c
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak c] in
      guard let self = self, let c = c, self.authCtx === c else { return }
      // 先に幕のアプリを前に出してから確認を閉じる。逆だと閉じた瞬間に裏のアプリ（メモなど）が
      // 前に出る＝60秒ごとに「ほかのアプリが前に出た」が残り、その一瞬に打ったキーが裏に入りうる
      NSApp.activate(ignoringOtherApps: true)
      self.endAuth(); self.reassert()
    }
    // 待ち受け中は確認の窓が前面のまま（幕は上に重なるだけ）。そのあいだ Dock を隠す・切り替えを止める
    // 設定は効かない（Dock が見え、スワイプで裏が動くことがある＝本人のテスト）。それでも前に戻すと
    // 指が読まれなくなるので、こちらを取る（reassert の説明）。Esc は確認の窓に届き userCancel → 合言葉の欄
    c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "幕を外します") { ok, err in
      DispatchQueue.main.async {
        guard self.authCtx === c else { return }   // 打ち切ったあとの返事は捨てる
        self.authCtx = nil
        self.authing = false
        self.m.armed = false
        self.lastAuthEnd = Date()
        if ok {
          self.failStreak = 0; self.lastErr = nil
          self.m.scan = "ok"; self.m.scanAt = Date()
          // 指紋が緑に満ちるのを見せてから外す
          let round = self.m.since   // 0.45秒のあいだに外して掛け直されたら、新しい回は外さない
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            self.m.scan = ""
            if self.m.locked && self.m.since == round { self.unlock(by: "Touch ID") }
          }
        }
        else {
          let code = (err as? LAError)?.code
          if code != self.lastErr { log("Touch ID 通らず: \(err?.localizedDescription ?? "")") }
          self.lastErr = code
          // 打ち切り・ほかのアプリ（こちらの都合）以外が続いたら、次を始めるまでの間を広げる（2→4→…→60秒）
          if code == .appCancel || code == .systemCancel { self.failStreak = 0 } else { self.failStreak += 1 }
          self.touchFailed(code)
          self.reassert()
        }
      }
    }
  }

  // 指が合わなかった（LAContext は1回の確認の中で何度か指を試させ、それでも合わないと
  // authenticationFailed を返す＝ここに来た時点で複数回だめだった）・ロックアウト・使えない
  // → 合言葉の欄を出す。Esc で確認をやめた（userCancel）ときも欄に切り替える＝Touch ID が
  // 効かないときの逃げ道。こちらから打ち切った・ほかのアプリに移った（appCancel/systemCancel）は数えない
  func touchFailed(_ code: LAError.Code?) {
    if code == .authenticationFailed || code == .biometryLockout {
      m.scan = "ng"; m.scanAt = Date()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.m.scan == "ng" { self.m.scan = "" } }
    }
    switch code {
    case .authenticationFailed?:
      alertPhone("指紋が合いませんでした", kind: "指紋")
      // 毎回赤く揺らし、3回続いたら合言葉へ（本人の指定）。それまではすぐ待ち受け直す
      // 「続けて」3回：前の失敗から2分以上あいたら数え直す（朝・昼・夕の1回ずつで欄に移らない）
      if Date().timeIntervalSince(lastFingerFail) > 120 { fingerFails = 0 }
      lastFingerFail = Date()
      fingerFails += 1
      if fingerFails >= 3 {
        let round = m.since
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.m.locked && self.m.since == round { self.toPin() } }
      } else {
        failStreak = 0   // 指が合わないのは間を広げる理由にしない
      }
    case .biometryLockout?:
      alertPhone("Touch ID がロックされました（指の失敗が続いたため）", kind: "ロック")
      let round = m.since
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        if self.m.locked && self.m.since == round { self.toPin(); self.m.note = "Touch ID はロック中です" }
      }
    case .biometryNotAvailable?, .biometryNotEnrolled?, .userCancel?:
      toPin()
    default:
      break
    }
  }

  // 合言葉の欄から指紋に戻る（Esc）。Esc の押し間違い・画面が眠って確認が打ち切られた・
  // 鍵束が読めない、のどれでも Touch ID に戻れるように。数え直しは0から（間を広げる数は残す）
  func backToTouch() {
    guard m.locked, m.showPin, touchOK, !m.checking else { return }
    // Touch ID がロックされている（指の失敗が続いた）と、指紋に戻しても待ち受けられず、
    // 「使えない」扱いで数字の板が出っぱなしになる（本人のテストで「電卓になった」）。欄のまま知らせる
    var e: NSError?
    if !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) {
      m.note = (e as? LAError)?.code == .biometryLockout ? "Touch ID はロック中です" : "Touch ID は使えません"
      return
    }
    log("合言葉の欄から指紋へ")
    m.showPin = false; m.showPad = false; m.typed = ""; m.note = ""
    fingerFails = 0
    tick()
  }

  func toPin() {
    if !m.showPin { log("Touch ID から合言葉の板へ") }
    endAuth()   // 待ち受けが残っているとキーが確認の窓に取られ、合言葉が打てない
    m.showPin = true
    m.note = ""   // 欄が「合言葉を入力」に変わるので、知らせは出さない
    reassert()
  }

  func endAuth() {
    if authCtx != nil { lastAuthEnd = Date() }
    m.armed = false
    authCtx?.invalidate()
    authCtx = nil
    authing = false
  }

  // 幕に出す数（つみきリモートから借りる。題名は使わない）
  func pollSeats() {
    guard m.locked, let tok = try? String(contentsOf: TOKEN_FILE, encoding: .utf8),
          let u = URL(string: REMOTE + "/api/state?t=" + tok.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    var rq = URLRequest(url: u); rq.timeoutInterval = 3
    URLSession.shared.dataTask(with: rq) { d, _, _ in
      guard let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let ss = o["sessions"] as? [[String: Any]] else { return }
      let seats = ss.compactMap { s -> Seat? in
        guard let n = s["name"] as? String else { return nil }
        return Seat(id: n, title: "", status: (s["status"] as? String) ?? "")
      }
      DispatchQueue.main.async {
        // 変わったときだけ入れる（毎回入れると幕の全体を描き直す）
        if self.m.seats.map({ $0.id + $0.status }) != seats.map({ $0.id + $0.status }) { self.m.seats = seats }
      }
    }.resume()
  }

  // MARK: 127.0.0.1 の口（server.js から）

  func startServer() {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!)
    params.allowLocalEndpointReuse = true
    guard let l = try? NWListener(using: params) else { log("口を開けられません"); exit(1) }
    l.newConnectionHandler = { [weak self] c in self?.serve(c) }
    l.stateUpdateHandler = { s in
      if case .failed(let e) = s { log("口が閉じた: \(e)"); exit(1) }   // launchd が起こし直す
      if case .ready = s { log("127.0.0.1:\(PORT) で待ち受け") }
    }
    l.start(queue: .main)
    listener = l
  }

  func serve(_ c: NWConnection) {
    c.start(queue: .main)
    var buf = Data()
    var answered = false
    let reply: (Int, [String: Any]) -> Void = { code, obj in
      if answered { return }
      answered = true
      let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
      let h = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "X")\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: \(body.count)\r\nconnection: close\r\n\r\n"
      c.send(content: h.data(using: .utf8)! + body, completion: .contentProcessed { _ in c.cancel() })
    }
    // 返事が来ないつなぎっぱなしは5秒で切る
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !answered { c.cancel() } }
    func readMore() {
      c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { d, _, done, err in
        if let d = d { buf.append(d) }
        if buf.count > 65536 || err != nil { c.cancel(); return }
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { if !done { readMore() } else { c.cancel() }; return }
        let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        var hdr: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { hdr[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        // ⚠️ 鍵を先に比べる。本文の長さは鍵が合ってから、0〜64KB に収めて読む
        //    （負の Content-Length で、鍵なしのまま落とせた＝反証役が再現）
        let given = Array((hdr["x-lock-key"] ?? "").utf8), want = Array(self.key.utf8)
        var diff = given.count == want.count ? 0 : 1
        if given.count == want.count { for i in 0..<want.count { diff |= Int(given[i] ^ want[i]) } }
        if diff != 0 { reply(401, ["error": "unauthorized"]); return }
        guard first.count >= 2 else { reply(400, ["error": "bad"]); return }
        guard let len = Int(hdr["content-length"] ?? "0"), (0...65536).contains(len) else { reply(400, ["error": "bad length"]); return }
        let have = buf.count - r.upperBound
        if have < len { if !done { readMore() } else { reply(400, ["error": "short"]) }; return }
        let body = buf.subdata(in: r.upperBound..<(r.upperBound + len))
        self.route(String(first[0]), String(first[1]), body, reply)
      }
    }
    readMore()
  }

  func route(_ method: String, _ path: String, _ body: Data, _ reply: @escaping (Int, [String: Any]) -> Void) {
    let j = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    switch (method, path) {
    case ("GET", "/status"):
      reply(200, snapshot())
    case ("POST", "/lock"):
      if !Pin.isSet { reply(409, ["error": "先に合言葉を決めてください"]); return }
      lock(by: (j["by"] as? String) ?? "iPhone"); reply(200, snapshot())
    case ("POST", "/unlock"):
      unlock(by: (j["by"] as? String) ?? "iPhone"); reply(200, snapshot())
    case ("POST", "/pin"):
      guard let p = j["pin"] as? String, (4...8).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        reply(400, ["error": "数字4〜8桁で決めてください"]); return
      }
      Pin.q.async {
        let ok = Pin.set(p)
        DispatchQueue.main.async {
          if ok {
            log("合言葉を決め直した")
            Pin.refresh { reply(200, self.snapshot()) }
          } else {
            Pin.refresh()   // 書けなかったときは「ある／ない」を鍵束から取り直す
            reply(500, ["error": "鍵束に書けませんでした"])
          }
        }
      }
    case ("POST", "/try") where KC_SERVICE != "com.tsumiki.lock":
      // 試験のときだけ：キーを打たずに、幕のボタンを押したのと同じ道を通す
      for ch in (j["keys"] as? String) ?? "" {
        if ch == "t" { touch() } else if ch == "f" { touchFailed(.authenticationFailed) } else { press(ch == "\n" ? "enter" : String(ch)) }
      }
      reply(200, snapshot())
    default:
      reply(404, ["error": "no route"])
    }
  }

  func snapshot() -> [String: Any] {
    ["locked": m.locked, "since": m.since.timeIntervalSince1970 * 1000, "pin": Pin.isSet,
     "touchid": touchOK, "fails": m.fails, "checking": m.checking,
     // 指が効かないときの調べ用：待ち受けているか・いつから・最後に終わってから何秒・続けた失敗
     // armed は「返事待ち」だけ。指を読めるのは確認の窓が前面のとき（authFront）
     "armed": authing, "authFront": NSWorkspace.shared.frontmostApplication.map { isAuthAgent($0) } ?? false,
     "armedFor": authing ? Date().timeIntervalSince(authStart) : -1,
     "sinceEnd": Date().timeIntervalSince(lastAuthEnd), "failStreak": failStreak, "showPin": m.showPin]
  }
}

typealias NSListener = NWListener

// 見た目の確かめ用：`TsumikiLock --render out.png 1440 900` で幕を画像にして終わる（架空の席）
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render" {
  let a = CommandLine.arguments
  let w = Double(a.count > 3 ? a[3] : "1440") ?? 1440, h = Double(a.count > 4 ? a[4] : "900") ?? 900
  let m = Model()
  let mode = a.count > 5 ? a[5] : "pin"
  m.locked = true; m.typed = mode.hasPrefix("pin") ? "12" : ""; m.note = ""
  m.showPin = mode.hasPrefix("pin")
  m.showPad = mode == "pinpad"
  m.armed = !mode.hasPrefix("pin")
  m.seats = [Seat(id: "a", title: "", status: "busy"), Seat(id: "b", title: "", status: "waiting"),
             Seat(id: "c", title: "", status: "idle")]
  m.now = Date(timeIntervalSince1970: 1791895000)
  func shoot(_ path: String) {
    MainActor.assumeIsolated {
      let r = ImageRenderer(content: Curtain(m: m, onKey: { _ in }, onTouch: {}, touchOK: true).frame(width: w, height: h))
      r.scale = 1
      if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
         let png = b.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
  }
  if mode == "frames" {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: a[2], isDirectory: &isDir), isDir.boolValue else {
      FileHandle.standardError.write("書き出し先のフォルダがありません: \(a[2])\n".data(using: .utf8)!); exit(1)
    }
    // 動きの見本：ふだん（止まっている・1秒）→ 指が合わない（赤・0.6秒）→ ふだん（0.5秒）→ 通った（緑・0.6秒）
    m.showPin = false
    let base = Date(timeIntervalSinceReferenceDate: 0)
    var f = 0
    func run(_ n: Int, _ scan: String) {
      m.scan = scan; m.scanAt = base.addingTimeInterval(Double(f) / 30)
      for i in 0..<n { m.renderAt = m.scanAt.addingTimeInterval(Double(i) / 30); shoot(a[2] + String(format: "/f%03d.png", f)); f += 1 }
    }
    run(30, ""); run(18, "ng"); run(15, ""); run(24, "ok")
  } else {
    m.renderAt = Date(timeIntervalSinceReferenceDate: 1.1)
    shoot(a[2])
  }
  exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
