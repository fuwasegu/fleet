import SwiftUI
import SwiftData
import KanbanKit

struct BoardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BoardColumn.order) private var columns: [BoardColumn]
    @State private var uiState = BoardUIState()

    var body: some View {
        Group {
            if columns.isEmpty {
                ContentUnavailableView {
                    Label("列がありません", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("「列を追加」で最初の状態(列)を作成してください。")
                } actions: {
                    Button("列を追加") { addColumn() }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(columns) { column in
                            ColumnView(column: column)
                        }
                    }
                    .padding()
                    .animation(.snappy(duration: 0.22), value: columns.map(\.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named("board"))
        .overlay(alignment: .topLeading) { draggedOverlay }
        .navigationTitle("KANBAN Term")
        .toolbar {
            ToolbarItem {
                Button("列を追加", systemImage: "plus") { addColumn() }
            }
        }
        .environment(uiState)
    }

    /// ドラッグ中のカードをカーソルに追従表示（元カードは opacity で隠す）
    @ViewBuilder private var draggedOverlay: some View {
        if let id = uiState.draggingCardID,
           let loc = uiState.dragLocation,
           let card = BoardStore(context: context).card(withID: id) {
            CardFace(card: card)
                .frame(width: 256)
                .opacity(0.95)
                .shadow(radius: 10, y: 6)
                .position(loc)
                .allowsHitTesting(false)
        }
    }

    private func addColumn() {
        do { try BoardStore(context: context).addColumn(name: "新しい列") } catch {}
    }
}
