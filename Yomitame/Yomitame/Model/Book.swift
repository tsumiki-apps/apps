import Foundation
import SwiftData

@Model
final class Book {
    var id: UUID = UUID()
    var isbn13: String?
    var title: String = ""
    var authors: String = ""
    var publisher: String = ""
    var pubdate: String = ""
    var coverURLString: String?
    var totalPages: Int?
    var currentPage: Int = 0
    var statusRaw: String = ReadingStatus.tsundoku.rawValue
    var addedAt: Date = Date()
    var finishedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ReadingSession.book)
    var sessions: [ReadingSession] = []

    init(from c: BookCandidate) {
        self.isbn13 = c.isbn13
        self.title = c.title
        self.authors = c.authors
        self.publisher = c.publisher
        self.pubdate = c.pubdate
        self.coverURLString = c.coverURL?.absoluteString
    }

    init(title: String, authors: String = "") {
        self.title = title
        self.authors = authors
    }

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }

    var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .tsundoku }
        set { statusRaw = newValue.rawValue }
    }

    /// 読んだ合計分数（セッションから毎回導出する）
    var totalMinutes: Int { sessions.reduce(0) { $0 + $1.minutes } }
}

enum ReadingStatus: String, CaseIterable {
    case tsundoku, reading, finished

    var label: String {
        switch self {
        case .tsundoku: return "積読"
        case .reading: return "読書中"
        case .finished: return "読了"
        }
    }
}

@Model
final class ReadingSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var seconds: Int = 0
    var targetMinutes: Int = 30
    var endPage: Int?
    var memo: String?
    var book: Book?

    @Relationship(deleteRule: .cascade, inverse: \Quote.session)
    var quotes: [Quote] = []

    init(book: Book, seconds: Int, targetMinutes: Int) {
        self.book = book
        self.seconds = seconds
        self.targetMinutes = targetMinutes
    }

    /// 切り捨てで分に直す。表示だけ切り上げてコインを切り捨てる、といった食い違いを作らない。
    var minutes: Int { seconds / 60 }

    /// 読んだ分だけ素直に付与する。目標到達時のみ2割の上乗せ。
    var coins: Int {
        let base = minutes
        return reachedGoal ? base + Int(Double(base) * 0.2) : base
    }

    var reachedGoal: Bool { minutes >= targetMinutes }
}

/// 心に残った一節。読書の記録としてはコインより価値が長持ちするので、独立させて持つ。
@Model
final class Quote {
    var id: UUID = UUID()
    var text: String = ""
    var page: Int?
    var createdAt: Date = Date()
    var session: ReadingSession?

    init(text: String, page: Int? = nil) {
        self.text = text
        self.page = page
    }
}

/// コインとスマホ時間の交換履歴。
/// 残高＝Σセッションのコイン − Σ交換で消したコイン。残高そのものは保存しない。
@Model
final class Redemption {
    var id: UUID = UUID()
    var minutes: Int = 0
    var coins: Int = 0
    var redeemedAt: Date = Date()

    init(minutes: Int, coins: Int) {
        self.minutes = minutes
        self.coins = coins
    }
}
