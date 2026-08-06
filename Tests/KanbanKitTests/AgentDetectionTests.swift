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

    @Test func claudeTrustFolderPromptIsBlocked() {
        // claude 2.1.220 の実画面(新しい作業ディレクトリでの初回起動)。
        // 裏起動したカードは必ずここで止まるので、Unknown ではなく Blocked にしないと
        // 「人間を待っている」ことが盤面に出ない(実バグの回帰)。
        let lines = [
            "Accessing workspace:",
            "/Users/me/fresh-dir",
            "Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source",
            "project, or work from your team). If not, take a moment to review what's in this folder first.",
            "Claude Code'll be able to read, edit, and execute files here.",
            "Security guide",
            "❯ 1. Yes, I trust this folder",
            "  2. No, exit",
            "Enter to confirm · Esc to cancel",
        ]
        #expect(c("", lines) == .blocked)
    }

    @Test func claudeTrustFolderIsBlockedEvenIfTheQuestionWraps() {
        // 幅が狭いと問いの文が折り返して contains が切れる。メニュー行だけでも拾えること。
        let lines = ["Quick safety check: Is this a project you created or",
                     "one you trust?",
                     "❯ 1. Yes, I trust this folder",
                     "  2. No, exit"]
        #expect(c("", lines) == .blocked)
    }

    @Test func claudeTrustFolderIsBlockedEvenWhenItIsAboveTheBottomWindow() {
        // 実測(dev ビルド計測): 起動直後は画面がスクロールしていないため、40 行の端末で
        // ダイアログは上部に描かれ、下部 24 行にはほぼ何も無い(全画面非空=15 / 窓内非空=4)。
        // 下部窓しか見ていないと Unknown のままになり、盤面が「人間待ち」を示せなかった。
        let screen = ["❯ claude --session-id ...",
                      "────────────────────────────",
                      "Accessing workspace:",
                      "/private/tmp/fresh-dir",
                      "Quick safety check: Is this a project you created or one you trust? (Like",
                      "❯ 1. Yes, I trust this folder",
                      "  2. No, exit",
                      "Enter to confirm · Esc to cancel"]
        let bottomWindow = ["", "", "", ""]   // 下部窓は空
        #expect(AgentDetection.classify(kind: .claude, title: "", lines: bottomWindow, screen: screen) == .blocked)
        // screen を渡さない旧来の呼び出しでは lines がそのまま画面扱い(後方互換)
        #expect(AgentDetection.classify(kind: .claude, title: "", lines: bottomWindow) == nil)
    }

    @Test func claudeTrustFolderIsBlockedWhenGapsAreControlCharsNotSpaces() {
        // 実測: SwiftTerm のバッファは書き込まれていないセルを NUL で返すため、語間が空白では
        // なく制御文字になる。素の contains は当たらず Unknown のままだった(実バグの回帰)。
        let nul = "\u{0}"
        let screen = ["Quick\(nul)safety\(nul)check:\(nul)Is\(nul)this\(nul)a\(nul)project\(nul)you\(nul)created\(nul)or\(nul)one\(nul)you\(nul)trust?",
                      "❯\(nul)1.\(nul)Yes,\(nul)I\(nul)trust\(nul)this\(nul)folder"]
        #expect(AgentDetection.classify(kind: .claude, title: "", lines: [], screen: screen) == .blocked)
    }

    @Test func normalizeCollapsesControlCharRunsIntoSingleSpaces() {
        #expect(AgentDetection.normalize("Accessing\u{0}workspace:") == "Accessing workspace:")
        #expect(AgentDetection.normalize("a\u{0}\u{0}\u{0}b") == "a b")
        #expect(AgentDetection.normalize("  padded \u{0} ") == "padded")
        #expect(AgentDetection.normalize("\u{0}\u{0}\u{0}").isEmpty)   // 空行として扱えること
    }

    @Test func claudeConfirmSelectionFormIsBlocked() {
        // 「enter to confirm」系のダイアログ(select だけでなく confirm も待ち)
        let lines = ["Choose one", "❯ 1. foo", "  2. bar", "Enter to confirm · Esc to cancel"]
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

    @Test func powerlevel10kPromptIsNotIdle() {
        // p10k のデフォルト2行プロンプトは Claude の入力欄と同じ box-drawing 文字
        // (╭ ╰ ─ ❯)を使うが、Claude 専用の証拠(長い横罫線や "│ > " マーカー、
        // ヒントフッタ)が無いので Idle と誤判定してはならない(実バグの再発防止)。
        let lines = [
            "╭─ ~/Projects/foo  main",
            "╰─❯ ",
        ]
        #expect(c("", lines) != .idle)
    }

    @Test func starshipTwoLinePromptIsNotIdle() {
        // starship のデフォルト2行プロンプトも同様(┌─/└─❯ 変種と ╭─/╰─❯ 変種の両方)。
        let square = [
            "┌─ ~/Projects/foo on  main",
            "└─❯ ",
        ]
        #expect(c("", square) != .idle)

        let rounded = [
            "╭─ ~/Projects/foo on  main",
            "╰─❯ ",
        ]
        #expect(c("", rounded) != .idle)
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
