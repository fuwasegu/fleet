import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import KanbanKit

/// ドラッグ中のカードを共有するUI状態（元カードを隠す/ライブ並び替えのため）
@MainActor
@Observable
final class BoardUIState {
    var draggingCardID: UUID?
}

extension Color {
    /// "RRGGBB" 16進から生成
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

enum ColumnPalette {
    static let colors: [(name: String, hex: String)] = [
        ("レッド", "FF453A"),
        ("オレンジ", "FF9F0A"),
        ("イエロー", "FFD60A"),
        ("グリーン", "32D74B"),
        ("ブルー", "0A84FF"),
        ("パープル", "BF5AF2"),
        ("ピンク", "FF375F"),
        ("グレー", "8E8E93"),
    ]
}

/// カード上にホバーした時、そのカードの位置へドラッグ中カードをライブ移動（ヌルッと並び替え）
struct CardDropDelegate: DropDelegate {
    let target: Card
    let column: BoardColumn
    let context: ModelContext
    let uiState: BoardUIState

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragID = uiState.draggingCardID, dragID != target.id else { return }
            let store = BoardStore(context: context)
            guard let dragged = store.card(withID: dragID) else { return }
            let cards = column.cards
                .filter { $0.id != dragID }
                .sorted { $0.order < $1.order }
            let index = cards.firstIndex(where: { $0.id == target.id }) ?? cards.count
            withAnimation(.snappy(duration: 0.22)) {
                try? store.moveCard(dragged, to: column, at: index)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { uiState.draggingCardID = nil }
        return true
    }
}

/// 列の空き領域へドロップ → その列の末尾へ移動
struct ColumnDropDelegate: DropDelegate {
    let column: BoardColumn
    let context: ModelContext
    let uiState: BoardUIState

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragID = uiState.draggingCardID else { return }
            let store = BoardStore(context: context)
            guard let dragged = store.card(withID: dragID) else { return }
            if dragged.column?.persistentModelID != column.persistentModelID {
                withAnimation(.snappy(duration: 0.22)) {
                    try? store.moveCard(dragged, to: column, at: column.cards.count)
                }
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { uiState.draggingCardID = nil }
        return true
    }
}
