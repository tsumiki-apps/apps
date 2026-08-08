import Foundation

/// 読書記録の集計。画面から計算式を追い出しておく。
enum Stats {

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// 日付 → その日のセッション
    static func byDay(_ sessions: [ReadingSession]) -> [Date: [ReadingSession]] {
        Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startedAt) }
    }

    /// その日いちばん長く読んだ本（カレンダーに出す表紙を決めるため）
    static func mainBook(on day: Date, _ sessions: [ReadingSession]) -> Book? {
        let start = cal.startOfDay(for: day)
        let todays = sessions.filter { cal.startOfDay(for: $0.startedAt) == start }
        var minutesByBook: [Book: Int] = [:]
        for s in todays {
            guard let b = s.book else { continue }
            minutesByBook[b, default: 0] += s.seconds
        }
        return minutesByBook.max { $0.value < $1.value }?.key
    }

    // MARK: - ストリーク

    /// 連続日数。
    ///
    /// ただの連続カウントは諸刃で、1日途切れた時点で離脱を招く（Duolingo の知見）。
    /// **月2回までの「フリーズ」**で1日の欠けを埋め、続きとして数える。
    /// 途切れても責めない設計にしておかないと、いちばん続けてほしい人から順に辞めていく。
    static let freezesPerMonth = 2

    struct Streak {
        var days: Int
        var usedFreezes: Int
        var readToday: Bool
    }

    static func streak(_ sessions: [ReadingSession], now: Date = Date()) -> Streak {
        let days = Set(sessions.map { cal.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return .init(days: 0, usedFreezes: 0, readToday: false) }

        let today = cal.startOfDay(for: now)
        let readToday = days.contains(today)

        var count = 0
        var freezes = 0
        // 今日まだ読んでいない場合は昨日から数える（今日を欠けとして扱わない）
        var cursor = readToday ? today : cal.date(byAdding: .day, value: -1, to: today)!

        while true {
            if days.contains(cursor) {
                count += 1
            } else if freezes < freezesPerMonth {
                freezes += 1                     // 1日の欠けはフリーズで埋める
            } else {
                break
            }
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
            if count > 3650 { break }
        }
        // count は「実際に読んだ日」だけを数えている。フリーズで埋めた日は含まない。
        return .init(days: count, usedFreezes: freezes, readToday: readToday)
    }

    // MARK: - 期間の集計

    struct Summary {
        var totalMinutes: Int
        var daysRead: Int
        var averageMinutes: Int
        var finishedBooks: Int
        var redeemedMinutes: Int
        /// 日付（表示順）→ 読書分
        var series: [(label: String, minutes: Int)]
    }

    static func summary(sessions: [ReadingSession],
                        redemptions: [Redemption],
                        books: [Book],
                        weekly: Bool,
                        now: Date = Date()) -> Summary {
        let unit: Calendar.Component = weekly ? .day : .day
        let span = weekly ? 7 : cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let anchor = cal.startOfDay(for: now)

        var series: [(String, Int)] = []
        var total = 0, daysRead = 0
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.dateFormat = weekly ? "E" : "d"

        for offset in stride(from: span - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: unit, value: -offset, to: anchor) else { continue }
            let secs = sessions
                .filter { cal.startOfDay(for: $0.startedAt) == cal.startOfDay(for: day) }
                .reduce(0) { $0 + $1.seconds }
            let minutes = secs / 60
            total += minutes
            if minutes > 0 { daysRead += 1 }
            series.append((fmt.string(from: day), minutes))
        }

        let from = cal.date(byAdding: unit, value: -(span - 1), to: anchor)!
        let redeemed = redemptions
            .filter { $0.redeemedAt >= from }
            .reduce(0) { $0 + $1.minutes }
        let finished = books
            .filter { ($0.finishedAt ?? .distantPast) >= from }
            .count

        return Summary(totalMinutes: total,
                       daysRead: daysRead,
                       averageMinutes: daysRead == 0 ? 0 : total / daysRead,
                       finishedBooks: finished,
                       redeemedMinutes: redeemed,
                       series: series)
    }
}

extension Book: Hashable {
    static func == (lhs: Book, rhs: Book) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
