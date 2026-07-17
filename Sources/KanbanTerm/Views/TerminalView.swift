import SwiftUI
import SwiftTerm

/// カード単位のターミナルセッションを保持する。閉じても(非表示にしても)プロセスは生かしたまま。
/// → 仕様「Terminal を閉じても Agent は動く」に合致し、周囲クリックで誤って閉じてもセッションは残る。
@MainActor
@Observable
final class TerminalSessions {
    private var views: [UUID: LocalProcessTerminalView] = [:]

    /// カードのターミナルview。初回だけシェルを起動し、以後は同じインスタンスを再利用する。
    func view(for cardID: UUID, directory: String?) -> LocalProcessTerminalView {
        if let existing = views[cardID] { return existing }
        let term = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(
            executable: shell,
            args: ["-l"],
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
    let sessions: TerminalSessions

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        sessions.view(for: cardID, directory: directory)
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
