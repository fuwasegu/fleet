import Foundation
import Testing
import SwiftData
@testable import KanbanKit

@MainActor
struct BoardStoreTests {

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    // MARK: - 列

    @Test func addColumnAssignsIncreasingOrder() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "作業中")
        let b = try store.addColumn(name: "レビュー待ち")
        #expect(a.order == 0)
        #expect(b.order == 1)
        #expect(try store.columns().count == 2)
    }

    @Test func addColumnRejectsEmptyName() throws {
        let store = try makeStore()
        #expect(throws: BoardError.emptyName) { try store.addColumn(name: "   ") }
    }

    @Test func renameColumnRejectsEmptyName() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        #expect(throws: BoardError.emptyName) { try store.renameColumn(a, to: "") }
        #expect(a.name == "A")
    }

    @Test func removeEmptyColumnSucceeds() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        try store.removeColumn(a)
        #expect(try store.columns().isEmpty)
    }

    // fsl: CardInExistingColumn / 孤児カード防止
    @Test func removeNonEmptyColumnFails() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addCard(title: "card", to: a)
        #expect(throws: BoardError.columnNotEmpty) { try store.removeColumn(a) }
        #expect(try store.columns().count == 1)
    }

    @Test func removeColumnNormalizesRemainingOrders() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addColumn(name: "B")
        let c = try store.addColumn(name: "C")
        try store.removeColumn(a)
        let cols = try store.columns()
        #expect(cols.map(\.order) == [0, 1])
        #expect(cols.last?.id == c.id)
    }

    @Test func setColumnColorPersists() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        try store.setColumnColor(a, hex: "FF453A")
        #expect(a.colorHex == "FF453A")
        try store.setColumnColor(a, hex: nil)
        #expect(a.colorHex == nil)
    }

    // MARK: - カード

    @Test func addCardAssignsIncreasingOrder() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c0 = try store.addCard(title: "0", to: a)
        let c1 = try store.addCard(title: "1", to: a)
        #expect(c0.order == 0)
        #expect(c1.order == 1)
        #expect(c0.column?.id == a.id)
    }

    @Test func newCardDefaultsToUnknownAndSeen() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "c", to: a)
        #expect(c.agentState == .unknown)
        #expect(c.isDone == false)
        #expect(c.dangerSkip == false)
    }

    // fsl: move_card — 移動後もカードは必ず列に属す
    @Test func moveCardBetweenColumns() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let b = try store.addColumn(name: "B")
        let c = try store.addCard(title: "c", to: a)
        try store.moveCard(c, to: b, at: 0)
        #expect(c.column?.id == b.id)
        #expect(a.cards.isEmpty)
        #expect(b.cards.count == 1)
    }

    @Test func moveCardReordersWithinColumn() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addCard(title: "0", to: a)
        _ = try store.addCard(title: "1", to: a)
        let c2 = try store.addCard(title: "2", to: a)
        try store.moveCard(c2, to: a, at: 0)
        let titles = a.cards.sorted { $0.order < $1.order }.map(\.title)
        #expect(titles == ["2", "0", "1"])
    }

    @Test func renameCardUpdatesTitle() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "old", to: a)
        try store.renameCard(c, to: "new")
        #expect(c.title == "new")
    }

    @Test func renameCardRejectsEmpty() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "keep", to: a)
        #expect(throws: BoardError.emptyName) { try store.renameCard(c, to: "  ") }
        #expect(c.title == "keep")
    }

    @Test func cardWithIDResolves() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "x", to: a)
        #expect(store.card(withID: c.id)?.id == c.id)
        #expect(store.card(withID: UUID()) == nil)
    }

    @Test func deleteCardNormalizesOrders() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c0 = try store.addCard(title: "0", to: a)
        _ = try store.addCard(title: "1", to: a)
        try store.deleteCard(c0)
        #expect(a.cards.count == 1)
        #expect(a.cards.first?.order == 0)
        #expect(a.cards.first?.title == "1")
    }
}
