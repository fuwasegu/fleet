import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import KanbanKit

struct BoardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BoardColumn.order) private var columns: [BoardColumn]
    @State private var uiState = BoardUIState()
    @State private var sessions = TerminalSessions()
    @State private var caffeine = CaffeineController()
    @State private var showingCaffeine = false

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
                Button {
                    showingCaffeine.toggle()
                } label: {
                    Image(systemName: caffeine.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(caffeine.isOn ? .orange : .primary)
                }
                .help("スリープ防止 (caffeinate)")
                .popover(isPresented: $showingCaffeine, arrowEdge: .bottom) {
                    CaffeinePopover(caffeine: caffeine)
                }
            }
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
                    .onTapGesture { closeTerminal() }

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text(card.title).font(.headline).lineLimit(1)
                        Text(card.workingDirPath ?? "~")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button {
                            openMarkdownPicker(cwd: card.workingDirPath)
                        } label: {
                            Label("Markdown", systemImage: "doc.richtext")
                        }
                        .buttonStyle(.borderless)
                        .help("Markdown をプレビュー")
                        Button {
                            closeTerminal()
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
                        sessions: sessions,
                        context: context,
                        uiState: uiState
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                .shadow(radius: 30)
                .padding(24)   // ほぼ全画面（周囲だけ余白 = 暗幕クリックで閉じられる）

                markdownPreviewOverlay   // Terminal のさらに上層 (fsl: preview は terminal の上)
            }
            .onExitCommand { closeTerminal() }
            .transition(.opacity)
        }
    }

    /// Markdown プレビュー(Terminal モーダルのさらに上のレイヤー)。
    @ViewBuilder private var markdownPreviewOverlay: some View {
        if let url = uiState.previewURL {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.3))
                    .ignoresSafeArea()
                    .onTapGesture { uiState.previewURL = nil }

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                        Text(url.lastPathComponent).font(.headline).lineLimit(1)
                        Spacer()
                        Button { uiState.previewURL = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("プレビューを閉じる")
                    }
                    .padding(10)
                    Divider()
                    MarkdownView(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "読み込めませんでした")
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                .shadow(radius: 30)
                .padding(60)
            }
        }
    }

    private func openMarkdownPicker(cwd: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        panel.allowedContentTypes = types
        if let cwd {
            panel.directoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            uiState.previewURL = url
        }
    }

    /// ターミナルを閉じる。閉じる直前に cwd をカードへ反映する。
    private func closeTerminal() {
        if let id = uiState.terminalCardID {
            sessions.refreshCwd(for: id, context: context)
            fetchPR(for: id)
        }
        uiState.previewURL = nil        // fsl: Terminal を閉じるとプレビューも閉じる
        uiState.terminalCardID = nil
    }

    /// 現在ブランチの PR URL を gh で取得してカードに反映する(取得はバックグラウンド)。
    private func fetchPR(for cardID: UUID) {
        guard let cwd = BoardStore(context: context).card(withID: cardID)?.workingDirPath else { return }
        Task {
            let url = await Task.detached { GitHubService.prURL(cwd: cwd) }.value
            if let card = BoardStore(context: context).card(withID: cardID) {
                try? BoardStore(context: context).setCardPR(card, url: url)
            }
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
