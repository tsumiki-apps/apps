import SwiftUI

/// はじめての導入。
///
/// ReadTime のここだけは本当によくできていたので、型を借りる：
/// 共感 → 2つの質問 → **本人の入力から計算した数字** → 仕組みの説明 → 目標 → 自分との約束。
/// 一般論を語らず「あなたの場合はこうです」と言えるから刺さる。
///
/// 借りないもの：実在SNSのアイコン、体験前の課金要求、閉じたら半額の二重価格。
struct OnboardingView: View {
    @AppStorage("onboardingDone") private var done = false
    @AppStorage("dailyGoalMinutes") private var dailyGoal = 30
    @AppStorage("monthlyBookGoal") private var bookGoal = 4
    @AppStorage("dailyPhoneHours") private var phoneHours = 4

    @State private var step = 0

    /// 1冊を読み切るのにかかる時間の目安。ここを起点に「1日◯分」を逆算する。
    private static let minutesPerBook = 250.0

    private var minutesPerDay: Int {
        Int((Double(bookGoal) * Self.minutesPerBook / 30).rounded())
    }
    private var shareOfPhone: Int {
        max(1, Int((Double(minutesPerDay) / Double(phoneHours * 60) * 100).rounded()))
    }

    private let lastStep = 6

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if step > 0 { progress }
                content
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private var progress: some View {
        HStack(spacing: 12) {
            Button { step -= 1 } label: { Image(systemName: "chevron.left") }
                .tint(.white)
                .opacity(step > 1 ? 1 : 0)
                .disabled(step <= 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardRaised)
                    Capsule().fill(.white)
                        .frame(width: geo.size.width * CGFloat(step) / CGFloat(lastStep))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: NarrativeStep { step = 1 }
        case 1: phoneStep
        case 2: bookStep
        case 3: proofStep
        case 4: mechanicsStep
        case 5: goalStep
        default: CommitStep(minutes: dailyGoal) { done = true }
        }
    }

    // MARK: - 1. スマホ時間

    private var phoneStep: some View {
        StepScaffold(title: "1日にどれくらい\nスマホを見ていますか？",
                     subtitle: "だいたいの時間で大丈夫です。",
                     cta: "次へ") { step = 2 } content: {
            VStack(spacing: 30) {
                BigNumber(value: "\(phoneHours)", unit: "時間")
                VStack(spacing: 6) {
                    Slider(value: .init(get: { Double(phoneHours) },
                                        set: { phoneHours = Int($0.rounded()) }),
                           in: 1...10, step: 1)
                    .tint(.white)
                    HStack {
                        Text("1時間"); Spacer(); Text("10時間")
                    }
                    .font(.caption2).foregroundStyle(Theme.sub)
                }
            }
        }
    }

    // MARK: - 2. 読みたい冊数

