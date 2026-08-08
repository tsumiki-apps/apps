import ManagedSettings

/// ロック画面のボタンが押されたときの処理。
/// ここでも期限を検算する（多重防御の3枚目）。
final class ShieldActionExtension: ShieldActionDelegate {

    private func handle(_ action: ShieldAction,
                        completionHandler: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            // 「本を読む」。よみためを開かせたいが、拡張から他アプリは起動できないので
            // 画面を閉じるだけにする（ここで無理をすると Apple の審査にも引っかかる）。
            LockManager.reconcile()
            completionHandler(.close)
        case .secondaryButtonPressed:
            completionHandler(.close)
        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler: completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler: completionHandler)
    }
}
