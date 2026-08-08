import SwiftUI
import SwiftData

/// 本の詳細。
///
/// ReadTime には「引用を見返す場所」が無かった。読んだ時間はコインになって消えるが、
/// 残るのは書き留めた一節のほうなので、この画面をコインより前に置く。
struct BookDetailView: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("dailyGoalMinutes") private var dailyGoal = 30

    @State private var reading = false
    @State private var editingPages = false
    @State private var pagesDraft = ""
    @State private var confirmDelete = false

    private let service = BookSearchService()

    private var quotes: [Quote] {
        book.sessions.flatMap(\.quotes).sorted { $0.createdAt > $1.createdAt }
    }
    private var memos: [ReadingSession] {
        book.sessions.filter { !($0.memo ?? "").isEmpty }.sorted { $0.startedAt > $1.startedAt }
    }
    private var totalCoins: Int { book.sessions.reduce(0) { $0 + $1.coins } }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    progress
                    stats
                    if !quotes.isEmpty { quoteSection }
                    if !memos.isEmpty { memoSection }
                    actions
                }
                // タブバーがスクロール内容に重なるので、その高さぶん逃がす
                .padding(.bottom, 100)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ReadingStatus.allCases, id: \.self) { s in
                        Button {
                            book.status = s
                            book.finishedAt = (s == .finished) ? Date() : nil
                        } label: {
                            Label(s.label, systemImage: book.status == s ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button("この本を削除", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").tint(.white)
                }
            }
        }
        .fullScreenCover(isPresented: $reading) {
            ReadingTimerView(book: book, defaultGoal: dailyGoal)
        }
        .alert("この本を削除しますか？", isPresented: $confirmDelete) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                context.delete(book)
                dismiss()
            }
        } message: {
            Text("読書の記録と引用もいっしょに消えます。")
        }
        // 楽天はページ数を返さないので、開いたときに openBD から補う
        .task {
            guard book.totalPages == nil, let isbn = book.isbn13 else { return }
            if let n = await service.pageCount(isbn: isbn) { book.totalPages = n }
        }
    }

    // MARK: - 見出し

    private var header: some View {
        VStack(spacing: 12) {
            CoverImage(url: book.coverURL, title: book.title)
                .frame(width: 150)
                .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
                .padding(.top, 10)

            Text(book.status.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(book.status == .finished ? .black : Theme.sub)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(book.status == .finished ? Theme.gold : Theme.card, in: Capsule())

            Text(book.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            VStack(spacing: 2) {
                Text(book.authors).foregroundStyle(Theme.sub)
                if !book.publisher.isEmpty {
                    Text(book.publisher).foregroundStyle(Theme.sub.opacity(0.7))
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, Theme.margin)
    }

    // MARK: - 進捗

    private var progress: some View {
        VStack(spacing: 8) {
            if let total = book.totalPages, total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cardRaised)
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * min(1, CGFloat(book.currentPage) / CGFloat(total)))
                    }
                }
                .frame(height: 3)

                Button {
                    pagesDraft = "\(book.currentPage)"
                    editingPages = true
                } label: {
                    Text("\(book.currentPage) / \(total) ページ")
                        .font(.caption).foregroundStyle(Theme.sub).monospacedDigit()
                }
            } else {
                Button {
                    pagesDraft = ""
                    editingPages = true
                } label: {
                    Label("ページ数を入力", systemImage: "plus.circle")
                        .font(.caption).foregroundStyle(Theme.sub)
                }
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 22)
        .alert("ページ", isPresented: $editingPages) {
            TextField(book.totalPages == nil ? "総ページ数" : "いま何ページ？", text: $pagesDraft)
                .keyboardType(.numberPad)
            Button("キャンセル", role: .cancel) {}
            Button("保存") {
                guard let n = Int(pagesDraft), n > 0 else { return }
                if book.totalPages == nil { book.totalPages = n } else { book.currentPage = n }
            }
        }
    }

    // MARK: - 統計

    private var stats: some View {
        HStack(spacing: 0) {
            stat("\(book.totalMinutes)分", "読んだ時間")
            Rectangle().fill(Theme.sub.opacity(0.25)).frame(width: 1, height: 28)
            stat("\(book.sessions.count)回", "セッション")
            Rectangle().fill(Theme.sub.opacity(0.25)).frame(width: 1, height: 28)
            stat("\(totalCoins)", "コイン")
        }
        .padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, Theme.margin)
        .padding(.top, 22)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold))
                .foregroundStyle(.white).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 引用

    private var quoteSection: some View {
        section("引用 \(quotes.count)件") {
            VStack(spacing: 10) {
                ForEach(quotes) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q.text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if let p = q.page {
                                Text("p.\(p)").font(.caption2).foregroundStyle(Theme.gold)
                            }
                            Spacer()
                            Button {
                                UIPasteboard.general.string = q.text
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption2)
                            }
                            .tint(Theme.sub)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.gold).frame(width: 3)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .contextMenu {
                        Button("削除", role: .destructive) { context.delete(q) }
                    }
                }
            }
        }
    }

    // MARK: - メモ

    private var memoSection: some View {
        section("ひとこと \(memos.count)件") {
            VStack(spacing: 10) {
                ForEach(memos) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.memo ?? "")
                            .font(.subheadline).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(Theme.sub)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
            content()
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(spacing: 10) {
            Button("読書を開始する") { reading = true }
                .buttonStyle(PrimaryButton())

            if book.status != .finished {
                Button("読み終わった") {
                    book.status = .finished
                    book.finishedAt = Date()
                    if let t = book.totalPages { book.currentPage = t }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.sub)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 30)
    }
}
