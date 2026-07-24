import Foundation
import SwiftData

/// Agent 状態。herdr 実装準拠（`kanban_ui.fsl` の AgentSt）。
/// "Done" は独立状態ではなく (idle かつ未閲覧) の派生（`Card.isDone`）。
public enum AgentState: String, Codable, CaseIterable, Sendable {
    case unknown
    case idle
    case working
    case blocked
}

/// カードで動かすエージェントの種別。起動コマンド・状態検知・MCP 配線・共通指示の差し替え軸。
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }
}

@Model
public final class BoardColumn {
    public var id: UUID
    public var name: String
    public var order: Int
    /// 列のアクセントカラー(16進 "RRGGBB")。nil はデフォルト色。
    public var colorHex: String?

    @Relationship(deleteRule: .cascade, inverse: \Card.column)
    public var cards: [Card]

    public init(id: UUID = UUID(), name: String, order: Int, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.order = order
        self.colorHex = colorHex
        self.cards = []
    }
}

/// A2A 共有メモリのチャンネル(＝盤面でつないだカードのクラスタ)。
/// メモリ本体は SwiftData ではなく ~/.fleet/channels/<id>/memory.jsonl に置く(別プロセスの
/// fleet-bridge と共有するため)。この Model は所属関係とメタだけを持つ。
@Model
public final class Channel {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var colorHex: String?

    @Relationship(inverse: \Card.channel)
    public var cards: [Card]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.colorHex = colorHex
        self.cards = []
    }
}

/// 名前付き Claude 設定プロファイル(ラベル + `CLAUDE_CONFIG_DIR`)。
/// カードに割り当てることで、別アカウント/ライセンスの config dir を向けて claude CLI を起動できる。
@Model
public final class ClaudeProfile {
    public var id: UUID
    public var label: String
    public var configDirPath: String
    public var order: Int

    @Relationship(deleteRule: .nullify, inverse: \Card.claudeProfile)
    public var cards: [Card]

    public init(id: UUID = UUID(), label: String, configDirPath: String, order: Int) {
        self.id = id
        self.label = label
        self.configDirPath = configDirPath
        self.order = order
        self.cards = []
    }
}

@Model
public final class Card {
    public var id: UUID
    public var title: String
    public var order: Int
    public var column: BoardColumn?
    public var channel: Channel?   // A2A: 所属する共有メモリチャンネル(0..1)
    @Relationship(deleteRule: .nullify)
    public var claudeProfile: ClaudeProfile? = nil   // 割り当てた Claude 設定プロファイル(config dir 切替用)

    // 宣言時デフォルト値は SwiftData の軽量マイグレーション(既存ストアへ属性追加)に必須。
    public var workingDirPath: String? = nil
    public var agentStateRaw: String = AgentState.unknown.rawValue
    public var dangerSkip: Bool = false        // 危険モードスキップ (Claude: --dangerously-skip-permissions)
    public var autoStartAgent: Bool = false    // カードのターミナル初回起動時に Claude を自動起動するか
    public var seen: Bool = true
    public var prURL: String? = nil            // 現在ブランチに紐づく GitHub PR の URL (gh 由来)
    public var branch: String? = nil           // 現在の git ブランチ名
    public var blockedPrompt: String? = nil    // Blocked 時に端末から取り出した実際の問い(例: "Do you want to proceed?")
    public var agentKindRaw: String = AgentKind.claude.rawValue   // 起動する Agent 種別
    public var claudeSessionID: String? = nil   // このカードに固定した Claude セッション id(自動復帰用)
    public var codexSessionID: String? = nil    // このカードに紐づく Codex セッション id(初回起動後に捕捉)
    public var repoRoot: String? = nil          // Fleet 管理 worktree の元リポジトリ root
    public var worktreePath: String? = nil      // このカードに紐づく worktree の絶対パス
    public var isFleetOwnedWorktree: Bool = false  // worktree の作成/撤去を Fleet が管理してよいか

    public init(id: UUID = UUID(),
                title: String,
                order: Int,
                column: BoardColumn? = nil,
                workingDirPath: String? = nil,
                agentState: AgentState = .unknown,
                dangerSkip: Bool = false,
                autoStartAgent: Bool = false,
                seen: Bool = true,
                agentKind: AgentKind = .claude) {
        self.id = id
        self.title = title
        self.order = order
        self.column = column
        self.workingDirPath = workingDirPath
        self.agentStateRaw = agentState.rawValue
        self.dangerSkip = dangerSkip
        self.autoStartAgent = autoStartAgent
        self.seen = seen
        self.agentKindRaw = agentKind.rawValue
    }

    /// 表示用: raw 文字列と AgentState の相互変換
    public var agentState: AgentState {
        get { AgentState(rawValue: agentStateRaw) ?? .unknown }
        set { agentStateRaw = newValue.rawValue }
    }

    /// 起動する Agent 種別(claude / codex)
    public var agentKind: AgentKind {
        get { AgentKind(rawValue: agentKindRaw) ?? .claude }
        set { agentKindRaw = newValue.rawValue }
    }

    /// "Done" 表示 = 完了(idle) かつ 未閲覧
    public var isDone: Bool { agentState == .idle && !seen }

    /// cwd 解決: worktree バインディングがあれば優先し、無ければ従来の作業ディレクトリ
    public var effectiveCwd: String? { worktreePath ?? workingDirPath }
}
