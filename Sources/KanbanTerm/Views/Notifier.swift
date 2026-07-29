import AppKit
import Foundation
import KanbanKit

/// DONE / BLOCKED を「盤面を見ていないユーザー」に知らせる。
///
/// 当初は `UNUserNotificationCenter`(システム通知)で実装したが、**Gatekeeper に
/// rejected される署名のアプリでは原理的に使えない**ことが分かって差し替えた。
/// 自己署名 / Apple Development 署名のアプリでは `requestAuthorization` が
/// 許可ダイアログを出さないまま `denied` になり、通知設定にも登録されない
/// (実測: Notarized Developer ID のアプリだけが登録・配信される)。Fleet は自己署名配布
/// なので、通知センターを使うには Apple Developer Program での notarization が必要。
///
/// そこで**署名の質に依存しない** Dock で知らせる。Dock にはカード名を出せないので、
/// 「どのカードか」は盤面上部の「要対応」リスト(カード名が並ぶ)が担う。
@MainActor
final class Notifier {
    static let shared = Notifier()

    static let notifyOnDoneKey = "notifyOnDone"
    static let notifyOnBlockedKey = "notifyOnBlocked"

    private init() {}

    /// 設定でその種別の通知が有効か。既定はどちらもオン。
    static func isEnabled(_ kind: AgentNotification.Kind) -> Bool {
        let key = kind == .done ? notifyOnDoneKey : notifyOnBlockedKey
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// 手番が来たことを知らせる。Fleet が前面にいる場合 Dock は反応しない(=見えているので不要)。
    func signal(_ kind: AgentNotification.Kind) {
        guard Self.isEnabled(kind) else { return }
        switch kind {
        case .blocked:
            NSSound(named: "Funk")?.play()
            // 応答が要るので、戻ってくるまで跳ね続ける。
            NSApp.requestUserAttention(.criticalRequest)
        case .done:
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)   // 一度だけ跳ねる
        }
    }

    /// Dock バッジに要対応の件数を出す。0 件になったら消す。
    func updateBadge(attentionCount: Int) {
        NSApp.dockTile.badgeLabel = AgentNotification.badgeLabel(attentionCount: attentionCount)
    }
}
