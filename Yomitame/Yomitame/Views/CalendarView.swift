import SwiftUI
import SwiftData

/// 読んだ日に本の表紙が並ぶカレンダー。
///
/// 数字のグリッドより「本が積み上がっている絵」のほうが嬉しい、という一点だけの画面。
/// ReadTime がいちばん気持ちよかったのもここだった。
struct CalendarView: View {
    @Query private var sessions: [ReadingSession]
    @State private var month = Date()

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private var streak: Stats.Streak { Stats.streak(sessions) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        streakCard
                        header
                        weekdayRow
                        grid
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("カレンダー")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - ストリーク

    private var streakCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(streak.days > 0 ? Theme.gold : Theme.sub)
            VStack(alignment: .leading, spacing: 2) {
                Text(streak.days > 0 ? "\(streak.days)日つづいています" : "今日から始めましょう")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, Theme.margin)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if streak.usedFreezes > 0 {
            // 途切れを責めない。埋めたことを淡々と伝えるだけにする。
            return "お休みを\(streak.usedFreezes)日ぶん埋めました（月\(Stats.freezesPerMonth)日まで）"
        }
        return streak.readToday ? "今日はもう読みました" : "今日はまだです"
    }

    // MARK: - 月の切り替え

    private var header: some View {
        HStack {
            Text(monthTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            Button { shift(-1) } label: { chevron("chevron.left") }
            Button { shift(1) } label: { chevron("chevron.right") }
                .disabled(cal.compare(month, to: Date(), toGranularity: .month) != .orderedAscending)
                .opacity(cal.compare(month, to: Date(), toGranularity: .month) == .orderedAscending ? 1 : 0.35)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 12)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Theme.card, in: Circle())
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年 M月"
        return f.string(from: month)
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: month) { month = d }
    }

    // MARK: - 日付グリッド

    private var weekdayRow: some View {
        HStack(spacing: 6) {
            ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { d in
                Text(d)
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 8)
    }

    private var grid: some View {
        let days = daysInMonth
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                         spacing: 6) {
            ForEach(days.indices, id: \.self) { i in
                if let day = days[i] {
                    cell(day)
                } else {
                    Color.clear.aspectRatio(Theme.coverAspect, contentMode: .fit)
                }
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func cell(_ day: Date) -> some View {
        let book = Stats.mainBook(on: day, sessions)
        let isToday = cal.isDateInToday(day)
        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.card)
                if let book {
                    CoverImage(url: book.coverURL, title: book.title)
                }
            }
            .aspectRatio(Theme.coverAspect, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white, lineWidth: isToday ? 1.5 : 0)
            )
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 9))
                .foregroundStyle(isToday ? .white : Theme.sub)
        }
    }

    /// 月初の曜日ぶんだけ nil を頭に詰めた配列
    private var daysInMonth: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let leading = cal.component(.weekday, from: interval.start) - 1
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in range {
            if let date = cal.date(byAdding: .day, value: d - 1, to: interval.start) {
                out.append(date)
            }
        }
        return out
    }
}
