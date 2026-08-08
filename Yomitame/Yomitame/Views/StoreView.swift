import SwiftUI
import SwiftData

/// コインをスマホ時間に交換する画面。
///
/// レートは 1コイン = 1分の**一律**。まとめ買い割引は付けない。
/// 「読んだ分だけ使える」という約束が単純であることそのものが、この仕組みの信用になる。
struct StoreView: View {
    @Environment(\.modelContext) private var context
    @Query private var sessions: [ReadingSession]
    @Query private var redemptions: [Redemption]

    @State private var confirming: Int?
    @State private var message: String?

    private let options = [1, 2, 3, 5, 10, 15, 25, 30, 60]

    private var balance: Int {
        sessions.reduce(0) { $0 + $1.coins } - redemptions.reduce(0) { $0 + $1.coins }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        if LockStore.isUnlocked { unlockedBanner }
                        grid
                        note
                    }
                }
            }
            .navigationTitle("ストア")
            .alert("スマホ時間と交換しますか？", isPresented: .init(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } })
            ) {
                Button("キャンセル", role: .cancel) { confirming = nil }
                Button("交換する") { if let m = confirming { redeem(m) } }
            } message: {
                if let m = confirming {
                    Text("\(m)コインを使って、選んだアプリを\(m)分だけ開けるようにします。")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "circle.circle.fill")
                    .font(.title2).foregroundStyle(Theme.gold)
                Text("\(balance)")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Text("読書1分 = スマホ1分。読んだぶんだけ使えます。")
                .font(.caption).foregroundStyle(Theme.sub)
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var unlockedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill").foregroundStyle(Theme.gold)
            Text("いま解放中：残り\(LockStore.remainingUnlockSeconds / 60 + 1)分")
                .font(.footnote).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 16)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                  spacing: 12) {
            ForEach(options, id: \.self) { m in
                let affordable = balance >= m
                Button { confirming = m } label: {
                    VStack(spacing: 6) {
                        Text("\(m)分")
                            .font(.headline)
                            .foregroundStyle(affordable ? .white : Theme.sub)
                        HStack(spacing: 3) {
                            Image(systemName: "circle.circle.fill").font(.caption2)
                            Text("\(m)").font(.caption).monospacedDigit()
                        }
                        .foregroundStyle(affordable ? Theme.gold : Theme.sub)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!affordable)
                .opacity(affordable ? 1 : 0.45)
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("交換すると、選んだアプリがその時間だけ開くようになります。時間が過ぎると自動でロックに戻ります。")
            Text("※ 端末の日付を変えたり、設定からスクリーンタイムの許可を切ったりすると、ロックは外れます。完全に防ぐことはできません。")
                .foregroundStyle(Theme.sub.opacity(0.8))
        }
        .font(.caption2)
        .foregroundStyle(Theme.sub)
        .padding(.horizontal, Theme.margin)
        .padding(.top, 22)
        .padding(.bottom, 30)
    }

    private func redeem(_ minutes: Int) {
        confirming = nil
        guard balance >= minutes else { return }
        context.insert(Redemption(minutes: minutes, coins: minutes))
        LockManager.unlock(minutes: minutes)
    }
}
