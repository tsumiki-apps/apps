import SwiftUI
import FamilyControls

/// ロックの設定。
///
/// ReadTime はここで「すべてのアプリおよびカテゴリ」を無警告で選ばせ、
/// Notion・Safari・設定・計算機まで巻き添えにしていた。
/// 仕事や連絡の道具を守ることを既定にして、全部ロックは警告つきの例外にする。
struct LockSettingsView: View {
    @State private var enabled = LockStore.enabled
    @State private var selection = LockStore.selection
    @State private var showingPicker = false
    @State private var authorizing = false
    @State private var authError: String?
    @State private var authorized = LockManager.isAuthorized

    private var count: Int {
        selection.applicationTokens.count + selection.categoryTokens.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !authorized { permissionCard } else { lockCard }
                        honesty
                    }
                }
            }
            .navigationTitle("設定")
            .familyActivityPicker(isPresented: $showingPicker, selection: $selection)
            .onChange(of: selection) { _, new in
                LockStore.selection = new
                if enabled { LockManager.reconcile() }
            }
            .task { authorized = LockManager.isAuthorized }
        }
    }

    // MARK: - 権限（理由 → 予告 → 本番の3段）

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("スクリーンタイムを許可してください")
                .font(.title3.weight(.bold)).foregroundStyle(.white)
            Text("選んだアプリをロックし、読書で貯めたコインと引き換えに解除するために使います。使用状況を集めたり、外部に送ったりはしません。")
                .font(.footnote).foregroundStyle(Theme.sub)

            Text("次の画面で「続ける」を選んでください。")
                .font(.caption).foregroundStyle(Theme.gold)

            if let e = authError {
                Text(e).font(.caption).foregroundStyle(.red)
            }

            Button(authorizing ? "確認中…" : "許可に進む") {
                Task { await authorize() }
            }
            .buttonStyle(PrimaryButton())
            .disabled(authorizing)
        }
        .padding(Theme.margin)
    }

    private func authorize() async {
        authorizing = true
        defer { authorizing = false }
        do {
            try await LockManager.requestAuthorization()
            authorized = LockManager.isAuthorized
            authError = nil
        } catch {
            authError = "許可されませんでした。設定 → スクリーンタイム から確認してください。（\(error.localizedDescription)）"
        }
    }

    // MARK: - ロック対象

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("アプリをロックする").foregroundStyle(.white)
                    Text("読書で貯めたコインと引き換えに開けます")
                        .font(.caption).foregroundStyle(Theme.sub)
                }
            }
            .tint(Theme.gold)
            .onChange(of: enabled) { _, on in
                LockStore.enabled = on
                on ? LockManager.lock() : LockManager.unlock(minutes: 0)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))

            Button { showingPicker = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ロックするアプリ").foregroundStyle(.white)
                        Text(count == 0 ? "まだ選んでいません" : "\(count)件を選択中")
                            .font(.caption).foregroundStyle(count == 0 ? Theme.sub : Theme.gold)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.sub)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Text("時間を奪っているアプリだけを選んでください。連絡・地図・カメラなど毎日必要な道具まで止めると、生活のほうが壊れます。")
                .font(.caption2)
                .foregroundStyle(Theme.sub)
                .padding(.top, 10)
        }
        .padding(Theme.margin)
    }

    // MARK: - できないことを先に言う

    private var honesty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("このロックでできないこと")
                .font(.footnote.weight(.semibold)).foregroundStyle(.white)
            ForEach([
                "端末の日付を変えると外れます",
                "設定からスクリーンタイムの許可を切ると外れます",
                "iOS の仕組み上、再ロックが遅れることがあります（アプリを開き直すと直ります）",
            ], id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text("・").foregroundStyle(Theme.sub)
                    Text(line).foregroundStyle(Theme.sub)
                }
                .font(.caption)
            }
            Text("「絶対に開けない」とは言いません。開けようと思えば開けます。それでも、ひと手間あるだけで戻ってこられることのほうが多い、という道具です。")
                .font(.caption2)
                .foregroundStyle(Theme.sub.opacity(0.8))
                .padding(.top, 4)
        }
        .padding(Theme.margin)
        .padding(.bottom, 30)
    }
}
