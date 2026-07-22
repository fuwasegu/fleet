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
        #expect(c("", ["assistant output", "❯ "]) == .idle)
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
