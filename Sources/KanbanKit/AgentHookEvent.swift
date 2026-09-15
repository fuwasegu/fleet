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
    /// hook_event_name(+ payload の message)→ 状態。確認済みイベント名以外(未知のイベント)は
    /// nil(=無視、状態を書かない)。
    ///
    /// - UserPromptSubmit / PreToolUse / PostToolUse → working(何か実行中)
    /// - Stop → idle(応答が止まった = 待機)
    /// - PermissionRequest → blocked(人間の入力待ち。実測では発火しなかったが、将来の
    ///   バージョンで発火した場合に備えて配線しておく)
    /// - Notification → `message` を見て判定する。`Notification` は Claude Code の汎用通知
    ///   チャンネルで、「権限確認」と「アイドル通知(例: "Claude is waiting for your input"、
    ///   ターン終了のおよそ60秒後に発火)」の両方がここに流れてくる。message に "permission"
    ///   が(大小文字を区別せず)含まれる場合だけ blocked とし、それ以外(アイドル通知含む)は
    ///   nil(無視)にする。ここを Notification 一律 blocked にすると、完了して1分アイドルに
    ///   なっただけのカードが軒並み Blocked に化ける実バグになる(Stop→idle の直後に
    ///   Notification→blocked で Done/Blocking がフラップする)。idle にマップしないのは
    ///   意図的: 曖昧な通知から状態を作り出すより、Stop が既に置いた idle をそのまま残す方が
    ///   安全なため。
    /// - SessionEnd → unknown(セッションが終わった。以後の状態は判定不能)
    public static func state(forEventName name: String, message: String?) -> AgentState? {
        switch name {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Stop":
            return .idle
        case "PermissionRequest":
            return .blocked
        case "Notification":
            guard let message, message.localizedCaseInsensitiveContains("permission") else { return nil }
            return .blocked
        case "SessionEnd":
            return .unknown
        default:
            return nil
        }
    }
}
