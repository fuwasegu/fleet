import Foundation
import SwiftData

public enum BoardError: Error, Equatable {
    case emptyName
    case columnNotEmpty
}

/// ボード操作 API。`kanban_ui.fsl` のアクションに 1:1 対応し、不変条件をここで担保する。
@MainActor
public struct BoardStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// 列を order 昇順で取得
    public func columns() throws -> [BoardColumn] {
        let descriptor = FetchDescriptor<BoardColumn>(sortBy: [SortDescriptor(\.order)])
        return try context.fetch(descriptor)
    }

    // MARK: - 列 (状態)

    @discardableResult
    public func addColumn(name: String) throws -> BoardColumn {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        let next = (try columns().map(\.order).max() ?? -1) + 1
        let column = BoardColumn(name: trimmed, order: next)
        context.insert(column)
        try context.save()
        return column
    }

    public func renameColumn(_ column: BoardColumn, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        column.name = trimmed
        try context.save()
    }

    public func setColumnColor(_ column: BoardColumn, hex: String?) throws {
        column.colorHex = hex
        try context.save()
    }

    /// fsl: remove_column — 空でない列は削除不可（孤児カード防止 / CardInExistingColumn）
    public func removeColumn(_ column: BoardColumn) throws {
        guard column.cards.isEmpty else { throw BoardError.columnNotEmpty }
        context.delete(column)
        try context.save()
        normalizeColumnOrders()
        try context.save()
    }

    // MARK: - カード

    @discardableResult
    public func addCard(title: String,
                        to column: BoardColumn,
                        workingDirPath: String? = nil,
                        dangerSkip: Bool = false,
                        autoStartAgent: Bool = false) throws -> Card {
        let next = (column.cards.map(\.order).max() ?? -1) + 1
        let card = Card(title: title,
                        order: next,
                        column: column,
                        workingDirPath: workingDirPath,
                        dangerSkip: dangerSkip,
                        autoStartAgent: autoStartAgent)
        context.insert(card)
        try context.save()
        return card
    }

    public func renameCard(_ card: Card, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        card.title = trimmed
        try context.save()
    }

    public func setCardDirectory(_ card: Card, path: String?) throws {
        card.workingDirPath = path
        try context.save()
    }

    public func setCardPR(_ card: Card, url: String?) throws {
        card.prURL = url
        try context.save()
    }

    public func card(withID id: UUID) -> Card? {
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    public func column(withID id: UUID) -> BoardColumn? {
        let descriptor = FetchDescriptor<BoardColumn>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    public func deleteCard(_ card: Card) throws {
        let column = card.column
        context.delete(card)
        try context.save()
        if let column {
            normalizeCardOrders(in: column)
            try context.save()
        }
    }

    /// fsl: move_card — 列間移動 / 列内並び替え。移動後もカードは必ず列に属す。
    public func moveCard(_ card: Card, to column: BoardColumn, at index: Int) throws {
        let source = card.column
        card.column = column
        var target = column.cards
            .filter { $0.id != card.id }
            .sorted { $0.order < $1.order }
        let clamped = max(0, min(index, target.count))
        target.insert(card, at: clamped)
        for (i, c) in target.enumerated() { c.order = i }
        if let source, source.persistentModelID != column.persistentModelID {
            normalizeCardOrders(in: source)
        }
        try context.save()
    }

    // MARK: - order 正規化 (0..n-1)

    private func normalizeColumnOrders() {
        guard let cols = try? columns() else { return }
        for (i, c) in cols.enumerated() { c.order = i }
    }

    private func normalizeCardOrders(in column: BoardColumn) {
        let sorted = column.cards.sorted { $0.order < $1.order }
        for (i, c) in sorted.enumerated() { c.order = i }
    }
}
