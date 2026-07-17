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

/// ボード全体を覆う保険のドロップ受け。列やカードの外(隙間・余白)で離しても
/// draggingCardID を必ずリセットし、カードが薄いまま固まるのを防ぐ。
/// カード移動はしない(ライブ移動で確定済みの位置を保持)。内側のcard/column delegateが優先される。
struct BoardResetDropDelegate: DropDelegate {
    let uiState: BoardUIState
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { uiState.draggingCardID = nil }
        return true
    }
}

/// カード上のドロップ処理。
/// - 同一列内: ホバー中にライブ並び替え（方向考慮）。ソースviewは同じForEach内に残るのでセッションは生存。
/// - 別列: ドラッグ中は移動しない（ソースviewを破棄しないため）。drop確定時に対象位置へ移動する。
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
            // 別列のカードはドラッグ中に動かさない（ソースview破棄→セッション孤立を防ぐ）
            guard dragged.column?.persistentModelID == column.persistentModelID else { return }

            let full = column.cards.sorted { $0.order < $1.order }
            let filtered = full.filter { $0.id != dragID }
            guard let base = filtered.firstIndex(where: { $0.id == target.id }) else { return }
            guard let from = full.firstIndex(where: { $0.id == dragID }),
                  let to = full.firstIndex(where: { $0.id == target.id }) else { return }
            let insertIndex = to > from ? base + 1 : base   // 上→下は後ろ、下→上は前
            withAnimation(.snappy(duration: 0.22)) {
                try? store.moveCard(dragged, to: column, at: insertIndex)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer { uiState.draggingCardID = nil }
            guard let dragID = uiState.draggingCardID else { return }
            let store = BoardStore(context: context)
            guard let dragged = store.card(withID: dragID) else { return }
            // 別列からのドロップ確定 → この列の対象カード位置へ移動
            if dragged.column?.persistentModelID != column.persistentModelID {
                let filtered = column.cards.filter { $0.id != dragID }.sorted { $0.order < $1.order }
                let idx = filtered.firstIndex(where: { $0.id == target.id }) ?? filtered.count
                withAnimation(.snappy(duration: 0.22)) {
                    try? store.moveCard(dragged, to: column, at: idx)
                }
            }
        }
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
