import SwiftUI
import SwiftData
import KanbanKit

/// ドラッグ状態と、位置判定用のフレーム情報を共有する。
/// DragGesture ベースなので onEnded で必ずリセットされ、カードが薄いまま固まらない。
@MainActor
@Observable
final class BoardUIState {
    var draggingCardID: UUID?
    var dragLocation: CGPoint?                 // "board" 座標系でのカーソル位置
    var cardFrames: [UUID: CGRect] = [:]       // 各カードの "board" 座標系フレーム
    var columnFrames: [UUID: CGRect] = [:]     // 各列の "board" 座標系フレーム
    var terminalCardID: UUID?                  // ターミナルモーダルを開いているカード(fsl: terminal_open)
    var previewURL: URL?                        // Markdownプレビュー中のファイル(fsl: preview_open、terminal の上層)
    var tooltipCardID: UUID?                   // プロンプト行ホバー中のカード(tooltip 表示対象)
    var tooltipAnchor: CGPoint?                // "board" 座標系でのカーソル位置(tooltip の基準点)
    var draggingColumnID: UUID?                // 並べ替え中の列
    var columnDragLocation: CGPoint?           // "board" 座標系でのカーソル位置(列ドラッグ)
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

/// ドロップ確定: カーソル位置(board座標)から対象の列と挿入位置を割り出して移動する。
@MainActor
func commitCardDrop(cardID: UUID, at location: CGPoint, context: ModelContext, uiState: BoardUIState) {
    let store = BoardStore(context: context)
    guard let dragged = store.card(withID: cardID) else { return }

    // 対象の列: 位置を含む列。無ければ x が最も近い列。
    let frames = uiState.columnFrames
    let targetColumnID = frames.first(where: { $0.value.contains(location) })?.key
        ?? frames.min(by: { abs($0.value.midX - location.x) < abs($1.value.midX - location.x) })?.key
    guard let colID = targetColumnID, let column = store.column(withID: colID) else { return }

    // 挿入位置: カーソル y が各カードの中点より上に来た最初の位置
    let cardsInColumn = column.cards
        .filter { $0.id != cardID }
        .sorted { $0.order < $1.order }
    var index = cardsInColumn.count
    for (i, c) in cardsInColumn.enumerated() {
        if let f = uiState.cardFrames[c.id], location.y < f.midY {
            index = i
            break
        }
    }
    withAnimation(.snappy(duration: 0.2)) {
        try? store.moveCard(dragged, to: column, at: index)
    }
}

/// 列ドロップ確定: カーソル x から挿入位置を割り出して列を並べ替える。
@MainActor
func commitColumnDrop(columnID: UUID, at location: CGPoint, context: ModelContext, uiState: BoardUIState) {
    let store = BoardStore(context: context)
    guard let dragged = store.column(withID: columnID) else { return }
    let others = ((try? store.columns()) ?? []).filter { $0.id != columnID }
    var index = others.count
    for (i, c) in others.enumerated() {
        if let f = uiState.columnFrames[c.id], location.x < f.midX {
            index = i
            break
        }
    }
    withAnimation(.snappy(duration: 0.2)) {
        try? store.moveColumn(dragged, to: index)
    }
}
