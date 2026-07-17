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

    // 将来スライス用のフィールド（今スライスは表示のみ / デフォルト値）
    public var workingDirPath: String?
    public var agentStateRaw: String
    public var dangerSkip: Bool
    public var seen: Bool

    public init(id: UUID = UUID(),
                title: String,
                order: Int,
                column: BoardColumn? = nil,
                workingDirPath: String? = nil,
                agentState: AgentState = .unknown,
                dangerSkip: Bool = false,
                seen: Bool = true) {
        self.id = id
        self.title = title
        self.order = order
        self.column = column
        self.workingDirPath = workingDirPath
        self.agentStateRaw = agentState.rawValue
        self.dangerSkip = dangerSkip
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
