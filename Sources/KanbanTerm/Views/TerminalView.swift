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
        var lines: [String] = []
        for r in max(0, rows - 20)..<rows {
            if let line = t.getLine(row: r) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        let lower = lines.joined(separator: "\n").lowercased()
        let state: AgentState
        var question: String? = nil
        if lower.contains("esc to interrupt") {
            state = .working                                     // Claude 実行中フッタ
        } else if lower.contains("do you want")
                    || lower.contains("esc to cancel")
                    || lower.contains("enter to select") {
            state = .blocked                                     // 承認/選択プロンプト
            question = Self.extractQuestion(from: lines)         // 実際の問いをカードに出す(design C)
        } else {
            state = .idle
        }
        apply(state, question: question)
    }

    /// 承認ボックスの問い(例: "Do you want to make this edit?")を1行取り出す。罫線・記号は除去。
    private static func extractQuestion(from lines: [String]) -> String? {
        let frame = CharacterSet(charactersIn: " │╭╮╰╯─┃┏┓┗┛┌┐└┘|>❯•*")
        for line in lines {
            let cleaned = line.trimmingCharacters(in: frame).trimmingCharacters(in: .whitespaces)
            if cleaned.lowercased().contains("do you want") {
                return String(cleaned.prefix(80))
            }
        }
        return nil
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

    private func apply(_ state: AgentState, question: String? = nil) {
        guard let card = BoardStore(context: context).card(withID: cardID) else { return }
        var changed = false
        if isViewing() {
            if !card.seen { card.seen = true; changed = true }
        } else if state == .idle && lastState == .working {
            if card.seen { card.seen = false; changed = true }   // 別画面にいる間に完了 → Done(未読)
        }
        if card.agentState != state { card.agentState = state; changed = true }
        // Blocked の実際の問いを保存 / 解除。抽出できなければ直前の問いを保持する。
        if state == .blocked {
            if let q = question, card.blockedPrompt != q { card.blockedPrompt = q; changed = true }
        } else if card.blockedPrompt != nil {
            card.blockedPrompt = nil; changed = true
        }
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
    var onReady: (() -> Void)?   // シェルの初回出力(プロンプト)が落ち着いたら1回だけ呼ぶ
    private var scanTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var readyFired = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.onScan?()
        }
        // 初回プロンプトが描画され落ち着いたタイミングを検知して onReady を1回だけ発火。
        // (Agent 自動起動を固定ディレイでなくプロンプト準備完了に合わせるため)
        if !readyFired {
            readyTask?.cancel()
            readyTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, !self.readyFired else { return }
                self.readyFired = true
                self.onReady?()
            }
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
              resumeSessionID: String? = nil,
              context: ModelContext,
              uiState: BoardUIState) -> LocalProcessTerminalView {
        if let existing = views[cardID] { return existing }
        let term = MonitoredTerminalView(frame: .zero)
        term.font = TerminalSettings.resolvedFont()   // 設定フォントを適用
        Self.applyTheme(TerminalSettings.resolvedTheme(), to: term)

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
            // インタラクティブシェルへ「入力」として送るため、session id は必ず検証する。
            // (id は ~/.claude/projects 配下のファイル名由来。細工されたファイル名による
            //  コマンドインジェクションを防ぐため、UUID 相当の文字種のみ許可)
            var cmd = "claude"
            if let sid = resumeSessionID,
               sid.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
                cmd += " --resume \(sid)"
            }
            if dangerSkip { cmd += " --dangerously-skip-permissions" }
            let bytes = ArraySlice(Array((cmd + "\n").utf8))
            // 固定ディレイではなく、シェルのプロンプトが準備できてから送る(取りこぼし防止)。
            term.onReady = { [weak term] in term?.send(source: term!, data: bytes) }
        }
        views[cardID] = term
        uiState.resumeRequests[cardID] = nil   // 復帰要求は一度きり(再オープンで再復帰しない)
        return term
    }

    /// 設定フォントを開いている全ターミナルへ即時反映する。
    func applyFont() {
        let font = TerminalSettings.resolvedFont()
        for term in views.values { term.font = font }
    }

    /// 配色テーマを開いている全ターミナルへ即時反映する。
    func applyTheme() {
        let theme = TerminalSettings.resolvedTheme()
        for term in views.values { Self.applyTheme(theme, to: term) }
    }

    private static func applyTheme(_ theme: TermTheme, to term: LocalProcessTerminalView) {
        term.nativeBackgroundColor = NSColor(hex: theme.bg)
        term.nativeForegroundColor = NSColor(hex: theme.fg)
        term.caretColor = NSColor(hex: theme.caret)
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
    var resumeSessionID: String? = nil
    let sessions: TerminalSessions
    let context: ModelContext
    let uiState: BoardUIState

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        sessions.view(
            for: cardID, directory: directory,
            startAgent: startAgent, dangerSkip: dangerSkip,
            resumeSessionID: resumeSessionID,
            context: self.context, uiState: uiState
        )
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