    private var bookStep: some View {
        StepScaffold(title: "月に何冊\n読みたいですか？",
                     subtitle: "わくわくする、でも届きそうな数字に。",
                     cta: "次へ") { step = 3 } content: {
            VStack(spacing: 26) {
                HStack(spacing: 34) {
                    stepper("minus") { bookGoal = max(1, bookGoal - 1) }
                    BigNumber(value: "\(bookGoal)", unit: "")
                        .frame(minWidth: 90)
                    stepper("plus") { bookGoal = min(20, bookGoal + 1) }
                }
                Slider(value: .init(get: { Double(bookGoal) },
                                    set: { bookGoal = Int($0.rounded()) }),
                       in: 1...20, step: 1)
                .tint(.white)

                Label("1日あたり約\(minutesPerDay)分の読書ペースです。", systemImage: "book")
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
            }
        }
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Theme.cardRaised, in: Circle())
        }
    }

    // MARK: - 3. 本人の数字で示す（ここが山場）

    private var proofStep: some View {
        StepScaffold(title: "スマホの時間を減らせば、\n十分に可能です。",
                     subtitle: "1日わずか\(minutesPerDay)分の読書で、月\(bookGoal)冊のペースに。いまのスマホ時間の約\(shareOfPhone)%です。",
                     cta: "次へ") { step = 4 } content: {
            CrossingChart(badge: "月\(bookGoal)冊")
        }
    }

    // MARK: - 4. 仕組み

    private var mechanicsStep: some View {
        StepScaffold(title: "読んだ分だけ、\n使えるようになります。",
                     subtitle: nil,
                     cta: "次へ") { step = 5 } content: {
            VStack(spacing: 18) {
                mechanic("lock.fill", "選んだアプリをロック",
                         "時間を奪っているアプリだけを選びます。連絡や地図は止めません。")
                mechanic("circle.circle.fill", "1分読むと、1コイン",
                         "読んだ分がそのままコインになります。目標まで読めたら20%の上乗せ。")
                mechanic("arrow.left.arrow.right", "コインを時間に交換",
                         "1コインで1分だけ開きます。時間が過ぎると自動でロックに戻ります。")
            }
        }
    }

    private func mechanic(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.gold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(body).font(.caption).foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 5. 目標

    private var goalStep: some View {
        StepScaffold(title: "1日何分、\n本を読みますか？",
                     subtitle: "月\(bookGoal)冊の目標から計算した目安です。あとから変更できます。",
                     cta: "この目標にする") { step = 6 } content: {
            VStack(spacing: 12) {
                Picker("", selection: $dailyGoal) {
                    ForEach(Array(stride(from: 5, through: 120, by: 5)), id: \.self) { m in
                        Text("\(m) 分").tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 150)

                Label("1日\(dailyGoal)分で、月に約\(Int((Double(dailyGoal) * 30 / Self.minutesPerBook).rounded()))冊。",
                      systemImage: "chart.bar.fill")
                    .font(.footnote).foregroundStyle(Theme.sub)
            }
            .onAppear { if dailyGoal == 30 { dailyGoal = max(5, (minutesPerDay / 5) * 5) } }
        }
    }
}

// MARK: - 共通の骨組み

private struct StepScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    let cta: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.sub)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            content
            Spacer()
            Button(cta, action: action)
                .buttonStyle(PrimaryButton())
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 20)
    }
}

private struct BigNumber: View {
    let value: String
    let unit: String
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 74, weight: .semibold))
            if !unit.isEmpty { Text(unit).font(.title2.weight(.medium)) }
        }
        .foregroundStyle(.white)
        .contentTransition(.numericText())
        .animation(.snappy, value: value)
    }
}

// MARK: - 交差する2本線

/// 「読書が増え、スマホが減る」を1枚で見せる図。
/// 説明文を10行書くより、線が交差する絵のほうが速い。
private struct CrossingChart: View {
    let badge: String
    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                legend(.white, "読書の時間")
                legend(Color(red: 0.55, green: 0.45, blue: 0.95), "スマホの時間")
                Spacer()
            }
            .font(.caption2)

            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack {
                        curve(rising: false, in: w, h: h)
                            .trim(from: 0, to: progress)
                            .stroke(Color(red: 0.55, green: 0.45, blue: 0.95),
                                    style: .init(lineWidth: 3, lineCap: .round))
                        curve(rising: true, in: w, h: h)
                            .trim(from: 0, to: progress)
                            .stroke(.white, style: .init(lineWidth: 3, lineCap: .round))
                    }
                }
                .frame(height: 150)

                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white, in: Capsule())
                    .padding(8)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))

            HStack {
                Text("いま"); Spacer(); Text("1ヶ月後")
            }
            .font(.caption2).foregroundStyle(Theme.sub)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1)) { progress = 1 }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(Theme.sub)
        }
    }

    /// S字カーブ。上がる線と下がる線が中央で交わる。
    private func curve(rising: Bool, in w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            let y0 = rising ? h * 0.88 : h * 0.12
            let y1 = rising ? h * 0.12 : h * 0.88
            p.move(to: .init(x: 0, y: y0))
            p.addCurve(to: .init(x: w, y: y1),
                       control1: .init(x: w * 0.45, y: y0),
                       control2: .init(x: w * 0.55, y: y1))
        }
    }
}

