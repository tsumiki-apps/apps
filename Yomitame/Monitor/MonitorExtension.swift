import DeviceActivity

/// 解放時間が終わったら再ロックする拡張。
/// ここが発火しない事例が Apple に多数報告されているため、これだけに頼らない
/// （アプリ復帰時とロック画面のボタン押下時にも LockManager.reconcile() で検算する）。
final class MonitorExtension: DeviceActivityMonitor {

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity == LockStore.activityName else { return }
        LockStore.unlockUntil = nil
        LockManager.reconcile()
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // 解放の開始側では何もしない（解放そのものはアプリ側で済んでいる）
    }
}
