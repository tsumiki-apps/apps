// トレイの中身。
// ファイルは「場所の控え（ブックマーク）」だけを持つ＝元のファイルは動かさない・消さない・書き換えない。
// 文字・URL・画像・受け取ったファイル（写真アプリなどの「約束」のドラッグ）は元が無いので、中身を items/<id>/ に持つ。
// トレイから消すとき、消すのは items/<id>/ の中（アプリが持っている分）だけ。
import AppKit
import UniformTypeIdentifiers

enum Kind: String, Codable { case files, text, url, image }

struct TrayItem: Codable, Equatable {
    var id = UUID()
    var kind: Kind
    var bookmarks: [Data] = []     // 元のファイルの控え
    var paths: [String] = []       // 最後に分かった場所（控えが解けないときの手がかり・名前の表示）
    var owned: [String] = []       // アプリが持っている中身（items/<id>/ の中のファイル名）
    var text: String? = nil        // 文字・URL
    var added = Date()

    var count: Int { kind == .files ? bookmarks.count + owned.count : 1 }
}

/// ドラッグ・貼り付けで受け取ったもの
enum Payload: Equatable {
    case files([URL]), promises(Int), image(Data), url(URL), text(String), none
}

final class Store {
    let dir: URL
    private(set) var items: [TrayItem] = []
    var onChange: (() -> Void)?
    /// 消した中身を実際に消すまでの猶予（取り出した直後は相手のアプリがまだ写している途中かもしれない）
    var purgeDelay: TimeInterval = 60

    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TsumikiTray")
    }

    init(dir: URL = Store.defaultDir) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        load()
        purgeOrphans()
    }

    var itemsDir: URL { dir.appendingPathComponent("items") }
    var file: URL { dir.appendingPathComponent("items.json") }
    func ownedDir(_ id: UUID) -> URL { itemsDir.appendingPathComponent(id.uuidString) }

    // MARK: 保存・読み込み

    func load() {
        guard let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([TrayItem].self, from: d) else { return }
        items = v
    }

    func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file, options: .atomic) }
        onChange?()
    }

    /// 前回の終了までに消し損ねた中身（どの項目からも指されていない items/<id>/）を片付ける
    func purgeOrphans() {
        let keep = Set(items.map { $0.id.uuidString })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: itemsDir.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: itemsDir.appendingPathComponent(name))
        }
    }

    // MARK: 足す

    #if APPSTORE
    static let makeOpts: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    static let resolveOpts: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let makeOpts: URL.BookmarkCreationOptions = []
    static let resolveOpts: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif

    /// ファイル（複数なら1つの山）。控えを作るだけで、元には何もしない
    @discardableResult
    func addFiles(_ urls: [URL], at index: Int = 0) -> TrayItem? {
        var it = TrayItem(kind: .files)
        for u in urls {
            guard let b = try? u.bookmarkData(options: Store.makeOpts, includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            it.bookmarks.append(b); it.paths.append(u.path)
        }
        guard !it.bookmarks.isEmpty else { return nil }
        insert(it, at: index); return it
    }

    /// すでに items/<id>/ に置いたファイル（約束のドラッグで受け取ったもの）
    @discardableResult
    func addOwnedFiles(id: UUID, names: [String], at index: Int = 0) -> TrayItem? {
        guard !names.isEmpty else { return nil }
        var it = TrayItem(kind: .files); it.id = id; it.owned = names
        it.paths = names.map { ownedDir(id).appendingPathComponent($0).path }
        insert(it, at: index); return it
    }

    @discardableResult
    func addText(_ s: String, at index: Int = 0) -> TrayItem {
        var it = TrayItem(kind: .text); it.text = s
        insert(it, at: index); return it
    }

    @discardableResult
    func addURL(_ u: URL, at index: Int = 0) -> TrayItem {
        var it = TrayItem(kind: .url); it.text = u.absoluteString
        insert(it, at: index); return it
    }

    /// 画像（PNG にして持つ）
    @discardableResult
    func addImage(png: Data, name: String = "画像.png", at index: Int = 0) -> TrayItem? {
        var it = TrayItem(kind: .image)
        let d = ownedDir(it.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard (try? png.write(to: d.appendingPathComponent(name))) != nil else { return nil }
        it.owned = [name]; it.paths = [d.appendingPathComponent(name).path]
        insert(it, at: index); return it
    }

    private func insert(_ it: TrayItem, at index: Int) {
        items.insert(it, at: max(0, min(index, items.count)))
        save()
    }

    // MARK: 消す・ばらす・並べ替え

    /// トレイから消す。元のファイルには触らない。アプリが持っている中身だけ、少し待ってから消す
    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: i)
        save()
        if !it.owned.isEmpty { purgeLater(it.id) }
    }

    func removeAll() {
        let gone = items.filter { !$0.owned.isEmpty }.map(\.id)
        items.removeAll(); save()
        gone.forEach(purgeLater)
    }

    private func purgeLater(_ id: UUID) {
        let d = ownedDir(id)
        let work = { [weak self] in
            guard let self, !self.items.contains(where: { $0.id == id }) else { return }
            try? FileManager.default.removeItem(at: d)
        }
        if purgeDelay <= 0 { work() } else { DispatchQueue.main.asyncAfter(deadline: .now() + purgeDelay, execute: work) }
    }

    /// 山をばらす（1つずつの項目にする）
    func split(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].kind == .files, items[i].count > 1 else { return }
        let it = items.remove(at: i)
        var parts: [TrayItem] = []
        for (b, p) in zip(it.bookmarks, it.paths) {
            var n = TrayItem(kind: .files); n.bookmarks = [b]; n.paths = [p]; parts.append(n)
        }
        // 持っている中身は、山の id のフォルダにあるので、山の先頭の id をそのまま使い回せない。1つずつ移す
        for name in it.owned {
            var n = TrayItem(kind: .files)
            let to = ownedDir(n.id)
            try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: ownedDir(it.id).appendingPathComponent(name), to: to.appendingPathComponent(name))) != nil {
                n.owned = [name]; n.paths = [to.appendingPathComponent(name).path]; parts.append(n)
            }
        }
        try? FileManager.default.removeItem(at: ownedDir(it.id))
        items.insert(contentsOf: parts, at: i)
        save()
    }

    func move(_ id: UUID, to index: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: i)
        items.insert(it, at: max(0, min(index > i ? index - 1 : index, items.count)))
        save()
    }

    // MARK: 場所を引く

    /// 項目のファイルの今の場所。元が見つからない（消えた・ゴミ箱）ものは nil
    func urls(_ it: TrayItem) -> [URL?] {
        var out: [URL?] = []
        var changed = false
        var updated = it
        for (k, b) in it.bookmarks.enumerated() {
            var stale = false
            var u = try? URL(resolvingBookmarkData: b, options: Store.resolveOpts, relativeTo: nil, bookmarkDataIsStale: &stale)
            if let x = u {
                #if APPSTORE
                _ = x.startAccessingSecurityScopedResource()
                #endif
                if !FileManager.default.fileExists(atPath: x.path) || x.path.contains("/.Trash/") { u = nil }
            }
            if let x = u {
                if x.path != it.paths[k] { updated.paths[k] = x.path; changed = true }
                if stale, let nb = try? x.bookmarkData(options: Store.makeOpts, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    updated.bookmarks[k] = nb; changed = true
                }
            }
            out.append(u)
        }
        for name in it.owned {
            let u = ownedDir(it.id).appendingPathComponent(name)
            out.append(FileManager.default.fileExists(atPath: u.path) ? u : nil)
        }
        if changed, let i = items.firstIndex(where: { $0.id == it.id }) { items[i] = updated; save() }
        return out
    }

    func isMissing(_ it: TrayItem) -> Bool {
        guard it.kind == .files || it.kind == .image else { return false }
        return urls(it).allSatisfy { $0 == nil }
    }

    /// 表示用の名前（最後に分かった場所の名前）
    func title(_ it: TrayItem) -> String {
        switch it.kind {
        case .files, .image: return (it.paths.first as NSString?)?.lastPathComponent ?? ""
        case .url: return URL(string: it.text ?? "")?.host ?? it.text ?? ""
        case .text: return it.text ?? ""
        }
    }
}

