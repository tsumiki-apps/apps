import SwiftUI
import SwiftData

struct AddBookView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [BookCandidate] = []
    @State private var phase: Phase = .idle
    @State private var added: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showingScanner = false

    private let service = BookSearchService()

    enum Phase: Equatable {
        case idle, searching, done, empty, deepening
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                    scanButton
                    content
                }
            }
            .sheet(isPresented: $showingScanner) { ScanSheet() }
            .navigationTitle("本を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }.tint(Theme.sub)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.sub)
            TextField("タイトル・著者・ISBNで検索", text: $query)
                .foregroundStyle(.white)
                .submitLabel(.search)
                .autocorrectionDisabled()
                // 入力の途中で「見つかりません」を出さないよう、300ms 止まってから走らせる
                .onChange(of: query) { _, new in schedule(new) }
            if phase == .searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .padding(Theme.margin)
    }

    private var scanButton: some View {
        Button { showingScanner = true } label: {
            Label("バーコードで連続スキャン", systemImage: "barcode.viewfinder")
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Spacer()
        case .searching where results.isEmpty:
            Spacer()
        case .empty:
            notFound
        default:
            list
        }
    }

    private var list: some View {
        List {
            ForEach(results) { c in
                HStack(spacing: 12) {
                    CoverImage(url: c.coverURL, title: c.title)
                        .frame(width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.title).font(.subheadline).lineLimit(2).foregroundStyle(.white)
                        Text(c.authors).font(.caption).lineLimit(1).foregroundStyle(Theme.sub)
                        Text(c.publisher).font(.caption2).foregroundStyle(Theme.sub.opacity(0.7))
                    }
                    Spacer()
                    Button {
                        add(c)
                    } label: {
                        Image(systemName: added.contains(c.id) ? "checkmark" : "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Theme.bg)
            }
            if phase == .deepening {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("国立国会図書館も探しています…")
                        .font(.caption).foregroundStyle(Theme.sub)
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var notFound: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("見つかりませんでした")
                .foregroundStyle(.white)
            Text("略称や通称では引けないことがあります。\nバーコードを読むか、手入力で追加できます。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.sub)
            Button("「\(query)」を手入力で追加") { addManually() }
                .buttonStyle(PrimaryButton())
                .padding(.horizontal, Theme.margin)
                .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - 検索

    private func schedule(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []; phase = .idle; return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)   // デバウンス
            guard !Task.isCancelled else { return }
            await run(q)
        }
    }

    private func run(_ q: String) async {
        phase = .searching
        let outcome = await service.search(q)
        guard !Task.isCancelled else { return }

        results = outcome.candidates
        if !outcome.candidates.isEmpty {
            phase = .done
            return
        }
        guard outcome.canDeepen else { phase = .empty; return }

        // 楽天が空振り。まず「見つかりません」を出し、国会図書館は裏で追う。
        phase = .deepening
        let deep = await service.deepen(q)
        guard !Task.isCancelled else { return }
        results = deep
        phase = deep.isEmpty ? .empty : .done
    }

    // MARK: - 追加

    private func add(_ c: BookCandidate) {
        guard !added.contains(c.id) else { return }
        context.insert(Book(from: c))
        added.insert(c.id)
    }

    private func addManually() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        context.insert(Book(title: q))
        dismiss()
    }
}
