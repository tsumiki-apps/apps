import Foundation

/// 検索結果の1件（まだ本棚には入っていない候補）
struct BookCandidate: Identifiable, Hashable {
    var id: String { isbn13 ?? "\(title)|\(authors)" }
    var isbn13: String?
    var title: String
    var authors: String
    var publisher: String
    var pubdate: String
    var coverURL: URL?
    var source: Source
    var srcRank: Int
    var score: Double = 0

    enum Source: String { case rakuten = "楽天", rakutenKeyword = "楽天kw", ndl = "国会図書館" }
}

enum SearchRoute: Equatable {
    case isbn, rakutenTitle, rakutenKeyword, ndl
}

struct SearchOutcome {
    var candidates: [BookCandidate] = []
    var routes: [SearchRoute] = []
    /// 楽天が空振りしたので、国会図書館を裏で追って良い状態
    var canDeepen: Bool = false
}

/// 書誌検索。楽天ブックスを主、国会図書館を補完に使う。
///
/// 設計の根拠（実測で確定・詳細は Vault の book-metadata-api-comparison.md）:
/// - 楽天は 0.1〜0.2秒／書影 100%。国会図書館は `any=` で 16.6秒かかるうえ関連度ソートが無い。
/// - 楽天の売れ筋順そのものが強い信号なので、それを主軸に据える。
///   自前スコアだけで並べ替えると本命が 15位まで沈むことを実測で確認済み。
/// - 楽天 API は `Origin` ヘッダーが必須。`Referer` だけでは 403 になる。
actor BookSearchService {

    private let appID: String
    private let accessKey: String
    private let origin: String
    private let session: URLSession

    /// 楽天は 1リクエスト/秒。連続で叩くと 429 が返るので最後の発射時刻を持っておく。
    private var lastRakutenCall: Date = .distantPast
    private static let rakutenMinInterval: TimeInterval = 1.05

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        let info = bundle.infoDictionary ?? [:]
        self.appID = info["RakutenAppID"] as? String ?? ""
        self.accessKey = info["RakutenAccessKey"] as? String ?? ""
        self.origin = info["RakutenOrigin"] as? String ?? ""
        self.session = session
    }

    var isConfigured: Bool { !appID.isEmpty && !accessKey.isEmpty }

    // MARK: - 入口

    /// 画面をブロックしてよい範囲だけを返す（最悪でも約1.5秒で戻る）。
    /// 空振りしたときは `canDeepen` を立てて返し、国会図書館は呼び出し側が裏で追う。
    func search(_ query: String) async -> SearchOutcome {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchOutcome() }

        var out = SearchOutcome()

        // 数字だけならISBNとみなして直引き（バーコードを手打ちされても拾える）
        let digits = q.filter(\.isNumber)
        if digits.count == q.filter({ !$0.isWhitespace && $0 != "-" }).count,
           digits.count == 13 || digits.count == 10 {
            out.routes.append(.isbn)
            if let hit = await rakuten(digits, mode: .isbn).first {
                out.candidates = [hit]
                return out
            }
            out.canDeepen = true
            return out
        }

        let byTitle = await rakuten(q, mode: .title)
        out.routes.append(.rakutenTitle)
        if !byTitle.isEmpty {
            out.candidates = rank(query: q, byTitle)
            return out
        }

        // 書名で当たらないときだけ、キーワード検索へ広げる
        let byKeyword = await rakuten(q, mode: .keyword)
        out.routes.append(.rakutenKeyword)
        if !byKeyword.isEmpty {
            out.candidates = rank(query: q, byKeyword)
            return out
        }

        out.canDeepen = true
        return out
    }

    /// 国会図書館まで含めた追い込み。遅いので UI をブロックせずに呼ぶこと。
    func deepen(_ query: String) async -> [BookCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return rank(query: q, await ndl(q))
    }

    /// バーコード用。ISBN 直引きは 0.09秒で書影つきが返る。
    func lookup(isbn: String) async -> BookCandidate? {
        let digits = isbn.filter(\.isNumber)
        guard digits.count == 13 || digits.count == 10 else { return nil }
        return await rakuten(digits, mode: .isbn).first
    }

    // MARK: - 楽天ブックス

    private enum RakutenMode {
        case title, keyword, isbn
        var path: String { self == .keyword ? "BooksTotal/Search" : "BooksBook/Search" }
        var param: String {
            switch self {
            case .title: return "title"
            case .keyword: return "keyword"
            case .isbn: return "isbn"
            }
        }
        var rankOffset: Int { self == .keyword ? 40 : 0 }
        var source: BookCandidate.Source { self == .keyword ? .rakutenKeyword : .rakuten }
    }

    private func rakuten(_ query: String, mode: RakutenMode) async -> [BookCandidate] {
        guard isConfigured else { return [] }
        await throttleRakuten()

        var c = URLComponents(string: "https://openapi.rakuten.co.jp/services/api/\(mode.path)/20170404")!
        c.queryItems = [
            .init(name: "applicationId", value: appID),
            .init(name: "accessKey", value: accessKey),
            .init(name: mode.param, value: query),
            .init(name: "hits", value: "30"),
            .init(name: "sort", value: "sales"),
        ]
        guard let url = c.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 3)
        // ここが要。Referer では通らず Origin が必要（実測で切り分け済み）
        req.setValue(origin, forHTTPHeaderField: "Origin")

        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            data = d
            #if DEBUG
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[検索] \(mode.param)=\(query) → HTTP \(code) / \(d.count)バイト")
            if code != 200 { print("[検索] 本文: \(String(data: d, encoding: .utf8)?.prefix(200) ?? "")") }
            #endif
        } catch {
            #if DEBUG
            print("[検索] \(mode.param)=\(query) → 通信失敗: \(error.localizedDescription)")
            #endif
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["Items"] as? [[String: Any]]
        else { return [] }

        return items.enumerated().compactMap { idx, wrapper in
            guard let i = (wrapper["Item"] as? [String: Any]) ?? wrapper as [String: Any]? else { return nil }
            let isbn = (i["isbn"] as? String) ?? ""
            let cover = (i["largeImageUrl"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            return BookCandidate(
                isbn13: isbn.count >= 10 ? isbn : nil,
                title: (i["title"] as? String) ?? "",
                authors: (i["author"] as? String) ?? "",
                publisher: (i["publisherName"] as? String) ?? "",
                pubdate: (i["salesDate"] as? String) ?? "",
                coverURL: cover,
                source: mode.source,
                srcRank: mode.rankOffset + idx)
        }
    }

    private func throttleRakuten() async {
        let wait = Self.rakutenMinInterval - Date().timeIntervalSince(lastRakutenCall)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRakutenCall = Date()
    }

    // MARK: - 国会図書館（補完。書影は持っていない）

    private func ndl(_ query: String) async -> [BookCandidate] {
        // `any=` は 16.6秒かかるので使わない。`title=` なら約2秒。
        var c = URLComponents(string: "https://ndlsearch.ndl.go.jp/api/opensearch")!
        c.queryItems = [.init(name: "title", value: query), .init(name: "cnt", value: "100")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Yomitame/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await session.data(for: req),
              let xml = String(data: data, encoding: .utf8) else { return [] }
        return NDLParser.parse(xml)
    }

    // MARK: - 並べ替え

    /// 主軸は提供元の順位。関連度は補正と、無関係な本の切り捨てに使う。
    private func score(query: String, _ b: BookCandidate) -> Double {
        let q = Self.normalize(query)
        let t = Self.normalize(b.title)
        let a = Self.normalize(b.authors)
        guard !q.isEmpty else { return 0 }

        var s = max(0, 1000 - Double(b.srcRank) * 20)

        if t == q { s += 500 }                 // 完全一致は問答無用で最上位
        else if t.hasPrefix(q) { s += 100 }
        else if t.contains(q) { s += 50 }
        else if a.contains(q) { s += 50 }
        else { s -= 800 }                      // クエリを含まない＝実質除外

        s -= Double(max(0, t.count - q.count)) * 2
        if b.coverURL != nil { s += 15 }
        if b.isbn13 != nil { s += 10 }
        return s
    }

    private func rank(query: String, _ books: [BookCandidate]) -> [BookCandidate] {
        // 版の統合。国会図書館は同じ本を何版も返してくるので束ねないと一覧が埋まる。
        var groups: [String: BookCandidate] = [:]
        for b in books {
            let key = Self.normalize(b.title) + "|" + Self.normalize(String(b.authors.prefix(10)))
            let weight = { (x: BookCandidate) in
                -x.srcRank * 1000 + (x.coverURL != nil ? 500 : 0) + (x.isbn13 != nil ? 100 : 0)
            }
            if let cur = groups[key] {
                if weight(b) > weight(cur) { groups[key] = b }
            } else {
                groups[key] = b
            }
        }
        return groups.values
            .map { var x = $0; x.score = score(query: query, $0); return x }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }

    /// 全角→半角、小文字化、空白と記号の除去。「７つの習慣」と「7つの習慣」を同じに扱う。
    static func normalize(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.lowercased()
        return t.replacingOccurrences(
            of: "[\\s　:：・,，.．\\-—ー〜~!！?？'\"“”『』「」【】()（）\\[\\]]",
            with: "", options: .regularExpression)
    }
}

// MARK: - 国会図書館の OpenSearch XML

enum NDLParser {
    static func parse(_ xml: String) -> [BookCandidate] {
        var out: [BookCandidate] = []
        var rest = Substring(xml)
        while let s = rest.range(of: "<item>"),
              let e = rest.range(of: "</item>", range: s.upperBound..<rest.endIndex) {
            let body = String(rest[s.upperBound..<e.lowerBound])
            rest = rest[e.upperBound...]

            guard let title = tag(body, "title") else { continue }
            var isbn: String?
            if let r = body.range(of: "dcndl:ISBN\"[^>]*>([0-9Xx\\-]+)", options: .regularExpression) {
                isbn = String(body[r]).components(separatedBy: ">").last?
                    .replacingOccurrences(of: "-", with: "")
            }
            out.append(BookCandidate(
                isbn13: isbn,
                title: title,
                authors: tag(body, "author") ?? tag(body, "dc:creator") ?? "",
                publisher: tag(body, "dc:publisher") ?? "",
                pubdate: (tag(body, "dc:date") ?? "").replacingOccurrences(of: "-", with: ""),
                coverURL: nil,
                source: .ndl,
                srcRank: 80 + out.count))
        }
        return out
    }

    private static func tag(_ body: String, _ name: String) -> String? {
        guard let open = body.range(of: "<\(name)[^>]*>", options: .regularExpression),
              let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex)
        else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
