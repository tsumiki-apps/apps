import SwiftUI
import SwiftData

/// 読書タイマー。
///
/// ReadTime との違い（意図的に変えた点）:
/// - **カウントアップも選べる**。「読める分だけ読む」を許さないと、短い読書が全部ゼロ扱いになる。
/// - **コインは経過分に比例**。完走時のみ2割の上乗せ。「1分=1コイン」と言った以上それを守る。
/// - 0コインのときは**祝わない**。あと何秒で1コインかを出す。
struct ReadingTimerView: View {
    let book: Book
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var targetMinutes: Int
    @State private var countsDown = true
    @State private var startedAt: Date?
    @State private var accumulated: TimeInterval = 0      // 一時停止をまたいだ合計
    @State private var now = Date()
    @State private var showingResult = false
    @State private var draftQuote = ""
    @State private var quotePage = ""
    @State private var showingQuote = false
    /// 保存はセッション確定時にまとめて行う（途中でやめたら記録も残さない）
    @State private var pendingQuotes: [(String, Int?)] = []

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(book: Book, defaultGoal: Int = 30) {
        self.book = book
        _targetMinutes = State(initialValue: defaultGoal)
    }

    private var elapsed: TimeInterval {
        accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }
    private var running: Bool { startedAt != nil }
    private var remaining: TimeInterval { max(0, Double(targetMinutes * 60) - elapsed) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if startedAt == nil && accumulated == 0 {
                setup
            } else {
                timer
            }
        }
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $showingQuote) { quoteSheet }
        .fullScreenCover(isPresented: $showingResult) {
            SessionResultView(book: book,
                              seconds: Int(elapsed),
                              targetMinutes: targetMinutes,
                              quotes: pendingQuotes) { dismiss() }
        }
    }

    // MARK: - 開始前

    private var setup: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .tint(.white)
                Spacer()
            }
            .padding(Theme.margin)

            Spacer()
            CoverImage(url: book.coverURL, title: book.title)
                .frame(width: 130)
            Text(book.title)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 14)

            Menu {
                ForEach([5, 10, 15, 20, 25, 30, 40, 50, 60], id: \.self) { m in
                    Button("\(m)分") { targetMinutes = m }
                }
            } label: {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(targetMinutes)").font(.system(size: 68, weight: .light))
                    Text("分").font(.title3)
                }
                .foregroundStyle(.white)
            }
            .padding(.top, 26)

            Text("タップして変更")
                .font(.caption).foregroundStyle(Theme.sub)

            Label("1分ごとに1コイン。完走で20%上乗せ（最大 \(targetMinutes + targetMinutes / 5) コイン）",
                  systemImage: "circle.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.gold)
                .padding(.top, 16)

            Picker("", selection: $countsDown) {
                Text("目標まで数える").tag(true)
                Text("読めた分だけ").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 60)
            .padding(.top, 22)

            Spacer()
            Button("読書を開始する") { startedAt = Date() }
                .buttonStyle(PrimaryButton())
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 20)
        }
    }

    // MARK: - 計測中

    private var timer: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                Spacer()
                Button { finish() } label: { Image(systemName: "checkmark") }
            }
            .tint(.white)
            .padding(Theme.margin)

            Spacer()
            // 暗い部屋で読む前提。白ではなくグレーにしてまぶしさを抑える。
            Text(display)
                .font(.system(size: 62, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.66))
            Text(book.title)
                .font(.footnote)
                .foregroundStyle(Color(white: 0.34))
                .lineLimit(1)
                .padding(.horizontal, 40)
                .padding(.top, 6)
            Spacer()

            HStack(spacing: 34) {
                circleButton("quote.opening") { showingQuote = true }
                circleButton(running ? "pause.fill" : "play.fill", large: true) { toggle() }
                circleButton("checkmark") { finish() }
            }
            .padding(.bottom, 46)
        }
    }

    private var display: String {
        let t = Int(countsDown ? remaining : elapsed)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private func circleButton(_ symbol: String, large: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 24 : 18))
                .foregroundStyle(.white)
                .frame(width: large ? 78 : 66, height: large ? 78 : 66)
                .background(Theme.card, in: Circle())
        }
    }

    private func toggle() {
        if let s = startedAt {
            accumulated += Date().timeIntervalSince(s)
            startedAt = nil
        } else {
            startedAt = Date()
        }
    }

    private func finish() {
        if let s = startedAt {
            accumulated += Date().timeIntervalSince(s)
            startedAt = nil
        }
        showingResult = true
    }

    // MARK: - 引用

    private var quoteSheet: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 14) {
                    TextEditor(text: $draftQuote)
                        .scrollContentBackground(.hidden)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .frame(height: 180)
                    TextField("ページ番号（任意）", text: $quotePage)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(Theme.margin)
            }
            .navigationTitle("フレーズを保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { showingQuote = false }.tint(Theme.sub)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { pendingQuotes.append((draftQuote, Int(quotePage)))
                        draftQuote = ""; quotePage = ""; showingQuote = false }
                        .tint(Theme.gold)
                        .disabled(draftQuote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
