import Foundation

/// Agent CLI の起動コマンドへ差し込む断片を作る純ロジック。
///
/// 実際のコマンド組み立ては `TerminalView` 側にあるが、文字列を組む判断は副作用が無く
/// 事故りやすい(シェル注入・CLI ごとの流儀の違い)ので、テストできる形でここに置く。
/// `shellQuote` を KanbanKit に一本化したのと同じ方針。
public enum AgentLaunch {

    /// モデル名として受け付ける最大長。実在するモデル ID より十分長く、暴走入力は弾く長さ。
    static let modelNameMaxLength = 128

    /// ユーザーが自由入力したモデル名を正規化する。受け付けられない値は nil(= 指定なし)。
    ///
    /// **固定の選択肢は持たない。** 新しいモデルが出るたびに Fleet を更新しなければ使えない、
    /// という状態を避けるため。`opus` のようなエイリアスも `claude-opus-5` のような完全 ID も
    /// `gpt-5-codex` のような別体系も、同じ欄で受ける。
    ///
    /// 一方でこの文字列は起動コマンドへ入るので、`shellQuote` に加えて**文字集合でも締める**
    /// (多層防御)。許すのは英数字と `. _ - [ ]` のみ。空白を許さないのは、空白区切りで
    /// 2引数に割れて意図しないフラグが混入するのを防ぐため。
    public static func normalizedModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= modelNameMaxLength else { return nil }
        guard trimmed.unicodeScalars.allSatisfy(isAllowedModelScalar) else { return nil }
        return trimmed
    }

    /// モデル名として妥当か(UI のバリデーション表示用)。
    public static func isValidModelName(_ raw: String) -> Bool {
        normalizedModel(raw) != nil
    }

    private static func isAllowedModelScalar(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        case ".", "_", "-", "[", "]":         return true
        default:                              return false
        }
    }

    /// 起動コマンドへ追記するモデル指定の断片(先頭に空白を含む)。指定なし・不正なら空文字。
    ///
    /// - Claude: `--model <name>`(ヘルプ上 "Model for the current session"。実測で
    ///   `--resume <id> --model X` でも当該セッションに適用されることを確認済み)
    /// - Codex: `-c model="<name>"`。既存の MCP 注入と同じ設定上書き経路に乗せる。
    ///   `-c` の値は TOML として解釈されるので、文字列リテラルとして二重引用符で包む
    ///   (包まないと `gpt-5-codex` のようなハイフン混じりが TOML として解釈できず、
    ///   生文字列フォールバックに頼ることになる)。
    public static func modelFlag(kind: AgentKind, model: String?) -> String {
        guard let name = normalizedModel(model) else { return "" }
        switch kind {
        case .claude:
            return " --model " + WorktreeService.shellQuote(name)
        case .codex:
            return " -c " + WorktreeService.shellQuote("model=\"\(name)\"")
        }
    }
}
