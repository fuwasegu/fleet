import Foundation

/// 端末出力から Agent の状態(working/blocked/idle)を判定する、データ駆動の検知エンジン。
/// herdr の「領域 + 優先度 + パターン」方式に着想を得た自前実装(herdr の TOML は非標準
/// ライセンスのため取り込まず、各エージェントの表示挙動という事実を基にルールを自作)。
///
/// 入力は「OSC タイトル」と「端末下部の行」のみ(Fleet が SwiftTerm から抽出できるもの)。
/// 純ロジックなので KanbanKit 側でユニットテストできる。UI/端末には依存しない。
public enum AgentDetection {

    /// ルールを当てる領域。
    public enum Region: Sendable {
        case oscTitle              // OSC 0/2 のタイトル文字列
        case whole                 // 与えられた下部行の全体
        case bottom(Int)           // 末尾の非空行 N 本
    }

    /// マッチ条件。contains 系は大文字小文字を無視。regex/lineRegex は原文に対して評価。
    public indirect enum Matcher: Sendable {
        case contains([String])        // 全ての部分文字列を含む
        case containsAny([String])     // いずれかの部分文字列を含む
        case regex(String)             // 領域テキスト全体に対する正規表現
        case lineRegex(String)         // いずれかの行がマッチ
        case all([Matcher])
        case any([Matcher])
        case not(Matcher)

        func matches(text: String, lines: [String]) -> Bool {
            switch self {
            case .contains(let subs):
                let lower = text.lowercased()
                return subs.allSatisfy { lower.contains($0.lowercased()) }
            case .containsAny(let subs):
                let lower = text.lowercased()
                return subs.contains { lower.contains($0.lowercased()) }
            case .regex(let p):
                return Self.rx(p, text)
            case .lineRegex(let p):
                return lines.contains { Self.rx(p, $0) }
            case .all(let ms):
                return ms.allSatisfy { $0.matches(text: text, lines: lines) }
            case .any(let ms):
                return ms.contains { $0.matches(text: text, lines: lines) }
            case .not(let m):
                return !m.matches(text: text, lines: lines)
            }
        }

        private static func rx(_ pattern: String, _ s: String) -> Bool {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    /// 1ルール。priority 降順で評価し、最初にマッチしたものを採用。
    public struct Rule: Sendable {
        let id: String
        let state: AgentState
        let priority: Int
        let region: Region
        let skip: Bool          // マッチしても状態を変えない(transcript viewer 等)
        let match: Matcher

        init(_ id: String, _ state: AgentState, _ priority: Int, _ region: Region,
             skip: Bool = false, _ match: Matcher) {
            self.id = id; self.state = state; self.priority = priority
            self.region = region; self.skip = skip; self.match = match
        }
    }

    /// 判定。マッチ無し or skip ルールがマッチ → nil(＝状態維持)。
    public static func classify(kind: AgentKind, title: String, lines: [String]) -> AgentState? {
        let rules = (kind == .codex ? codexRules : claudeRules).sorted { $0.priority > $1.priority }
        for rule in rules {
            let (text, rlines) = content(rule.region, title: title, lines: lines)
            if rule.match.matches(text: text, lines: rlines) {
                return rule.skip ? nil : rule.state
            }
        }
        return nil
    }

    private static func content(_ r: Region, title: String, lines: [String]) -> (String, [String]) {
        switch r {
        case .oscTitle:
            return (title, [title])
        case .whole:
            return (lines.joined(separator: "\n"), lines)
        case .bottom(let n):
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(n)
            return (nonEmpty.joined(separator: "\n"), Array(nonEmpty))
        }
    }

    // MARK: - Claude Code ルール

    static let brailleTitle = "^[\u{2800}-\u{28FF}]"      // 点字スピナー先頭 = 稼働
    static let starTitle = "^\u{2733}"                    // ✳ 先頭 = 待機

    static let claudeRules: [Rule] = [
        // transcript ビューア表示中は状態を変えない
        .init("transcript", .unknown, 1000, .bottom(3), skip: true,
              .all([.contains(["showing detailed transcript"]),
                    .any([.contains(["ctrl+o"]), .contains(["ctrl+e"]), .contains(["↑↓ scroll"]), .contains(["? for shortcuts"])])])),
        // bash 権限プロンプト(番号/❯ メニュー付き)。タイトルにスピナーが残っていても Blocked 優先。
        .init("bash_permission", .blocked, 950, .whole,
              .all([.contains(["do you want to proceed?"]),
                    .any([.contains(["bash command"]), .contains(["bash("]), .contains(["tab to amend"]), .contains(["ctrl+e to explain"]), .contains(["cannot be auto-allowed"])]),
                    .any([.lineRegex("(?i)^\\s*❯?\\s*yes\\b"), .lineRegex("(?i)^\\s*1\\.\\s*yes\\b"), .lineRegex("(?i)^\\s*2\\.\\s*no\\b")])])),
        // 一般の承認プロンプト(番号メニュー)
        .init("generic_permission", .blocked, 940, .whole,
              .all([.contains(["do you want to proceed?"]),
                    .any([.lineRegex("(?i)^\\s*❯?\\s*1\\.\\s*yes\\b"), .lineRegex("(?i)^\\s*2\\.\\s*no\\b"), .contains(["❯"])])])),
        // 選択フォーム(enter to select / esc to cancel + ナビ導線)
        .init("selection_form", .blocked, 930, .whole,
              .all([.contains(["esc to cancel"]),
                    .any([.contains(["enter to select"]), .contains(["arrow keys"]), .contains(["to navigate"]), .contains(["↑/↓"]), .contains(["↑↓"])])])),
        // 弱い権限シグナル
        .init("weak_permission", .blocked, 900, .whole,
              .any([.all([.contains(["do you want to"]), .any([.contains(["yes"]), .contains(["❯"])])]),
                    .all([.contains(["would you like to"]), .any([.contains(["yes"]), .contains(["❯"])])]),
                    .contains(["waiting for permission"])])),
        // 稼働: タイトルの点字スピナー
        .init("working_title", .working, 800, .oscTitle, .regex(brailleTitle)),
        // 稼働: フッタ "esc to interrupt"
        .init("working_footer", .working, 700, .whole, .contains(["esc to interrupt"])),
        // 待機: タイトル ✳
        .init("idle_star", .idle, 300, .oscTitle, .regex(starTitle)),
        // 待機: 入力プロンプト行 ❯(選択フォームでない)
        .init("idle_caret", .idle, 250, .bottom(6),
              .all([.lineRegex("^\\s*❯"),
                    .not(.containsAny(["enter to select", "esc to cancel", "arrow keys", "to navigate"]))])),
    ]

    // MARK: - Codex ルール(挙動という事実に基づく自作)

    static let codexRules: [Rule] = [
        // Blocked: Codex は待機時に OSC タイトルへ "Action Required" を出す(最優先)
        .init("codex_title_blocked", .blocked, 1100, .oscTitle, .contains(["action required"])),
        // Working: タイトルの点字スピナー
        .init("codex_title_working", .working, 1050, .oscTitle, .regex(brailleTitle)),
        // transcript ビューアは状態を変えない
        .init("codex_transcript", .unknown, 1000, .bottom(4), skip: true,
              .all([.containsAny(["↑/↓ to scroll", "pgup/pgdn", "q to quit"]),
                    .containsAny(["esc to edit prev", "esc/← to edit prev"])])),
        // Blocked: 明示的な確認/コマンド許可
        .init("codex_live_blocker", .blocked, 900, .whole,
              .containsAny(["press enter to confirm or esc to cancel", "enter to submit answer", "enter to submit all", "allow command?"])),
        // Blocked: 弱いシグナル
        .init("codex_weak_blocker", .blocked, 600, .whole,
              .any([.contains(["[y/n]"]), .contains(["yes (y)"]),
                    .all([.contains(["do you want to"]), .any([.contains(["yes"]), .contains(["❯"])])])])),
        // Working: フッタ "• Working (… esc to interrupt)"
        .init("codex_working_footer", .working, 500, .bottom(3),
              .lineRegex("^\\s*[•◦]\\s+Working \\([^)]*esc to interrupt\\)")),
        // Idle: タイトルが非空・スピナー無し・Action Required 無し
        .init("codex_title_idle", .idle, 100, .oscTitle,
              .all([.regex("\\S"), .not(.regex(brailleTitle)), .not(.contains(["action required"]))])),
    ]
}
