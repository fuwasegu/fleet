import Testing
@testable import KanbanKit

struct AgentDetectionTests {
    private func c(_ title: String, _ lines: [String]) -> AgentState? {
        AgentDetection.classify(kind: .claude, title: title, lines: lines)
    }
    private func cx(_ title: String, _ lines: [String]) -> AgentState? {
        AgentDetection.classify(kind: .codex, title: title, lines: lines)
    }

    // MARK: Claude

    @Test func claudeWorkingFromSpinnerTitle() {
        #expect(c("\u{2807} Forging…", []) == .working)
    }

    @Test func claudeBashPermissionIsBlockedEvenWithSpinnerTitle() {
        // タイトルにスピナーが残っていても、権限プロンプトが見えたら Blocked が勝つ(実バグの回帰)
        let lines = [
            "Bash command",
            "find . -exec ... cannot be auto-allowed by a Bash(find:*) prefix rule",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. No",
        ]
        #expect(c("\u{2807} running", lines) == .blocked)
    }

    @Test func claudeSelectionFormIsBlocked() {
        let lines = ["Select an option", "❯ 1. foo", "  2. bar",
                     "enter to select · esc to cancel · ↑↓ to navigate"]
        #expect(c("", lines) == .blocked)
    }

    @Test func claudeIdleFromStarTitle() { #expect(c("\u{2733} ready", []) == .idle) }

    @Test func claudeIdleFromPromptCaret() {
        // 単なる ❯ ではなく、Claude TUI のヒントフッタ(証拠)が同じ下部ウィンドウにある場合のみ Idle。
        #expect(c("", ["assistant output", "❯ ", "? for shortcuts"]) == .idle)
    }

    @Test func claudeIdleWithTUIEvidenceIsIdle() {
        // idleFromPromptCaret と同型の、より実際の Claude 画面に近いフィクスチャ。
        let lines = [
            "assistant output",
            "❯ ",
            "? for shortcuts · shift+tab to cycle",
        ]
        #expect(c("", lines) == .idle)
    }

    @Test func claudeIdleWithInputBoxFrameEvidenceIsIdle() {
        // FIX I2: "? for shortcuts" 等のフッタヒントが画面外に流れて見えなくても、
        // Claude の入力欄の枠線(╭─...│...╰─)があれば TUI 証拠として Idle と判定できる
        // (偽陰性の低減)。キャレット行(❯)自体は既存テストと同じく素の行として置く。
        let lines = [
            "assistant output",
            "╭─────────────────────────────╮",
            "│ >                           │",
            "╰─────────────────────────────╯",
            "❯ ",
        ]
        #expect(c("", lines) == .idle)
    }

    @Test func claudeIdleWithFooterHintBeyondOldWindowIsIdle() {
        // 従来の下部6行の窓では ❯ とフッタヒントが同時に入らない配置(キャレットが
        // 7行以上前)でも、証拠ウィンドウを12行に広げたことで拾える(偽陰性の低減)。
        let lines = [
            "❯ ",
            "line a", "line b", "line c", "line d", "line e",
            "line f", "line g", "line h",
            "? for shortcuts",
        ]
        #expect(c("", lines) == .idle)
    }

    @Test func bareShellPromptIsNotIdle() {
        // ❯ は pure/starship/oh-my-zsh 等の素のシェルプロンプトでも極めて一般的な記号。
        // Claude TUI の証拠(ヒントフッタ等)が無ければ、素のシェルを Idle(=A2A hub がメッセージを
        // 投げ込んで良い状態)と誤判定してはならない(実バグの回帰)。
        #expect(c("", ["❯ "]) != .idle)
        #expect(c("", ["❯ git status"]) != .idle)
    }

    @Test func claudeWorkingFromFooter() {
        #expect(c("", ["… (esc to interrupt)"]) == .working)
    }

    @Test func claudeUnknownKeepsState() {
        #expect(c("", ["just some normal output line"]) == nil)
    }

    @Test func claudeTranscriptViewerKeepsState() {
        #expect(c("\u{2733} x", ["showing detailed transcript", "ctrl+o to toggle"]) == nil)
    }

    // MARK: Codex

    @Test func codexBlockedFromActionRequiredTitle() {
        #expect(cx("Action Required", []) == .blocked)
    }
    @Test func codexWorkingFromSpinnerTitle() {
        #expect(cx("\u{2819} thinking", []) == .working)
    }
    @Test func codexWorkingFromFooter() {
        #expect(cx("~/proj", ["• Working (5s · esc to interrupt)"]) == .working)
    }
    @Test func codexBlockedFromConfirm() {
        #expect(cx("~/proj", ["press Enter to confirm or Esc to cancel"]) == .blocked)
    }
    @Test func codexIdleFromPlainTitle() {
        #expect(cx("~/project (main)", ["done"]) == .idle)
    }
}
