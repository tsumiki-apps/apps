import ManagedSettings
import ManagedSettingsUI
import UIKit

/// ロック画面の見た目。
/// 出せるのはアイコン・見出し・本文・ボタン2つのラベルと色だけで、配置と大きさは Apple 固定。
/// 説教をせず「何をすれば開くか」を1文で言い切る。
final class ShieldConfigExtension: ShieldConfigurationDataSource {

    private var config: ShieldConfiguration {
        let remaining = LockStore.remainingUnlockSeconds
        let subtitle = remaining > 0
            ? "あと\(remaining / 60)分で自動的にロックに戻ります。"
            : "本を読むとコインが貯まり、その分だけ開けられます。"

        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: UIColor(white: 0.11, alpha: 1),
            icon: UIImage(named: "ShieldIcon"),
            title: .init(text: "いまはロック中です", color: .white),
            subtitle: .init(text: subtitle, color: UIColor(white: 0.62, alpha: 1)),
            primaryButtonLabel: .init(text: "本を読む", color: .black),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: .init(text: "閉じる", color: UIColor(white: 0.62, alpha: 1)))
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration { config }
    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration { config }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { config }
    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration { config }
}
