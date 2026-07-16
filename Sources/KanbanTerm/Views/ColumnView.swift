import SwiftUI
import SwiftData
import KanbanKit

struct ColumnView: View {
    @Environment(\.modelContext) private var context
    @Bindable var column: BoardColumn

    private var store: BoardStore { BoardStore(context: context) }
    private var sortedCards: [Card] { column.cards.sorted { $0.order < $1.order } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedCards) { card in
                        CardView(card: card)
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, before: card)
                            }
                    }
                }
            }
            Button("カードを追加", systemImage: "plus") {
                _ = try? store.addCard(title: "新しいカード", to: column)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: String.self) { items, _ in
            drop(items, at: sortedCards.count)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            TextField("列名", text: $column.name)
                .textFieldStyle(.plain)
                .font(.headline)
            Text("\(column.cards.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                try? store.removeColumn(column)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!column.cards.isEmpty)
            .help(column.cards.isEmpty ? "列を削除" : "カードが残っている列は削除できません")
        }
    }

    // MARK: - Drag & Drop

    @discardableResult
    private func drop(_ items: [String], before card: Card) -> Bool {
        guard let dragged = resolve(items) else { return false }
        let target = column.cards
            .filter { $0.id != dragged.id }
            .sorted { $0.order < $1.order }
        let index = target.firstIndex(where: { $0.id == card.id }) ?? target.count
        try? store.moveCard(dragged, to: column, at: index)
        return true
    }

    @discardableResult
    private func drop(_ items: [String], at index: Int) -> Bool {
        guard let dragged = resolve(items) else { return false }
        try? store.moveCard(dragged, to: column, at: index)
        return true
    }

    private func resolve(_ items: [String]) -> Card? {
        guard let raw = items.first, let uid = UUID(uuidString: raw) else { return nil }
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == uid })
        return try? context.fetch(descriptor).first
    }
}
