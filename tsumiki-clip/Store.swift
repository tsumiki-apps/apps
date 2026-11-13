// 履歴とピンボードの置き場。この Mac の中（~/Library/Application Support/TsumikiClip）だけに置き、外には送らない。
// 目次は clips.json（1つ）、画像は images/、書式つきの文字（RTF）は rich/。フォルダは 0700・ファイルは 0600（自分だけ読める）。
import AppKit
import CryptoKit

enum Kind: String, Codable { case text, link, image, file }

struct Clip: Codable, Equatable {
    var id = UUID()
    var kind: Kind
    var text: String              // 文字・リンク＝中身／ファイル＝パスを改行でつないだもの／画像＝""
    var sig: String               // 同じものを見分ける印（文字なら中身、画像なら SHA256）
    var rich: String?             // rich/ の中の RTF の名前
    var image: String?            // images/ の中の PNG の名前
    var width: Int?
    var height: Int?
    var app: String?              // コピーしたアプリ（bundle id）
    var appName: String?
    var date = Date()
    var board: UUID?              // nil＝履歴、それ以外＝ピンボード
    var title: String?

    var files: [URL] { kind == .file ? text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } : [] }
}

struct Board: Codable, Equatable {
    var id = UUID()
    var name: String
    var color: Int                // Palette.pigments の番号
}

private struct DB: Codable {
    var clips: [Clip] = []
    var boards: [Board] = []
}

/// コピーの中身（保存する前の形）
struct Captured {
    var kind: Kind
    var text: String
    var rtf: Data?
    var png: Data?
    var width: Int?
    var height: Int?
    var app: String?
    var appName: String?
}

final class Store {
    let root: URL
    private(set) var clips: [Clip] = []      // 新しい順
    private(set) var boards: [Board] = []
    var onChange: (() -> Void)?

    /// 既定の置き場。試すときは環境変数 TSUMIKI_CLIP_DIR で別の場所にできる
    static var defaultRoot: URL {
        if let p = ProcessInfo.processInfo.environment["TSUMIKI_CLIP_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TsumikiClip", isDirectory: true)
    }

    init(root: URL = Store.defaultRoot) {
        self.root = root
        let fm = FileManager.default
        for d in [root, root.appendingPathComponent("images"), root.appendingPathComponent("rich")] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true      // 履歴は Time Machine などに入れない
        var r = root; try? r.setResourceValues(rv)
        load()
        cleanOrphans()
    }

    /// 順番に貼るで待っているもの（期間・件数で消さない）
    var hold: Set<UUID> = []

    private var dbURL: URL { root.appendingPathComponent("clips.json") }
    func imageURL(_ c: Clip) -> URL? { c.image.map { root.appendingPathComponent("images/\($0)") } }
    func richData(_ c: Clip) -> Data? { c.rich.flatMap { try? Data(contentsOf: root.appendingPathComponent("rich/\($0)")) } }

    /// 読めなかったら壊れたファイルを横へよける（空の中身で上書きしてピンボードまで消すのを防ぐ）
    private func load() {
        guard let d = try? Data(contentsOf: dbURL) else { return }
        guard let db = try? JSONDecoder().decode(DB.self, from: d) else {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            try? FileManager.default.moveItem(at: dbURL, to: root.appendingPathComponent("clips.corrupt-\(f.string(from: Date())).json"))
            loadFailed = true
            return
        }
        clips = db.clips; boards = db.boards
    }
    private(set) var loadFailed = false

    /// どこからも指されていない画像・書式のファイルを消す（落ちた・壊れたときの残り）
    func cleanOrphans() {
        guard !loadFailed else { return }       // よけた古いファイルが指しているかもしれないので残す
        let fm = FileManager.default
        let used = Set(clips.compactMap(\.image) + clips.compactMap(\.rich))
        for dir in ["images", "rich"] {
            for n in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? [] where !used.contains(n) {
                try? fm.removeItem(at: root.appendingPathComponent("\(dir)/\(n)"))
            }
        }
    }

    func save() {
        guard let d = try? JSONEncoder().encode(DB(clips: clips, boards: boards)) else { return }
        writePrivate(d, to: dbURL)
        onChange?()
    }

