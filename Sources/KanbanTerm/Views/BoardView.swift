import SwiftUI
import SwiftData
import KanbanKit

struct BoardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BoardColumn.order) private var columns: [BoardColumn]
    @State private var uiState = BoardUIState()
    @State private var sessions = TerminalSessions()

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
        .overlay { terminalOverlay }
        .animation(.easeInOut(duration: 0.15), value: uiState.terminalCardID)
        .navigationTitle("KANBAN Term")
        .toolbar {
            ToolbarItem {
                Button("列を追加", systemImage: "plus") { addColumn() }
            }
        }
        .environment(uiState)
        .environment(sessions)
    }

    /// カードから開くターミナルモーダル（ウィンドウ内オーバーレイ）。
    /// 暗幕タップ / Esc / ✕ で閉じる。閉じてもセッションは TerminalSessions が保持。
    @ViewBuilder private var terminalOverlay: some View {
        if let id = uiState.terminalCardID,
           let card = BoardStore(context: context).card(withID: id) {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.4))
                    .ignoresSafeArea()
                    .onTapGesture { uiState.terminalCardID = nil }

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text(card.title).font(.headline).lineLimit(1)
                        Text(card.workingDirPath ?? "~")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button {
                            uiState.terminalCardID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("閉じる (Esc)")
                    }
                    .padding(10)
                    Divider()
                    TerminalView(
                        cardID: id,
                        directory: card.workingDirPath,
                        startAgent: card.autoStartAgent,
                        dangerSkip: card.dangerSkip,
                        sessions: sessions
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                .shadow(radius: 30)
                .padding(24)   // ほぼ全画面（周囲だけ余白 = 暗幕クリックで閉じられる）
            }
            .onExitCommand { uiState.terminalCardID = nil }
            .transition(.opacity)
        }
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
