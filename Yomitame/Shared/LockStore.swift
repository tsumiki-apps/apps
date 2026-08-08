import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// アプリ本体と3つの拡張が共有する保存箱（App Group）。
///
/// 拡張はアプリの SwiftData には触れないので、ロックに必要な最小限だけをここに置く。
/// 「いつまで解放しているか」を**絶対時刻**で持つのが要。
/// 拡張が起こされなかった場合でも、次にアプリが前面に出たときに検算して再ロックできる。
enum LockStore {
    static let appGroup = "group.com.tsumiki.yomitame"
    static let activityName = DeviceActivityName("yomitame.unlock")

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    private enum Key {
        static let selection = "lock.selection"
        static let unlockUntil = "lock.unlockUntil"
        static let enabled = "lock.enabled"
    }

    /// ロック対象。トークンは OS が再発行することがあるので永続キーとして扱わない。
    static var selection: FamilyActivitySelection {
        get {
            guard let data = defaults.data(forKey: Key.selection),
                  let s = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            else { return FamilyActivitySelection() }
            return s
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.selection)
        }
    }

    /// 解放の期限。nil ならロック中。
    static var unlockUntil: Date? {
        get { defaults.object(forKey: Key.unlockUntil) as? Date }
        set { defaults.set(newValue, forKey: Key.unlockUntil) }
    }

    /// ロック機能そのものを使うかどうか
    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// いま解放中か（期限切れは自動的に false）
    static var isUnlocked: Bool {
        guard let until = unlockUntil else { return false }
        return until > Date()
    }

    static var remainingUnlockSeconds: Int {
        guard let until = unlockUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow))
    }
}

/// 選ぶのが面倒で「すべてのアプリ」を選んでしまう事故を防ぐための下ごしらえ。
///
/// ReadTime は無警告で全カテゴリを選ばせ、Notion や Safari まで巻き添えにしていた。
/// 仕事や連絡の道具は最初から候補に入れない。
enum LockPreset: String, CaseIterable, Identifiable {
    case sns, video, game, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sns: return "SNS"
        case .video: return "動画"
        case .game: return "ゲーム"
        case .custom: return "自分で選ぶ"
        }
    }

    var detail: String {
        switch self {
        case .sns: return "X・Instagram・TikTok など"
        case .video: return "YouTube・Netflix など"
        case .game: return "ゲーム全般"
        case .custom: return "アプリを個別に指定します"
        }
    }

    var symbol: String {
        switch self {
        case .sns: return "bubble.left.and.bubble.right"
        case .video: return "play.rectangle"
        case .game: return "gamecontroller"
        case .custom: return "slider.horizontal.3"
        }
    }
}
