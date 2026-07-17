import SwiftUI
import SwiftData
import KanbanKit

struct ColumnView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Bindable var column: BoardColumn

    private var store: BoardStore { BoardStore(context: context) }
    private var sortedCards: [Card] { column.cards.sorted { $0.order < $1.order } }
    private var accent: Color { column.colorHex.flatMap(Color.init(hex:)) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(height: 4)
            header
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedCards) { card in
                        CardView(card: card)
                    }
                }
                .animation(.snappy(duration: 0.22), value: sortedCards.map(\.id))
            }
            Button("カードを追加", systemImage: "plus") {
                do { try store.addCard(title: "新しいカード", to: column) } catch {}
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.25)))
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("board"))
        } action: { rect in
            uiState.columnFrames[column.id] = rect
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
            colorMenu
            Button(role: .destructive) {
                do { try store.removeColumn(column) } catch {}
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!column.cards.isEmpty)
            .help(column.cards.isEmpty ? "列を削除" : "カードが残っている列は削除できません")
        }
    }

    private var colorMenu: some View {
        Menu {
            Button("なし") { setColor(nil) }
            ForEach(ColumnPalette.colors, id: \.hex) { entry in
                Button(entry.name) { setColor(entry.hex) }
            }
        } label: {
            Image(systemName: "paintpalette")
                .foregroundStyle(accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("列の色を変更")
    }

    private func setColor(_ hex: String?) {
        do { try store.setColumnColor(column, hex: hex) } catch {}
    }
}
