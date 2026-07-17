import SwiftUI
import Foundation
import Darwin
import SwiftData
@preconcurrency import SwiftTerm
import KanbanKit

/// 端末の状態を監視して Card.agentState / cwd を更新する (herdr方式の一部)。
/// - Working: 端末タイトル(OSC 0/2)の先頭付近にスピナー(点字 U+2800–U+28FF)
/// - Idle: スピナーが消えた / プロセス終了
/// - cwd: OSC 7 (hostCurrentDirectoryUpdate)
/// Blocked(承認プロンプト)の検知はバッファ走査が必要なため v2 で対応。
/// delegate コールバックはメインスレッドで来るため @MainActor。
@MainActor
final class AgentStateMonitor: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let cardID: UUID
    private let context: ModelContext
    private let isViewing: () -> Bool
    private var lastState: AgentState = .unknown

    init(cardID: UUID, context: ModelContext, isViewing: @escaping () -> Bool) {
        self.cardID = cardID
        self.context = context
        self.isViewing = isViewing
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let hasSpinner = title.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
        apply(hasSpinner ? .working : .idle)
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        guard let directory, let path = Self.path(fromOSC7: directory) else { return }
        guard let card = BoardStore(context: context).card(withID: cardID) else { return }
        if card.workingDirPath != path {
            card.workingDirPath = path
            try? context.save()
        }
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        apply(.idle)
    }

    private func apply(_ state: AgentState) {
        guard let card = BoardStore(context: context).card(withID: cardID) else { return }
        var changed = false
        if isViewing() {
            if !card.seen { card.seen = true; changed = true }
        } else if state == .idle && lastState == .working {
            if card.seen { card.seen = false; changed = true }   // 別画面にいる間に完了 → Done(未読)
        }
        if card.agentState != state { card.agentState = state; changed = true }
        lastState = state
        if changed { try? context.save() }
    }

    private static func path(fromOSC7 s: String) -> String? {
        if s.hasPrefix("file://"), let url = URL(string: s) { return url.path }
        return s.hasPrefix("/") ? s : nil
    }
}

/// カード単位のターミナルセッションを保持する。閉じても(非表示にしても)プロセスは生かしたまま。
@MainActor
@Observable
final class TerminalSessions {
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var monitors: [UUID: AgentStateMonitor] = [:]   // processDelegate は weak なので保持する
    private var context: ModelContext?
    private var cwdPollTask: Task<Void, Never>?

    func view(for cardID: UUID,
              directory: String?,
              startAgent: Bool,
              dangerSkip: Bool,
              context: ModelContext,
              uiState: BoardUIState) -> LocalProcessTerminalView {
        self.context = context
        startCwdPollingIfNeeded()
        if let existing = views[cardID] { return existing }
        let term = LocalProcessTerminalView(frame: .zero)

        let monitor = AgentStateMonitor(
            cardID: cardID,
            context: context,
            isViewing: { [weak uiState] in uiState?.terminalCardID == cardID }
        )
        term.processDelegate = monitor
        monitors[cardID] = monitor

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        term.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: nil,
            currentDirectory: Self.resolve(directory)
        )
        if startAgent {
            let danger = dangerSkip ? " --dangerously-skip-permissions" : ""
            let bytes = ArraySlice(Array("claude\(danger)\n".utf8))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                term.send(source: term, data: bytes)
            }
        }
        views[cardID] = term
        return term
    }

    /// カード削除時などにセッションを終了する(SIGTERM)。
    func close(_ cardID: UUID) {
        views[cardID]?.terminate()
        views[cardID] = nil
        monitors[cardID] = nil
    }

    // MARK: - cwd の追従 (OSC7 は既定で来ないので、シェルの cwd をネイティブに定期取得)

    private func startCwdPollingIfNeeded() {
        guard cwdPollTask == nil else { return }
        cwdPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pollCwds()
            }
        }
    }

    private func pollCwds() {
        guard let context else { return }
        let store = BoardStore(context: context)
        var changed = false
        for (cardID, term) in views {
            let pid = term.process.shellPid
            guard pid > 0, let cwd = Self.cwd(ofPID: pid) else { continue }
            if let card = store.card(withID: cardID), card.workingDirPath != cwd {
                card.workingDirPath = cwd
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// プロセスのカレントディレクトリをネイティブに取得。
    nonisolated static func cwd(ofPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard result > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
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
    let context: ModelContext
    let uiState: BoardUIState

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        sessions.view(
            for: cardID, directory: directory,
            startAgent: startAgent, dangerSkip: dangerSkip,
            context: self.context, uiState: uiState
        )
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
