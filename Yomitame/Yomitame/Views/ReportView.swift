import SwiftUI
import SwiftData

/// 週間・月間の振り返り。
///
/// 「読んだ時間」と「引き換えたスマホ時間」を**並べて**見せるのがこの画面の役目。
/// 貯めるだけでも使うだけでもなく、両方が見えて初めて交換の実感になる。
struct ReportView: View {
    @Query private var sessions: [ReadingSession]
    @Query private var redemptions: [Redemption]
    @Query private var books: [Book]

    @State private var weekly = true

    private var summary: Stats.Summary {
        Stats.summary(sessions: sessions, redemptions: redemptions,
                      books: books, weekly: weekly)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        Picker("", selection: $weekly) {
                            Text("週間").tag(true)
                            Text("月間").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                        .padding(.top, 8)

                        total
                        BarSeries(series: summary.series, color: .white, unit: "分")
                            .padding(.top, 22)
                        stats
                        redeemed
                        footer
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("レポート")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var total: some View {
        VStack(spacing: 4) {
            Text("読書時間").font(.caption).foregroundStyle(Theme.sub)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                if summary.totalMinutes >= 60 {
                    Text("\(summary.totalMinutes / 60)")
                        .font(.system(size: 38, weight: .bold))
                    Text("時間").font(.subheadline)
                }
                Text("\(summary.totalMinutes % 60)")
                    .font(.system(size: 38, weight: .bold))
                Text("分").font(.subheadline)
            }
            .foregroundStyle(.white)
            .monospacedDigit()
        }
        .padding(.top, 22)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("\(summary.daysRead)日", "読書した日")
            divider
            stat("\(summary.averageMinutes)分", "1日あたり")
            divider
            stat("\(summary.finishedBooks)冊", "読了")
        }
        .padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, Theme.margin)
        .padding(.top, 22)
    }

    private var divider: some View {
        Rectangle().fill(Theme.sub.opacity(0.25)).frame(width: 1, height: 30)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline).foregroundStyle(.white).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
    }

    private var redeemed: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("引き換えたスマホ時間")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text("\(summary.redeemedMinutes)分")
                    .font(.footnote).foregroundStyle(Theme.gold).monospacedDigit()
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, 28)
        }
    }

    private var footer: some View {
        Text("読書1分 = スマホ1分。読むほど、使える。")
            .font(.caption2)
            .foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
    }
}

/// 棒グラフ。Charts を使うほどの情報量ではないので手で描く。
/// 値が0の日も薄い棒を残して「読まなかった日」を見えるようにする。
private struct BarSeries: View {
    let series: [(label: String, minutes: Int)]
    let color: Color
    let unit: String

    private var peak: Int { max(series.map(\.minutes).max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: series.count > 10 ? 3 : 8) {
                ForEach(series.indices, id: \.self) { i in
                    let m = series[i].minutes
                    RoundedRectangle(cornerRadius: 3)
                        .fill(m > 0 ? color : Theme.cardRaised)
                        .frame(height: max(4, CGFloat(m) / CGFloat(peak) * 90))
                }
            }
            .frame(height: 90, alignment: .bottom)

            if series.count <= 10 {
                HStack(spacing: 8) {
                    ForEach(series.indices, id: \.self) { i in
                        Text(series[i].label)
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}
