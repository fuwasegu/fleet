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
    weak var term: LocalProcessTerminalView?   // Blocked判定のバッファ走査用

    init(cardID: UUID, context: ModelContext, isViewing: @escaping () -> Bool) {
        self.cardID = cardID
        self.context = context
        self.isViewing = isViewing
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // スピナーは即 Working のヒント。Idle/Blocked の確定はデータ受信時の rescan() に任せる。
        let hasSpinner = title.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
        if hasSpinner { apply(.working) }
    }

    /// バッファ末尾のフッタ文言から状態を判定する(出力が落ち着いた頃に呼ばれる)。
    func rescan() {
        guard let t = term?.getTerminal() else { return }
        let rows = t.rows
        var text = ""
        for r in max(0, rows - 20)..<rows {
            if let line = t.getLine(row: r) {
                text += line.translateToString(trimRight: true) + "\n"
            }
        }
        let lower = text.lowercased()
        let state: AgentState
        if lower.contains("esc to interrupt") {
            state = .working                                     // Claude 実行中フッタ
        } else if lower.contains("do you want")
                    || lower.contains("esc to cancel")
                    || lower.contains("enter to select") {
            state = .blocked                                     // 承認/選択プロンプト
        } else {
            state = .idle
        }
        apply(state)
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

/// dataReceived をフックし、出力が落ち着いた頃(250ms デバウンス)にバッファ走査(状態判定)を行う端末view。
final class MonitoredTerminalView: LocalProcessTerminalView {
    var onScan: (() -> Void)?
    private var scanTask: Task<Void, Never>?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.onScan?()
        }
    }
}

/// カード単位のターミナルセッションを保持する。閉じても(非表示にしても)プロセスは生かしたまま。
@MainActor
@Observable
final class TerminalSessions {
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var monitors: [UUID: AgentStateMonitor] = [:]   // processDelegate は weak なので保持する

    func view(for cardID: UUID,
              directory: String?,
              startAgent: Bool,
              dangerSkip: Bool,
              resume: Bool = false,
              context: ModelContext,
              uiState: BoardUIState) -> LocalProcessTerminalView {
        if let existing = views[cardID] { return existing }
        let term = MonitoredTerminalView(frame: .zero)

        let monitor = AgentStateMonitor(
            cardID: cardID,
            context: context,
            isViewing: { [weak uiState] in uiState?.terminalCardID == cardID }
        )
        term.processDelegate = monitor
        monitor.term = term
        term.onScan = { [weak monitor] in monitor?.rescan() }
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
            let flags = (resume ? " --continue" : "") + (dangerSkip ? " --dangerously-skip-permissions" : "")
            let bytes = ArraySlice(Array("claude\(flags)\n".utf8))
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

    // MARK: - cwd の追従 (OSC7 は既定で来ないので、閉じる時にシェルの cwd をネイティブ取得)

    /// ターミナルを閉じる時に呼ぶ。カードの表示パスを現在のシェル cwd に更新する。
    func refreshCwd(for cardID: UUID, context: ModelContext) {
        guard let term = views[cardID] else { return }
        let pid = term.process.shellPid
        guard pid > 0, let cwd = Self.cwd(ofPID: pid) else { return }
        if let card = BoardStore(context: context).card(withID: cardID), card.workingDirPath != cwd {
            card.workingDirPath = cwd
            try? context.save()
        }
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
