import SwiftUI
import SwiftData

@main
struct YomitameApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Book.self, ReadingSession.self, Quote.self, Redemption.self])
        .onChange(of: scenePhase) { _, phase in
            // 多重防御の2枚目。拡張が起きなかった場合でも、
            // アプリが前面に戻った時点で期限を検算して再ロックする。
            if phase == .active { LockManager.reconcile() }
        }
    }
}

struct RootView: View {
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        if onboardingDone { tabs } else { OnboardingView() }
    }

    private var tabs: some View {
        TabView {
            ShelfView()
                .tabItem { Label("本棚", systemImage: "books.vertical.fill") }
            CalendarView()
                .tabItem { Label("カレンダー", systemImage: "calendar") }
            ReportView()
                .tabItem { Label("レポート", systemImage: "chart.bar.fill") }
            StoreView()
                .tabItem { Label("ストア", systemImage: "circle.circle.fill") }
            LockSettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
        }
        .tint(.white)
    }
}

/// 見た目の定数。ReadTime を実測して決めた値をここに集約する。
/// （背景は純黒、カードは #181818、アクセントは金1色、主ボタンは高さ58pt）
enum Theme {
    static let bg = Color.black
    static let card = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255)
    static let cardRaised = Color(red: 0x28 / 255, green: 0x28 / 255, blue: 0x28 / 255)
    static let gold = Color(red: 0xF8 / 255, green: 0xC8 / 255, blue: 0x38 / 255)
    static let sub = Color(white: 0.6)

    static let margin: CGFloat = 20
    static let buttonHeight: CGFloat = 58
    static let coverAspect: CGFloat = 2.0 / 3.0
}
