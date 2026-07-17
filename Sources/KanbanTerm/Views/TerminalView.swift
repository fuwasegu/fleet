import SwiftUI
import SwiftTerm

/// SwiftTerm の LocalProcessTerminalView(PTY内蔵) を SwiftUI に載せるラッパー。
struct TerminalView: NSViewRepresentable {
    let directory: String?

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: .zero)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: nil,
            currentDirectory: resolvedDirectory()
        )
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    private func resolvedDirectory() -> String {
        if let d = directory {
            let expanded = (d as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return expanded }
        }
        return NSHomeDirectory()
    }
}

/// カードから開くターミナルモーダル。
struct TerminalModal: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let directory: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            TerminalView(directory: directory)
                .frame(minWidth: 720, minHeight: 460)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
