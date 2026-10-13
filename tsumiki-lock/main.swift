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
  // 数字の板を出すか。ふだんは Touch ID だけ。Touch ID が断ったとき（指が合わない・
  // ロックアウト・使えない）に出す。外れたら隠し直す
  @Published var showPin = false
  @Published var armed = false   // Touch ID を待ち受けている（指を置けば外れる）
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

struct LockIcon: View {
  var body: some View {
    Canvas { c, s in
      let k = s.width / 24
      var p = Path(roundedRect: CGRect(x: 5 * k, y: 11 * k, width: 14 * k, height: 10 * k), cornerRadius: 2 * k)
      p.move(to: CGPoint(x: 8 * k, y: 11 * k))
      p.addLine(to: CGPoint(x: 8 * k, y: 8 * k))
      p.addArc(center: CGPoint(x: 12 * k, y: 8 * k), radius: 4 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
      p.addLine(to: CGPoint(x: 16 * k, y: 11 * k))
      c.stroke(p, with: .color(.accent), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round))
    }
  }
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
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          Text(clock).font(zen(150 * u, true)).foregroundColor(.ink).monospacedDigit()
          Text(day).font(zen(28 * u)).foregroundColor(.mid).padding(.top, 4 * u)
          // 作業の題名は出さない（お客様の名前が入ることがある）。状態ごとの数だけ
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
          }.padding(.top, 48 * u)
          Spacer()
        }
        .padding(.leading, 120 * u).padding(.top, 130 * u)
        .frame(maxWidth: .infinity, alignment: .leading)

        if !m.showPin && touchOK {
          // 待機の画面：Touch ID だけ。押すか、指を置く前に何かキーを押す
          VStack(spacing: 36 * u) {
            LockIcon().frame(width: 72 * u, height: 72 * u)
            Button(action: onTouch) {
              ZStack {
                Circle().fill(Color.surface2)
                Circle().stroke(Color.accent.opacity(m.armed ? 0.55 : 0), lineWidth: 3 * u)
                Image(systemName: "touchid").font(.system(size: 76 * u, weight: .light)).foregroundColor(.accent)
              }.frame(width: 150 * u, height: 150 * u).contentShape(Circle())
            }.buttonStyle(.plain)
            Text(m.note).font(zen(18 * u)).foregroundColor(.warn).frame(height: 24 * u)
          }
          .frame(width: 520 * u).padding(.trailing, 110 * u)
        } else {
        VStack(spacing: 30 * u) {
          LockIcon().frame(width: 72 * u, height: 72 * u)
          // 丸は打った数だけ。空の丸を並べると「4桁」に見えて紛らわしく（本人の指摘）、
          // 合言葉の桁数を見せることにもなるので、打つ前は細い線だけ
          HStack(spacing: 18 * u) {
            if m.typed.isEmpty {
              Capsule().fill(Color.surface2).frame(width: 120 * u, height: 4 * u)
            } else {
              ForEach(0..<m.typed.count, id: \.self) { _ in
                Circle().fill(Color.accent).frame(width: 22 * u, height: 22 * u)
              }
            }
          }
          .frame(height: 22 * u)
          .offset(x: m.shake % 2 == 1 ? 10 * u : 0)
          .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: m.shake)
          Text(waitLeft > 0 ? "\(waitLeft) 秒 お待ちください" : m.checking ? "確かめています" : m.note)
            .font(zen(18 * u)).foregroundColor(.warn).frame(height: 24 * u)
          LazyVGrid(columns: Array(repeating: GridItem(.fixed(84 * u), spacing: 22 * u), count: 3), spacing: 18 * u) {
            ForEach(["1","2","3","4","5","6","7","8","9","touch","0","del"], id: \.self) { k in key(k, u) }
          }
          .opacity(waitLeft > 0 ? 0.35 : 1)
        }
        .frame(width: 520 * u).padding(.trailing, 110 * u)
        }
      }
      .frame(width: g.size.width, height: g.size.height)
      .background(Color.paper)
    }
  }

  @ViewBuilder func key(_ k: String, _ u: CGFloat) -> some View {
    let enter = k == "touch" && !m.typed.isEmpty
    Button(action: { enter ? onKey("enter") : k == "touch" ? onTouch() : onKey(k) }) {
      ZStack {
        Circle().fill(enter ? Color.accent : (k == "touch" || k == "del" ? Color.clear : Color.surface2))
        if enter {
          Image(systemName: "arrow.right").font(.system(size: 30 * u, weight: .semibold)).foregroundColor(.paper)
        } else if k == "touch" {
          if touchOK { Image(systemName: "touchid").font(.system(size: 40 * u, weight: .light)).foregroundColor(.accent) }
        } else if k == "del" {
          Text("⌫").font(zen(28 * u)).foregroundColor(.mid)
        } else {
          Text(k).font(zen(32 * u, true)).foregroundColor(.ink)
        }
      }.frame(width: 84 * u, height: 84 * u).contentShape(Circle())
    }.buttonStyle(.plain).disabled(k == "touch" && !enter && !touchOK)
  }

  func dot(_ s: String) -> Color { s == "busy" ? .good : s == "waiting" ? .accent : .mid }
  func wash(_ s: String) -> Color { s == "busy" ? .goodWash : .surface2 }
  func label(_ s: String) -> String { ["busy": "作業中", "waiting": "返答待ち", "idle": "待機", "paused": "中断"][s] ?? "" }
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

  // 幕の高さ。ふだんは一番上（どのアプリの全画面の窓より上）。
  // Touch ID の確認（coreautha・1000）を出すあいだだけ、その下に下げる
  let topLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

  func checkTouch() {
    var e: NSError?
    touchOK = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
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
      if a.processIdentifier == ProcessInfo.processInfo.processIdentifier || self.isAuthAgent(a) { return }
      log("ほかのアプリが前に出た（\(a.localizedName ?? "?")）→ 前に戻る")
      self.endAuth()
      self.reassert()
    }
    if m.locked { log("起動時に幕が掛かっていた → 掛け直す"); showCurtain() }
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
    m.locked = true; m.since = Date(); m.typed = ""; m.note = ""; m.showPin = false
    m.save()
    log("ロック（\(who)）")
    showCurtain()
  }

  func unlock(by who: String) {
    guard m.locked else { return }
    endAuth()
    m.locked = false; m.typed = ""; m.fails = 0; m.waitUntil = .distantPast; m.checking = false
    m.showPin = false
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
        if !self.m.showPin && self.touchOK { self.touch(); return nil }
        if e.keyCode == 51 { self.press("del") }                         // ⌫
        else if e.keyCode == 36 || e.keyCode == 76 {                      // Enter：打っていれば決定、無ければ Touch ID
          if self.m.typed.isEmpty { self.touch() } else { self.press("enter") }
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
  func tick() {
    m.now = Date()
    guard m.locked else { return }
    windows.forEach { $0.orderFrontRegardless() }
    if !authing && !NSApp.isActive { reassert() }
    // Touch ID は常に待ち受ける（本人の要望）。合言葉の板を出しているあいだは待ち受けない
    // （待ち受け中はキーが確認の窓に取られ、合言葉が打てないため）
    if !authing && !m.showPin { touch() }
    if m.now.timeIntervalSince(lastPoll) >= 3 { lastPoll = m.now; pollSeats() }
  }

  // MARK: 合言葉・Touch ID

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
      m.note = "合言葉を読めません。Touch ID か iPhone で外してください"
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
        }
        self.m.note = "違います"
        self.m.save()
        log("合言葉ちがい（\(self.m.fails) 回目）")
      }
    }
  }

  // Touch ID の待ち受け。幕は一番上のまま＝確認の窓（coreautha・1000）は幕の裏に隠れるが、
  // 指を置けば通る。窓を見せるために幕を下げると、ずっと待ち受ける今の作りでは
  // 幕がほぼ常に下がったままになり、1000 以上の窓（全画面のアプリなど）が上に出る恐れがある。
  // 待ち受け中はキーが確認の窓に行く＝Esc で確認をやめると合言葉の板に切り替わる。
  // 終わってから2秒は次を始めない（連打で確認を作り続けさせない）。60秒ごとに張り直す
  func touch() {
    guard m.locked, !authing, Date().timeIntervalSince(lastAuthEnd) > 2 else { return }
    checkTouch()
    guard touchOK else { return }
    authing = true
    m.armed = true
    let c = LAContext()
    c.localizedFallbackTitle = ""   // 「パスワードを入力」は出さない（幕の合言葉を使う）
    authCtx = c
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak c] in
      guard let self = self, let c = c, self.authCtx === c else { return }
      self.endAuth(); self.reassert()
    }
    c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "幕を外します") { ok, err in
      DispatchQueue.main.async {
        guard self.authCtx === c else { return }   // 打ち切ったあとの返事は捨てる
        self.authCtx = nil
        self.authing = false
        self.m.armed = false
        self.lastAuthEnd = Date()
        if ok { self.unlock(by: "Touch ID") }
        else {
          log("Touch ID 通らず: \(err?.localizedDescription ?? "")")
          self.touchFailed((err as? LAError)?.code)
          self.reassert()
        }
      }
    }
  }

  // 指が合わなかった（LAContext は1回の確認の中で何度か指を試させ、それでも合わないと
  // authenticationFailed を返す＝ここに来た時点で複数回だめだった）・ロックアウト・使えない
  // → 数字の板を出す。Esc で確認をやめた（userCancel）ときも板に切り替える＝Touch ID が
  // 効かないときの逃げ道。こちらから打ち切った・ほかのアプリに移った（appCancel/systemCancel）は数えない
  func touchFailed(_ code: LAError.Code?) {
    switch code {
    case .authenticationFailed?, .biometryLockout?, .biometryNotAvailable?, .biometryNotEnrolled?, .userCancel?:
      if !m.showPin { log("Touch ID が通らない → 合言葉の板を出す") }
      endAuth()   // 待ち受けが残っているとキーが確認の窓に取られ、合言葉が打てない
      m.showPin = true
      reassert()
      m.note = "合言葉で外してください"
    default:
      break
    }
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
      DispatchQueue.main.async { self.m.seats = seats }
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
     "touchid": touchOK, "fails": m.fails, "checking": m.checking]
  }
}

typealias NSListener = NWListener

// 見た目の確かめ用：`TsumikiLock --render out.png 1440 900` で幕を画像にして終わる（架空の席）
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render" {
  let a = CommandLine.arguments
  let w = Double(a.count > 3 ? a[3] : "1440") ?? 1440, h = Double(a.count > 4 ? a[4] : "900") ?? 900
  let m = Model()
  let mode = a.count > 5 ? a[5] : "pin"
  m.locked = true; m.typed = mode == "pin" ? "12" : ""; m.note = mode == "pin" ? "合言葉で外してください" : ""
  m.showPin = mode == "pin"
  m.now = Date(timeIntervalSince1970: 1791895000)
  m.seats = [Seat(id: "a", title: "見本の作業A", status: "busy"), Seat(id: "b", title: "見本の作業B", status: "waiting"),
             Seat(id: "c", title: "見本の作業C", status: "idle")]
  MainActor.assumeIsolated {
    let r = ImageRenderer(content: Curtain(m: m, onKey: { _ in }, onTouch: {}, touchOK: true).frame(width: w, height: h))
    r.scale = 2
    if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
       let png = b.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: a[2]))
    }
  }
  exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
