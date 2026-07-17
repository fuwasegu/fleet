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

/// カード上にホバーした時、方向を考慮してライブ移動（上→下・下→上の双方向で並び替え）
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

            let full = column.cards.sorted { $0.order < $1.order }
            let filtered = full.filter { $0.id != dragID }
            guard let base = filtered.firstIndex(where: { $0.id == target.id }) else { return }

            // 同一列内: ドラッグ中カードが対象より上にいれば対象の「後ろ」、下なら「前」へ。
            // 別列からの流入: dragged はこの列に居ないので対象の「前」に挿入。
            let insertIndex: Int
            if let from = full.firstIndex(where: { $0.id == dragID }),
               let to = full.firstIndex(where: { $0.id == target.id }) {
                insertIndex = to > from ? base + 1 : base
            } else {
                insertIndex = base
            }
            withAnimation(.snappy(duration: 0.22)) {
                try? store.moveCard(dragged, to: column, at: insertIndex)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { uiState.draggingCardID = nil }
        return true
    }
}

/// 列のカード以外の領域へドロップ → その列の末尾へ移動（同一列の最下部移動 / 空列への流入）。
/// ライブ移動は各カードの delegate が担うため、ここは drop 確定時のみ処理する。
struct ColumnDropDelegate: DropDelegate {
    let column: BoardColumn
    let context: ModelContext
    let uiState: BoardUIState

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { uiState.draggingCardID = nil }
            guard let dragID = uiState.draggingCardID else { return }
            let store = BoardStore(context: context)
            guard let dragged = store.card(withID: dragID) else { return }
            let end = column.cards.filter { $0.id != dragID }.count
            withAnimation(.snappy(duration: 0.22)) {
                try? store.moveCard(dragged, to: column, at: end)
            }
        }
        return true
    }
}
