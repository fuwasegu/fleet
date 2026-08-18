import Foundation

/// Claude Code の hooks イベント名 → Agent 状態のマッピング。
///
/// OSC タイトル/画面文字列のスクレイピング(`AgentDetection`)は CLI の表示変更(スピナーの
/// 絵文字が変わる・フッタ文字列が削除される等)で簡単に崩れる。hooks はセッションの実イベント
/// (プロンプト送信・ツール実行・停止)を直接教えてくれるので、表示に依存しないより確実な
/// 信号として追加する(既存のスクレイピングは削除しない。Blocked だけは trust dialog が
/// hook を発火しないため TUI 側が権威のまま — 詳細は呼び出し側 `AgentStateMonitor` 参照)。
///
/// `fleet-bridge --hook-event` と Fleet 本体の両方から同じ対応表を使うのが理想だが、
/// fleet-bridge は KanbanKit にリンクできない(既存の制約。`WorktreeService`/`AgentLaunch` の
/// 検証ロジックと同様、bridge 側は手動同期した複製を持つ — `Sources/fleet-bridge/main.swift` の
/// 対応する switch を参照。ここを変えたら両方直すこと)。
public enum AgentHookEvent {
    /// hook_event_name → 状態。確認済みイベント名以外(未知のイベント)は nil(=無視、状態を書かない)。
    ///
    /// - UserPromptSubmit / PreToolUse / PostToolUse → working(何か実行中)
    /// - Stop → idle(応答が止まった = 待機)
    /// - Notification / PermissionRequest → blocked(人間の入力待ち。PermissionRequest は
    ///   実測では発火しなかったが、将来のバージョンで発火した場合に備えて配線しておく)
    /// - SessionEnd → unknown(セッションが終わった。以後の状態は判定不能)
    public static func state(forEventName name: String) -> AgentState? {
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Stop":
            return .idle
        case "Notification", "PermissionRequest":
            return .blocked
        case "SessionEnd":
            return .unknown
        default:
            return nil
        }
    }
}