    private func writePrivate(_ d: Data, to u: URL) {
        try? d.write(to: u, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    // MARK: 足す

    /// 履歴に足す。同じものが履歴にあれば古いほうを消して一番上へ。足したものを返す
    @discardableResult
    func add(_ c: Captured, now: Date = Date()) -> Clip {
        var sig = c.text
        if let png = c.png { sig = "img:" + SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() }
        if c.kind == .file { sig = "file:" + c.text }
        var clip = Clip(kind: c.kind, text: c.text, sig: sig, width: c.width, height: c.height, app: c.app, appName: c.appName, date: now)
        // 同じものは古いほうをそのまま一番上へ（ID と画像のファイルを変えない＝順番に貼るで待っている分が消えない）
        if let i = clips.firstIndex(where: { $0.board == nil && $0.sig == sig && $0.kind == c.kind }) {
            var old = clips.remove(at: i)
            old.date = now; old.app = c.app; old.appName = c.appName; old.text = c.text
            if let rtf = c.rtf {
                let n = old.rich ?? "\(old.id.uuidString).rtf"
                writePrivate(rtf, to: root.appendingPathComponent("rich/\(n)")); old.rich = n
            }
            clips.insert(old, at: 0)
            purge(now: now, save: false)
            save()
            return old
        }
        let name = clip.id.uuidString
        if let png = c.png { writePrivate(png, to: root.appendingPathComponent("images/\(name).png")); clip.image = "\(name).png" }
        if let rtf = c.rtf { writePrivate(rtf, to: root.appendingPathComponent("rich/\(name).rtf")); clip.rich = "\(name).rtf" }
        clips.insert(clip, at: 0)
        purge(now: now, save: false)
        save()
        return clip
    }

    /// 貼った履歴を一番上へ（ピンボードの中身は動かさない）
    func touch(_ id: UUID, now: Date = Date()) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].board == nil else { return }
        var c = clips.remove(at: i); c.date = now
        clips.insert(c, at: 0)
        save()
    }

    // MARK: 消す