// MARK: - 0. ナラティブ

private struct NarrativeStep: View {
    let onNext: () -> Void
    @State private var shown = 0

    private let lines = [
        "読みたい本は、たくさんある。",
        "でも気づけば、スマホを開いていた。",
        "今日も、1ページも読めなかった。",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(Theme.sub)
                    .opacity(shown > i ? 1 : 0)
                    .offset(y: shown > i ? 0 : 8)
            }
            if shown > 3 {
                Text("もし毎日読書できていたら、\n何が変わっていただろう。")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            Spacer()
            if shown > 4 {
                Button("はじめる", action: onNext)
                    .buttonStyle(PrimaryButton())
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 20)
        .task {
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 850_000_000)
                withAnimation(.easeOut(duration: 0.5)) { shown += 1 }
            }
        }
    }
}

// MARK: - 6. 自分との約束

/// 指で✓を描かせる。タップではなく手を動かすことで、約束の重みが変わる。
/// 行動経済学でいうコミットメント装置（＝自分で自分を縛る仕掛け）をUIにしたもの。
/// ReadTime はこの直後に課金画面を出していたが、こちらはそのまま本棚へ入る。
private struct CommitStep: View {
    let minutes: Int
    let onDone: () -> Void

    @State private var stroke: [CGPoint] = []
    @State private var signed = false
    @State private var confetti = false

    var body: some View {
        VStack(spacing: 0) {
            Text("毎日\(minutes)分の読書に\nコミットしますか？")
                .font(.system(size: 25, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text("自分との小さな約束が、習慣をつくります。")
                .font(.footnote).foregroundStyle(Theme.sub)
                .padding(.top, 10)

            Spacer()
            ZStack {
                Image(systemName: "book.pages")
                    .font(.system(size: 74, weight: .ultraLight))
                    .foregroundStyle(Theme.sub.opacity(0.7))
                if confetti { Confetti() }
            }
            Spacer()

            Text("✓ をサインしてコミット")
                .font(.caption)
                .foregroundStyle(signed ? Theme.gold : Theme.sub)

            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.cardRaised)
                Path { p in
                    guard let first = stroke.first else { return }
                    p.move(to: first)
                    for pt in stroke.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Theme.gold, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
                if stroke.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.sub.opacity(0.45))
                }
            }
            .frame(height: 150)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { stroke.append($0.location) }
                    .onEnded { _ in
                        // 短すぎる線は誤タップ。ある程度の長さを描いたときだけ成立させる。
                        guard strokeLength > 90, !signed else { return }
                        signed = true
                        confetti = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
            )
            .padding(.top, 8)

            Button(signed ? "読書をはじめる" : "上に ✓ をサインしてコミット", action: onDone)
                .buttonStyle(PrimaryButton())
                .disabled(!signed)
                .opacity(signed ? 1 : 0.4)
                .padding(.top, 16)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, 20)
    }

    private var strokeLength: CGFloat {
        guard stroke.count > 1 else { return 0 }
        return zip(stroke, stroke.dropFirst()).reduce(0) { acc, pair in
            acc + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }
}

private struct Confetti: View {
    @State private var go = false
    private let colors: [Color] = [.white, Theme.gold, .orange, .cyan, .pink]

    var body: some View {
        ZStack {
            ForEach(0..<26, id: \.self) { i in
                let angle = Double(i) / 26 * 2 * .pi
                let distance: CGFloat = go ? 150 : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 11)
                    .rotationEffect(.degrees(Double(i) * 37))
                    .offset(x: cos(angle) * distance,
                            y: sin(angle) * distance + (go ? 60 : 0))
                    .opacity(go ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { go = true } }
    }
}
