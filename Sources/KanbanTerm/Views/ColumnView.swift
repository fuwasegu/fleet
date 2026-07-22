import SwiftUI
import SwiftData
import KanbanKit

struct ColumnView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Bindable var column: BoardColumn

    @State private var addingCard = false
    @GestureState private var isDraggingColumn = false

    private var store: BoardStore { BoardStore(context: context) }
    private var sortedCards: [Card] { column.cards.sorted { $0.order < $1.order } }
    private var accent: Color { column.colorHex.flatMap(Color.init(hex:)) ?? .gray }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(height: 3)
                .shadow(color: accent.opacity(0.7), radius: 5)   // ネオン風グロー
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
                addingCard = true
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .sheet(isPresented: $addingCard) {
            NewCardSheet { title, dir, autoStart, danger, kind in
                do {
                    try store.addCard(
                        title: title, to: column,
                        workingDirPath: dir, dangerSkip: danger, autoStartAgent: autoStart,
                        agentKind: kind
                    )
                } catch {}
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "121519")!)                       // 暗いパネル
                .overlay(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.05)))  // 極薄アクセント
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.22), lineWidth: 1))
        .opacity(isDraggingColumn ? 0.25 : 1)   // ドラッグ中の元列を薄く
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("board"))
        } action: { rect in
            uiState.columnFrames[column.id] = rect
        }
    }

    /// 列ヘッダのグリップ。掴んで左右にドラッグして列を並べ替える。
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .help("ドラッグで列を並べ替え")
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("board"))
                    .updating($isDraggingColumn) { _, state, _ in state = true }
                    .onChanged { value in
                        uiState.draggingColumnID = column.id
                        uiState.columnDragLocation = value.location
                    }
                    .onEnded { value in
                        commitColumnDrop(columnID: column.id, at: value.location,
                                         context: context, uiState: uiState)
                        uiState.draggingColumnID = nil
                        uiState.columnDragLocation = nil
                    }
            )
    }

    private var header: some View {
        HStack(spacing: 6) {
            dragHandle
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
                Button(LocalizedStringKey(entry.name)) { setColor(entry.hex) }
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
