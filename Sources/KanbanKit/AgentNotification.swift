import Foundation

/// 「エージェントの状態が変わった」→「システム通知を出すべきか」の判定。
/// 端末にも UI にも依存しない純ロジック(配信は KanbanTerm 側の Notifier)。
///
/// 呼び出し元は `AgentStateMonitor.apply()` の一箇所のみ。`.done` の条件は
/// `Card.seen` を落とす条件（= `Card.isDone` が真になる瞬間）と同一で、
/// Done の定義がここと `Models.swift` に二重化しないよう apply() 側もこの戻り値を使う。
public enum AgentNotification {
    /// 通知する種別。Working / Idle そのものは通知しない。
    public enum Kind: String, Sendable, Equatable {
        case done      // 完了(未読)
        case blocked   // 承認待ち
    }

    /// - Parameters:
    ///   - previous: 直前に確定していた状態
    ///   - current: 今確定した状態
    ///   - isViewing: そのカードのターミナルを今開いているか(開いていれば通知しない)
    public static func decide(previous: AgentState,
                              current: AgentState,
                              isViewing: Bool) -> Kind? {
        guard !isViewing else { return nil }   // 目の前で見ているものは通知しない
        switch current {
        case .idle:
            // working からの遷移だけが「完了」。unknown → idle は起動直後なので無音。
            return previous == .working ? .done : nil
        case .blocked:
            // 端末出力のたびに再評価されるため、遷移した時だけ鳴らす。
            return previous == .blocked ? nil : .blocked
        case .working, .unknown:
            return nil
        }
    }
}
