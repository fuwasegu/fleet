import Testing
import Foundation
@testable import KanbanKit

/// A2A outbox のメッセージを受信側カードの live ターミナルへ注入する前に必ず通す
/// `ChannelStore.sanitizeForTerminal` のテスト。ESC/OSC などの制御文字がそのまま
/// `term.send` へ流れると、受信側のターミナルを乗っ取れてしまう(SECURITY finding B)。
struct TerminalSanitizeTests {

    @Test func normalTextPassesThroughUnchanged() {
        let s = "hello world, this is a normal message. 123-456!"
        #expect(ChannelStore.sanitizeForTerminal(s) == s)
    }

    @Test func escapeSequenceBecomesSpace() {
        let s = "before\u{1B}[31mafter"
        let out = ChannelStore.sanitizeForTerminal(s)
        #expect(!out.contains("\u{1B}"))
        #expect(out == "before [31mafter")
    }

    @Test func newlinesTabsAndCarriageReturnsBecomeSpaces() {
        let s = "line1\nline2\rline3\tline4"
        let out = ChannelStore.sanitizeForTerminal(s)
        #expect(!out.contains("\n"))
        #expect(!out.contains("\r"))
        #expect(!out.contains("\t"))
        #expect(out == "line1 line2 line3 line4")
    }

    @Test func delAndC1ControlsAreRemoved() {
        // DEL (0x7F) と C1 コントロール(0x80-0x9F, 例: 0x9B = CSI)
        let s = "a\u{7F}b\u{9B}c\u{85}d"
        let out = ChannelStore.sanitizeForTerminal(s)
        #expect(!out.contains("\u{7F}"))
        #expect(!out.contains("\u{9B}"))
        #expect(!out.contains("\u{85}"))
        #expect(out == "a b c d")
    }

    @Test func runsOfWhitespaceAreCollapsedAndTrimmed() {
        let s = "  hello    world  "
        #expect(ChannelStore.sanitizeForTerminal(s) == "hello world")
    }

    @Test func controlCharacterRunsCollapseWithSurroundingWhitespace() {
        let s = "a\u{1B}\u{1B}\u{1B}b"
        #expect(ChannelStore.sanitizeForTerminal(s) == "a b")
    }

    @Test func overLongInputIsTruncatedWithEllipsis() {
        let s = String(repeating: "x", count: 50)
        let out = ChannelStore.sanitizeForTerminal(s, maxLength: 10)
        #expect(out == String(repeating: "x", count: 10) + "…")
    }

    @Test func inputAtOrUnderMaxLengthIsNotTruncated() {
        let s = String(repeating: "x", count: 10)
        let out = ChannelStore.sanitizeForTerminal(s, maxLength: 10)
        #expect(out == s)
    }

    @Test func defaultMaxLengthIsTwoThousand() {
        let s = String(repeating: "x", count: 3000)
        let out = ChannelStore.sanitizeForTerminal(s)
        #expect(out.count == 2001) // 2000 + "…"
        #expect(out.hasSuffix("…"))
    }
}
