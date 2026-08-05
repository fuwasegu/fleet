import Testing
@testable import KanbanKit

/// カード単位のモデル指定(Phase 0.5)。
/// 起動コマンドへ差し込む断片は純ロジックなので KanbanKit 側で検証する。
struct AgentLaunchTests {

    // MARK: - モデル名の正規化・検証

    @Test func acceptsValidModelNames() {
        // エイリアスも完全 ID も、Codex 系の別体系も同じ欄で受ける
        #expect(AgentLaunch.normalizedModel("opus") == "opus")
        #expect(AgentLaunch.normalizedModel("sonnet") == "sonnet")
        #expect(AgentLaunch.normalizedModel("claude-opus-5") == "claude-opus-5")
        #expect(AgentLaunch.normalizedModel("claude-haiku-4-5-20251001") == "claude-haiku-4-5-20251001")
        #expect(AgentLaunch.normalizedModel("gpt-5-codex") == "gpt-5-codex")
        #expect(AgentLaunch.normalizedModel("claude-opus-5[1m]") == "claude-opus-5[1m]")
        #expect(AgentLaunch.normalizedModel("us.anthropic.claude-opus-5") == "us.anthropic.claude-opus-5")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(AgentLaunch.normalizedModel("  opus  ") == "opus")
        #expect(AgentLaunch.normalizedModel("\topus\n") == "opus")
    }

    @Test func emptyOrNilMeansUnspecified() {
        #expect(AgentLaunch.normalizedModel(nil) == nil)
        #expect(AgentLaunch.normalizedModel("") == nil)
        #expect(AgentLaunch.normalizedModel("   ") == nil)
    }

    /// モデル名は起動コマンド文字列へ入るので、shellQuote に加えて文字集合でも締める(多層防御)。
    @Test func rejectsShellInjectionAttempts() {
        #expect(AgentLaunch.normalizedModel("opus; rm -rf /") == nil)
        #expect(AgentLaunch.normalizedModel("opus && curl evil.example") == nil)
        #expect(AgentLaunch.normalizedModel("$(whoami)") == nil)
        #expect(AgentLaunch.normalizedModel("`id`") == nil)
        #expect(AgentLaunch.normalizedModel("opus'") == nil)
        #expect(AgentLaunch.normalizedModel("opus\"") == nil)
        #expect(AgentLaunch.normalizedModel("opus|cat") == nil)
        #expect(AgentLaunch.normalizedModel("opus\nsonnet") == nil)
        #expect(AgentLaunch.normalizedModel("../../etc/passwd") == nil)
        #expect(AgentLaunch.normalizedModel("opus sonnet") == nil)   // 空白区切りで2引数になるのを防ぐ
    }

    @Test func rejectsOverlyLongNames() {
        #expect(AgentLaunch.normalizedModel(String(repeating: "a", count: 200)) == nil)
    }

    // MARK: - 起動フラグの断片

    @Test func claudeUsesModelFlag() {
        #expect(AgentLaunch.modelFlag(kind: .claude, model: "opus") == " --model 'opus'")
        #expect(AgentLaunch.modelFlag(kind: .claude, model: "claude-opus-5") == " --model 'claude-opus-5'")
    }

    /// Codex は既存の MCP 注入と同じ `-c key=value` 上書きに乗せる。
    /// 値は TOML として解釈されるため文字列リテラルにする必要がある。
    @Test func codexUsesConfigOverride() {
        #expect(AgentLaunch.modelFlag(kind: .codex, model: "gpt-5-codex") == " -c 'model=\"gpt-5-codex\"'")
    }

    @Test func unspecifiedAddsNothing() {
        #expect(AgentLaunch.modelFlag(kind: .claude, model: nil) == "")
        #expect(AgentLaunch.modelFlag(kind: .codex, model: nil) == "")
        #expect(AgentLaunch.modelFlag(kind: .claude, model: "") == "")
        #expect(AgentLaunch.modelFlag(kind: .claude, model: "   ") == "")
    }

    /// 不正な値が Card に入っていても起動コマンドは汚染されない(既定モデルにフォールバック)。
    @Test func invalidValueFallsBackToDefaultModel() {
        #expect(AgentLaunch.modelFlag(kind: .claude, model: "opus; rm -rf /") == "")
        #expect(AgentLaunch.modelFlag(kind: .codex, model: "$(id)") == "")
    }

    // MARK: - Card の既定値

    @Test func existingCardsHaveNoModel() {
        let card = Card(title: "従来カード", order: 0)
        #expect(card.model == nil)
        #expect(AgentLaunch.modelFlag(kind: card.agentKind, model: card.model) == "")
    }
}