// MARK: - 取り込み（ドロップ・貼り付けの中身を見分ける）

enum Intake {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                             NSPasteboard.PasteboardType("public.heic")]

    /// ファイル → 約束のファイル（Web の URL が無いとき）→ 画像 → URL → 文字 の順に見る。
    /// ブラウザのリンクや画像は「約束のファイル」も一緒に付けてくる（.webloc など）。URL があればそちらを採る。
    static func read(_ pb: NSPasteboard) -> Payload {
        if let us = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !us.isEmpty {
            return .files(us)
        }
        let web = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).first(where: isWeb)
        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)?.count ?? 0
        if promises > 0, web == nil { return .promises(promises) }
        if let png = imagePNG(pb) { return .image(png) }
        if let u = web { return .url(u) }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if !s.contains(where: \.isWhitespace), let u = URL(string: s), isWeb(u) { return .url(u) }
            return .text(s)
        }
        if promises > 0 { return .promises(promises) }
        return .none
    }

    /// 相手が許す操作から選ぶ：コピー → 何でも → リンク。移動は選ばない（移動にすると渡した側が元を消すことがある）
    static func operation(_ mask: NSDragOperation) -> NSDragOperation {
        for op in [NSDragOperation.copy, .generic, .link] where mask.contains(op) { return op }
        return []
    }

    static func isWeb(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") }

    static func imagePNG(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        for t in imageTypes.dropFirst() {
            if let d = pb.data(forType: t), let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        return nil
    }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string] + imageTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }
}
