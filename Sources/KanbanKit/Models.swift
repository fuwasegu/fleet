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

@Model
public final class Card {
    public var id: UUID
    public var title: String
    public var order: Int
    public var column: BoardColumn?

    // 宣言時デフォルト値は SwiftData の軽量マイグレーション(既存ストアへ属性追加)に必須。
    public var workingDirPath: String? = nil
    public var agentStateRaw: String = AgentState.unknown.rawValue
    public var dangerSkip: Bool = false        // 危険モードスキップ (Claude: --dangerously-skip-permissions)
    public var autoStartAgent: Bool = false    // カードのターミナル初回起動時に Claude を自動起動するか
    public var seen: Bool = true
    public var prURL: String? = nil            // 現在ブランチに紐づく GitHub PR の URL (gh 由来)
    public var branch: String? = nil           // 現在の git ブランチ名
    public var blockedPrompt: String? = nil    // Blocked 時に端末から取り出した実際の問い(例: "Do you want to proceed?")

    public init(id: UUID = UUID(),
                title: String,
                order: Int,
                column: BoardColumn? = nil,
                workingDirPath: String? = nil,
                agentState: AgentState = .unknown,
                dangerSkip: Bool = false,
                autoStartAgent: Bool = false,
                seen: Bool = true) {
        self.id = id
        self.title = title
        self.order = order
        self.column = column
        self.workingDirPath = workingDirPath
        self.agentStateRaw = agentState.rawValue
        self.dangerSkip = dangerSkip
        self.autoStartAgent = autoStartAgent
        self.seen = seen
    }

    /// 表示用: raw 文字列と AgentState の相互変換
    public var agentState: AgentState {
        get { AgentState(rawValue: agentStateRaw) ?? .unknown }
        set { agentStateRaw = newValue.rawValue }
    }

    /// "Done" 表示 = 完了(idle) かつ 未閲覧
    public var isDone: Bool { agentState == .idle && !seen }
}
