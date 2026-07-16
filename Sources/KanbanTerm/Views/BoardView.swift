import SwiftUI
import SwiftData
import KanbanKit

struct BoardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BoardColumn.order) private var columns: [BoardColumn]

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
                }
            }
        }
        .navigationTitle("KANBAN Term")
        .toolbar {
            ToolbarItem {
                Button("列を追加", systemImage: "plus") { addColumn() }
            }
        }
    }

    private func addColumn() {
        _ = try? BoardStore(context: context).addColumn(name: "新しい列")
    }
}
