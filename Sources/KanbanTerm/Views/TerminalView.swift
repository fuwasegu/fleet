import SwiftUI
import SwiftTerm

/// カード単位のターミナルセッションを保持する。閉じても(非表示にしても)プロセスは生かしたまま。
/// → 仕様「Terminal を閉じても Agent は動く」に合致し、周囲クリックで誤って閉じてもセッションは残る。
@MainActor
@Observable
final class TerminalSessions {
    private var views: [UUID: LocalProcessTerminalView] = [:]

    /// カードのターミナルview。初回だけシェルを起動し、以後は同じインスタンスを再利用する。
    /// startAgent が true の初回起動時は、cwd で Claude を自動起動する。
    func view(for cardID: UUID, directory: String?, startAgent: Bool, dangerSkip: Bool) -> LocalProcessTerminalView {
        if let existing = views[cardID] { return existing }
        let term = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let args: [String]
        if startAgent {
            let danger = dangerSkip ? " --dangerously-skip-permissions" : ""
            // Claude 実行後もシェルに戻す
            args = ["-l", "-c", "claude\(danger); exec \(shell) -l"]
        } else {
            args = ["-l"]
        }
        term.startProcess(
            executable: shell,
            args: args,
            environment: env,
            execName: nil,
            currentDirectory: Self.resolve(directory)
        )
        views[cardID] = term
        return term
    }

    private static func resolve(_ directory: String?) -> String {
        if let d = directory {
            let expanded = (d as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return expanded }
        }
        return NSHomeDirectory()
    }
}

/// SwiftTerm の LocalProcessTerminalView を SwiftUI に載せるラッパー（セッションは TerminalSessions が保持）。
struct TerminalView: NSViewRepresentable {
    let cardID: UUID
    let directory: String?
    let startAgent: Bool
    let dangerSkip: Bool
    let sessions: TerminalSessions

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        sessions.view(for: cardID, directory: directory, startAgent: startAgent, dangerSkip: dangerSkip)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
