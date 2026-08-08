import SwiftUI
import SwiftData

/// 読書セッションの結果。
///
/// ReadTime はここで「1分 読書しました」と表示しながら「+0 コイン」を出していた。
/// 表示と付与が食い違うと、いちばん嬉しいはずの画面が裏切りに変わる。
/// こちらは切り捨てた分数をそのまま見せ、0 のときは祝わずに「あと何秒か」を伝える。
struct SessionResultView: View {
    let book: Book
    let seconds: Int
    let targetMinutes: Int
    var quotes: [(String, Int?)] = []
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pageText = ""
    @State private var memo = ""

    private var minutes: Int { seconds / 60 }
    private var reachedGoal: Bool { minutes >= targetMinutes }
    private var coins: Int { reachedGoal ? minutes + minutes / 5 : minutes }
    private var secondsToNextCoin: Int { 60 - (seconds % 60) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    if coins > 0 { earned } else { tooShort }

                    section("どこまで読みましたか？") {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            TextField("0", text: $pageText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 90)
                                .overlay(Rectangle().frame(height: 1)
                                    .foregroundStyle(Theme.sub.opacity(0.4)), alignment: .bottom)
                            Text(book.totalPages.map { "/ \($0) ページ" } ?? "ページ")
                                .font(.footnote).foregroundStyle(Theme.sub)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    section("ひとこと") {
                        TextField("このセッションのメモ（任意）", text: $memo, axis: .vertical)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }

                    if !quotes.isEmpty {
                        section("保存する引用 \(quotes.count)件") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(quotes.enumerated()), id: \.offset) { _, q in
                                    Text("“\(q.0)")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.sub)
                                        .lineLimit(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Button("保存して完了") { save() }
                        .buttonStyle(PrimaryButton())
                        .padding(.horizontal, Theme.margin)
                        .padding(.top, 28)
                        .padding(.bottom, 30)
                }
            }
        }
    }

    private var earned: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.gold).frame(width: 95, height: 95)
                    .shadow(color: Theme.gold.opacity(0.5), radius: 22)
                Image(systemName: "book.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .padding(.top, 44)

            Text("+\(coins) コイン")
                .font(.system(size: 33, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text(reachedGoal
                 ? "\(minutes)分 読みました。目標達成で20%上乗せ"
                 : "\(minutes)分 読みました")
                .font(.caption)
                .foregroundStyle(Theme.sub)
        }
    }

    /// 1分に満たなかったとき。演出で祝ってから0を渡すのが最悪なので、静かに事実だけ伝える。
    private var tooShort: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.sub)
                .padding(.top, 52)
            Text("あと\(secondsToNextCoin)秒で1コイン")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("記録は残ります。続きはいつでも。")
                .font(.caption)
                .foregroundStyle(Theme.sub)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
            content()
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let session = ReadingSession(book: book, seconds: seconds, targetMinutes: targetMinutes)
        session.endPage = Int(pageText)
        session.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : memo
        for (text, page) in quotes {
            let q = Quote(text: text, page: page)
            q.session = session
            context.insert(q)
        }
        context.insert(session)

        if let p = Int(pageText) { book.currentPage = p }
        if book.status == .tsundoku { book.status = .reading }
        if let total = book.totalPages, let p = Int(pageText), p >= total {
            book.status = .finished
            book.finishedAt = Date()
        }
        dismiss()
        onDone()
    }
}
