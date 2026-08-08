import SwiftUI
import SwiftData

struct ShelfView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query private var sessions: [ReadingSession]
    @State private var showingAdd = false
    @State private var reading: Book?

    /// コイン残高は保持せず、毎回セッションから導出する。
    /// 残高を実体で持つと、一度ずれたときに直せない（ReadTime の +0コイン問題の温床）。
    private var coins: Int { sessions.reduce(0) { $0 + $1.coins } }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if books.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .navigationTitle("本棚")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sessions.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "circle.circle.fill").foregroundStyle(Theme.gold)
                            Text("\(coins)").foregroundStyle(.white).monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .tint(.white)
                }
            }
            .sheet(isPresented: $showingAdd) { AddBookView() }
            .fullScreenCover(item: $reading) { ReadingTimerView(book: $0) }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.sub)
            Text("まだ本がありません")
                .foregroundStyle(.white)
            Text("バーコードを読むか、書名で探して\n最初の1冊を入れましょう。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.sub)
            Button("本を追加") { showingAdd = true }
                .buttonStyle(PrimaryButton())
                .padding(.top, 8)
                .padding(.horizontal, Theme.margin)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 20) {
                ForEach(books) { book in
                    Button { reading = book } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        CoverImage(url: book.coverURL, title: book.title)
                        Text(book.title)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.white)
                        Text(book.status.label)
                            .font(.caption2)
                            .foregroundStyle(Theme.sub)
                    }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.margin)
        }
    }
}

/// 書影。楽天は 100% 書影を返すが、国会図書館経由や手入力では無いのでその場合は題字で代替する。
struct CoverImage: View {
    let url: URL?
    let title: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Theme.cardRaised
                    Text(title.prefix(12))
                        .font(.caption2)
                        .foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                        .padding(6)
                }
            }
        }
        .aspectRatio(Theme.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.buttonHeight)
            .background(.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