    func remove(_ id: UUID, save doSave: Bool = true) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips.remove(at: i)
        deleteBlobs(c)
        if doSave { save() }
    }

    private func deleteBlobs(_ c: Clip) {
        let fm = FileManager.default
        if let n = c.image { try? fm.removeItem(at: root.appendingPathComponent("images/\(n)")) }
        if let n = c.rich { try? fm.removeItem(at: root.appendingPathComponent("rich/\(n)")) }
    }

    /// 履歴を全部消す（ピンボードは残す）
    func clearHistory() {
        for c in clips where c.board == nil { deleteBlobs(c) }
        clips.removeAll { $0.board == nil }
        save()
    }

    /// 期間と件数の上限で古い履歴を消す。ピンボードの中身は消さない
    func purge(now: Date = Date(), save doSave: Bool = true) {
        let days = Prefs.keepDays, limit = Prefs.maxCount
        var n = 0
        var drop: [Clip] = []
        for c in clips where c.board == nil {
            n += 1
            if hold.contains(c.id) { continue }
            if (days > 0 && now.timeIntervalSince(c.date) > Double(days) * 86400) || (limit > 0 && n > limit) { drop.append(c) }
        }
        guard !drop.isEmpty else { return }
        let ids = Set(drop.map(\.id))
        drop.forEach(deleteBlobs)
        clips.removeAll { ids.contains($0.id) }
        if doSave { save() }
    }

    // MARK: ピンボード

    @discardableResult
    func addBoard(_ name: String) -> Board {
        let b = Board(name: name, color: boards.count % Palette.pigments.count)
        boards.append(b); save()
        return b
    }

    func renameBoard(_ id: UUID, _ name: String) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].name = name; save()
    }

    func removeBoard(_ id: UUID) {
        for c in clips where c.board == id { deleteBlobs(c) }
        clips.removeAll { $0.board == id }
        boards.removeAll { $0.id == id }
        save()
    }

    /// ピンボードへ写す（履歴のほうは期間が来たら消えるが、写したものは残る）
    @discardableResult
    func pin(_ id: UUID, to board: UUID) -> Clip? {
        guard let src = clips.first(where: { $0.id == id }) else { return nil }
        if let dup = clips.first(where: { $0.board == board && $0.sig == src.sig }) { return dup }
        var c = src; c.id = UUID(); c.board = board; c.date = Date()
        let fm = FileManager.default
        if let n = src.image {
            let nn = "\(c.id.uuidString).png"
            do { try fm.copyItem(at: root.appendingPathComponent("images/\(n)"), to: root.appendingPathComponent("images/\(nn)")); c.image = nn }
            catch { return nil }          // 元の画像が無い＝写せない（空のピンを作らない）
        }
        if let n = src.rich {
            let nn = "\(c.id.uuidString).rtf"
            c.rich = (try? fm.copyItem(at: root.appendingPathComponent("rich/\(n)"), to: root.appendingPathComponent("rich/\(nn)"))) != nil ? nn : nil
        }
        clips.insert(c, at: 0); save()
        return c
    }

    func rename(_ id: UUID, _ title: String?) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].title = (title?.isEmpty ?? true) ? nil : title; save()
    }

    // MARK: 探す

    /// board＝nil は履歴。検索は大文字小文字・全角半角を区別しない
    func list(board: UUID?, query: String) -> [Clip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return clips.filter { c in
            guard c.board == board else { return false }
            if q.isEmpty { return true }
            let hay = [c.text, c.title ?? "", c.appName ?? ""].joined(separator: "\n")
            return q.split(separator: " ").allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

// MARK: - 設定（UserDefaults）

enum Prefs {
    static var d: UserDefaults = .standard
    /// 残す日数（0＝ずっと）。既定は30日（本家の既定と同じ）
    static var keepDays: Int {
        get { d.object(forKey: "keepDays") as? Int ?? 30 }
        set { d.set(newValue, forKey: "keepDays") }
    }
    /// 履歴の件数の上限（0＝上限なし）
    static var maxCount: Int {
        get { d.object(forKey: "maxCount") as? Int ?? 1000 }
        set { d.set(newValue, forKey: "maxCount") }
    }
    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
    /// 最初から入れておく「記録しないアプリ」（パスワードやお金の情報を扱うアプリ）
    static let defaultIgnored = ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
                                 "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane", "org.keepassxc.keepassxc",
                                 "com.nordpass.macos.NordPass", "com.apple.systempreferences.Passwords"]
    static var ignored: [String] {
        get { d.stringArray(forKey: "ignored") ?? defaultIgnored }
        set { d.set(newValue, forKey: "ignored") }
    }
}

// MARK: - 色（DESIGN.md の和紙と墨。明るい／暗いで切り替わる）

enum Palette {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light) }
    }
    static let paper = dyn(0xf5f4f0, 0x0f0d07)
    static let surface = dyn(0xfffefb, 0x211d14)
    static let surface2 = dyn(0xefece5, 0x2b2619)
    static let ink = dyn(0x1d1a15, 0xefe8da)
    static let inkMid = dyn(0x5b554a, 0xa89e8b)
    static let sub = dyn(0x68645d, 0x9f988a)
    static let line = dyn(0xe2ded4, 0x36301f)
    static let line2 = dyn(0xd8d3c7, 0x443d2b)
    static let accent = dyn(0xb06f26, 0xd59a4d)
    static let accentWash = dyn(0xf0e4d1, 0x362a19)
    static let warn = dyn(0xb0522a, 0xd9825a)
    static let pigments: [NSColor] = [hex(0xb07a2c), hex(0xa3523c), hex(0x4c6478), hex(0x63764e), hex(0x8a6a4e), hex(0x6a5878)]
}

// MARK: - 貼る前に整える

enum Tidy: Int, CaseIterable {
    case trim = 1, join, halfwidth
    var name: String { ["", "前後の空白を取る", "改行をつなぐ", "全角英数を半角に"][rawValue] }
    var symbol: String { ["", "scissors", "arrow.right.to.line", "textformat.size.smaller"][rawValue] }

    func apply(_ s: String) -> String {
        switch self {
        case .trim:
            // 全体の前後と、各行の行末の空白を取る
            let lines = s.components(separatedBy: "\n").map { l -> String in
                var x = Substring(l)
                while let c = x.last, c == " " || c == "\t" || c == "\r" || c == "\u{3000}" { x.removeLast() }
                return String(x)
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}")))
        case .join:
            // 行をつなぐ。英数どうしの間だけ半角スペースを入れる（日本語はそのままつなぐ）
            let parts = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var out = ""
            for p in parts {
                if let a = out.unicodeScalars.last, let b = p.unicodeScalars.first, a.isASCII, b.isASCII,
                   CharacterSet.alphanumerics.contains(b) || ",.;:!?)".unicodeScalars.contains(a) {
                    out += " "
                }
                out += p
            }
            return out
        case .halfwidth:
            // 全角の数字と英字だけ半角に（カタカナ・かっこ・句読点は変えない）
            return String(String.UnicodeScalarView(s.unicodeScalars.map { u -> Unicode.Scalar in
                switch u.value {
                case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return Unicode.Scalar(u.value - 0xFEE0)!
                default: return u
                }
            }))
        }
    }
}
