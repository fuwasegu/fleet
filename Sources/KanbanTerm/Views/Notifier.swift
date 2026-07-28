import AppKit
import Foundation
import Observation
import UserNotifications
import KanbanKit

/// 通知タップで開きたいカードを SwiftUI 側へ渡す橋渡し。
/// `UNUserNotificationCenterDelegate` はビュー階層の外にいるため、ここを経由して
/// `BoardView` が `uiState.terminalCardID` に流す。
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    /// 通知がタップされたカード。BoardView が消費して nil に戻す。
    var pendingCardID: UUID?
    private init() {}
}

/// DONE / BLOCKED のシステム通知の配信層。
/// 「通知すべきか」の判定は持たない(`KanbanKit.AgentNotification.decide`)。
/// ここが持つのは「設定でオンか」「どう見せるか」「タップされたら何をするか」だけ。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let notifyOnDoneKey = "notifyOnDone"
    static let notifyOnBlockedKey = "notifyOnBlocked"
    private nonisolated static let cardIDKey = "cardID"

    private override init() { super.init() }

    /// 通知センター。バンドル外(テスト・ツール実行)では `UNUserNotificationCenter.current()` が
    /// 例外を投げるため、bundleIdentifier が無い場合は通知機能ごと無効にする。
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// 起動時に一度だけ呼ぶ。delegate を差してから権限を要求する
    /// (先に delegate を差さないと、通知タップでの起動を取りこぼす)。
    func start() {
        guard let center = Self.center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// OS 側で Fleet の通知が拒否されているか(設定画面のヒント表示用)。
    static func isDenied() async -> Bool {
        guard let center = center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .denied
    }

    /// 設定でその種別の通知が有効か。既定はどちらもオン。
    static func isEnabled(_ kind: AgentNotification.Kind) -> Bool {
        let key = kind == .done ? notifyOnDoneKey : notifyOnBlockedKey
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// カード名付きで通知を出す。
    /// - Parameter question: Blocked のときエージェントが出している実際の問い。
    func post(_ kind: AgentNotification.Kind, cardID: UUID, cardTitle: String, question: String?) {
        guard Self.isEnabled(kind), let center = Self.center else { return }

        let content = UNMutableNotificationContent()
        content.title = cardTitle                     // 依頼の主眼: どのカードの話かを必ず出す
        content.sound = .default
        content.threadIdentifier = cardID.uuidString  // 通知センターでカード単位にまとまる
        content.userInfo = [Self.cardIDKey: cardID.uuidString]
        switch kind {
        case .done:
            content.subtitle = String(localized: "完了")
        case .blocked:
            content.subtitle = String(localized: "承認待ち")
            if let question, !question.isEmpty { content.body = question }
        }

        // 同一カード・同一種別は上書きする(未読が積み上がらない)。
        let request = UNNotificationRequest(identifier: Self.identifier(cardID, kind),
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }

    /// そのカードを開いた = 用が済んだので、残っている通知を取り下げる。
    func clear(cardID: UUID) {
        guard let center = Self.center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [
            Self.identifier(cardID, .done),
            Self.identifier(cardID, .blocked),
        ])
    }

    private static func identifier(_ cardID: UUID, _ kind: AgentNotification.Kind) -> String {
        "card-\(cardID.uuidString)-\(kind.rawValue)"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Fleet が前面にいても banner を出す(既定では抑制される)。
    /// そのカードのターミナルを開いている場合はそもそも `decide` が nil を返すので届かない。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// タップ: Fleet を前面に出し、そのカードのターミナルを開く。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo[Self.cardIDKey] as? String
        Task { @MainActor in
            guard let raw, let id = UUID(uuidString: raw) else { return }
            NSApp.activate(ignoringOtherApps: true)
            NotificationRouter.shared.pendingCardID = id
        }
        completionHandler()
    }
}
