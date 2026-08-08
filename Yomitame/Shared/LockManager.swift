import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// ロックの実行役。アプリ本体からも拡張からも呼ばれる。
///
/// ⚠️ Apple の API は「解放が終わったら勝手に再ロックしてくれる」ことを保証しない。
/// `intervalDidEnd` が発火しない事例が Apple Developer Forums に多数報告されており
/// （ReadTime の「制限時間後もアプリを使えてしまう」不具合もおそらくこれ）、
/// タイマーひとつに頼ると同じ穴が開く。だから守りを3枚重ねる。
///
///   1枚目: DeviceActivitySchedule の `intervalDidEnd` で再ロック（正攻法）
///   2枚目: アプリが前面に戻るたびに期限を検算して即再ロック
///   3枚目: ロック画面のボタンが押されたときにも検算
///
/// さらに「完全にロックできる」とは謳わない。日時変更や権限オフで抜けられるのは事実で、
/// 誇大表現をしないこと自体が信頼になる。
enum LockManager {

    private static let store = ManagedSettingsStore(named: .init("yomitame"))

    // MARK: - 権限

    static var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    static func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }

    // MARK: - かける／外す

    /// 選んだアプリをロックする
    static func lock() {
        let selection = LockStore.selection
        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty else {
            clear(); return
        }
        store.shield.applications = selection.applicationTokens.isEmpty
            ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        store.shield.webDomainCategories = selection.categoryTokens.isEmpty
            ? nil : .specific(selection.categoryTokens)
        LockStore.unlockUntil = nil
    }

    /// コインと引き換えに `minutes` 分だけ解放する
    static func unlock(minutes: Int) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        LockStore.unlockUntil = until
        clear()
        scheduleRelock(at: until)
    }

    /// シールドを外すだけ（状態は触らない）
    private static func clear() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
    }

    // MARK: - 多重防御

    /// 1枚目：期限で拡張を起こしてもらう予約
    private static func scheduleRelock(at date: Date) {
        let center = DeviceActivityCenter()
        center.stopMonitoring([LockStore.activityName])

        let cal = Calendar.current
        let start = cal.dateComponents([.hour, .minute, .second], from: Date())
        let end = cal.dateComponents([.hour, .minute, .second], from: date)
        let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
        try? center.startMonitoring(LockStore.activityName, during: schedule)
    }

    /// 2枚目・3枚目：期限が過ぎていたら即座に再ロックする。
    /// アプリが前面に戻ったとき、ロック画面のボタンが押されたとき、拡張が起きたときに呼ぶ。
    @discardableResult
    static func reconcile() -> Bool {
        guard LockStore.enabled else { clear(); return false }
        if LockStore.isUnlocked { return false }
        lock()
        DeviceActivityCenter().stopMonitoring([LockStore.activityName])
        return true
    }
}
