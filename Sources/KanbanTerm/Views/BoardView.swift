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
    @State private var showingTokens = false
    @State private var showingSettings = false

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
        .background(Color(hex: "0B0D0F")!)   // サイバーなニアブラックの盤面
        .coordinateSpace(.named("board"))
        .overlay(alignment: .topLeading) { draggedOverlay }
        .overlay(alignment: .topLeading) { columnDraggedOverlay }
        .overlay(alignment: .topLeading) { tooltipOverlay }
        .overlay { terminalOverlay }
        .animation(.easeInOut(duration: 0.15), value: uiState.terminalCardID)
        .navigationTitle("Fleet")
        .toolbar {
            ToolbarItem {
                Button {
                    showingTokens.toggle()
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .help("トークン使用量")
                .popover(isPresented: $showingTokens, arrowEdge: .bottom) {
                    TokenDashboard()
                }
            }
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
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "textformat.size")
                }
                .help("ターミナルのフォント設定")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    TerminalSettingsPopover(sessions: sessions)
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
                    MarkdownWebView(markdown: (try? String(contentsOf: url, encoding: .utf8)) ?? String(localized: "読み込めませんでした"))
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
            fetchGitInfo(for: id)
        }
        uiState.previewURL = nil        // fsl: Terminal を閉じるとプレビューも閉じる
        uiState.terminalCardID = nil
    }

    /// 現在ブランチと PR URL を git/gh で取得してカードに反映する(取得はバックグラウンド)。
    private func fetchGitInfo(for cardID: UUID) {
        guard let cwd = BoardStore(context: context).card(withID: cardID)?.workingDirPath else { return }
        Task {
            let info = await Task.detached { () -> (String?, String?) in
                (GitHubService.branch(cwd: cwd), GitHubService.prURL(cwd: cwd))
            }.value
            if let card = BoardStore(context: context).card(withID: cardID) {
                try? BoardStore(context: context).setCardGitInfo(card, branch: info.0, prURL: info.1)
            }
        }
    }

    /// プロンプト行ホバー時の tooltip。列のクリップを受けないよう最上位で、カーソル付近に浮かせる。
    @ViewBuilder private var tooltipOverlay: some View {
        if let id = uiState.tooltipCardID, let anchor = uiState.tooltipAnchor,
           uiState.draggingCardID == nil, uiState.terminalCardID == nil,
           let card = BoardStore(context: context).card(withID: id),
           !card.promptTooltipText.isEmpty {
            GeometryReader { geo in
                let lines = card.promptTooltipText.split(separator: "\n")
                let longest = lines.map(\.count).max() ?? 0
                let estWidth = CGFloat(longest) * 7.1 + 60      // アイコン列 + 余白込み
                let estHeight = CGFloat(lines.count) * 21 + 44   // ヘッダ + 余白込み
                let x = min(max(12, anchor.x + 14), max(12, geo.size.width - estWidth - 12))
                let y = min(anchor.y + 18, max(12, geo.size.height - estHeight - 12))
                PromptTooltip(card: card)
                    .offset(x: x, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    /// 並べ替え中の列を示す、カーソル追従のチップ。
    @ViewBuilder private var columnDraggedOverlay: some View {
        if let id = uiState.draggingColumnID,
           let loc = uiState.columnDragLocation,
           let column = BoardStore(context: context).column(withID: id) {
            let accent = column.colorHex.flatMap(Color.init(hex:)) ?? .gray
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 18, height: 3)
                Text(column.name).font(.headline).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(hex: "121519")!, in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.5), lineWidth: 1))
            .shadow(radius: 12, y: 5)
            .position(loc)
            .allowsHitTesting(false)
        }
    }

    /// ドラッグ中のカードをカーソルに追従表示（元カードは opacity で隠す）
    @ViewBuilder private var draggedOverlay: some View {
        if let id = uiState.draggingCardID,
           let loc = uiState.dragLocation,
           let card = BoardStore(context: context).card(withID: id) {
            CardFace(card: card)
                .frame(width: 256)
                .fixedSize(horizontal: false, vertical: true)   // 内容の高さにフィット(縦伸び防止)
                .opacity(0.95)
                .shadow(radius: 10, y: 6)
                .position(loc)
                .allowsHitTesting(false)
        }
    }

    private func addColumn() {
        do { try BoardStore(context: context).addColumn(name: String(localized: "新しい列")) } catch {}
    }
}
