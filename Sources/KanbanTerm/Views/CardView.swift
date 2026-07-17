import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import KanbanKit

/// Agent 状態 → 色/ラベル/アイコン/アニメ有無。レール・バッジで共有する。
struct AgentStatusStyle {
    let label: String
    let color: Color
    let icon: String
    let animate: Bool

    init(card: Card) {
        if card.isDone {
            label = "Done"; color = .blue; icon = "checkmark.circle.fill"; animate = false
            return
        }
        switch card.agentState {
        case .working: label = "Working"; color = .green;  icon = "arrow.triangle.2.circlepath"; animate = true
        case .blocked: label = "Blocked"; color = .orange; icon = "hand.raised.fill";            animate = false
        case .idle:    label = "Idle";    color = .gray;   icon = "pause.circle.fill";           animate = false
        case .unknown: label = "待機なし"; color = .gray;  icon = "terminal";                    animate = false
        }
    }
}

/// カードの見た目（ドラッグ中のオーバーレイでも再利用する非依存ビュー）
struct CardFace: View {
    let card: Card
    var showActions: Bool = false
    var onEdit: () -> Void = {}
    var onOpenTerminal: () -> Void = {}

    private var status: AgentStatusStyle { AgentStatusStyle(card: card) }

    var body: some View {
        HStack(spacing: 0) {
            // シグネチャ: Agent状態のステータスレール（壁一面で状態を一目スキャン）
            Rectangle()
                .fill(status.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    AgentBadge(card: card)
                    if showActions {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("カード名を編集")
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    metaLine("folder", card.workingDirPath ?? "~/path/to/project", truncation: .head)
                    if card.branch != nil || card.prURL != nil {
                        HStack(spacing: 8) {
                            if let branch = card.branch {
                                metaLine("arrow.triangle.branch", branch, truncation: .tail)
                            }
                            Spacer(minLength: 4)
                            if let pr = card.prURL, let url = URL(string: pr) {
                                Button { NSWorkspace.shared.open(url) } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.forward.square")
                                        Text("PR")
                                    }
                                    .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                                .help(pr)
                            }
                        }
                    }
                }

                if showActions {
                    Button(action: onOpenTerminal) {
                        Label("ターミナルを開く", systemImage: "terminal.fill")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help("ターミナルを開く")
                }
            }
            .padding(12)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(status.color.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metaLine(_ systemImage: String, _ text: String, truncation: Text.TruncationMode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.system(.caption2, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(truncation)
    }
}

struct AgentBadge: View {
    let card: Card
    @State private var spin = false

    var body: some View {
        let s = AgentStatusStyle(card: card)
        HStack(spacing: 4) {
            Image(systemName: s.icon)
                .rotationEffect(.degrees(s.animate && spin ? 360 : 0))
                .animation(
                    s.animate ? .linear(duration: 1.4).repeatForever(autoreverses: false) : .default,
                    value: spin
                )
            Text(s.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(s.color.opacity(0.18), in: Capsule())
        .foregroundStyle(s.color)
        .onAppear { if s.animate { spin = true } }
        .onChange(of: card.agentStateRaw) { _, _ in
            spin = AgentStatusStyle(card: card).animate
        }
    }
}

struct CardView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Environment(TerminalSessions.self) private var sessions
    @Bindable var card: Card

    @GestureState private var isDragging = false

    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var changingDir = false

    var body: some View {
        CardFace(
            card: card,
            showActions: true,
            onEdit: beginRename,
            onOpenTerminal: { uiState.terminalCardID = card.id }
        )
            .opacity(isDragging ? 0.05 : 1)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("board"))
            } action: { rect in
                uiState.cardFrames[card.id] = rect
            }
            .gesture(dragGesture)
            .contextMenu {
                Button { uiState.terminalCardID = card.id } label: {
                    Label("ターミナルを開く", systemImage: "terminal")
                }
                Button(action: beginRename) {
                    Label("名前を変更", systemImage: "pencil")
                }
                Button { changingDir = true } label: {
                    Label("作業ディレクトリを変更…", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("カードを削除", systemImage: "trash")
                }
            }
            .sheet(isPresented: $renaming) {
                RenameCardSheet(title: $draft) { newTitle in
                    do { try BoardStore(context: context).renameCard(card, to: newTitle) } catch {}
                }
            }
            .alert("カードを削除しますか?", isPresented: $confirmingDelete) {
                Button("削除", role: .destructive, action: deleteCard)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(card.title)」を削除します。起動中のターミナル/Agent も終了します。")
            }
            .fileImporter(isPresented: $changingDir, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    try? BoardStore(context: context).setCardDirectory(card, path: url.path)
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("board"))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                uiState.draggingCardID = card.id
                uiState.dragLocation = value.location
            }
            .onEnded { value in
                commitCardDrop(cardID: card.id, at: value.location, context: context, uiState: uiState)
                uiState.draggingCardID = nil
                uiState.dragLocation = nil
            }
    }

    private func beginRename() {
        draft = card.title
        renaming = true
    }

    private func deleteCard() {
        if uiState.terminalCardID == card.id { uiState.terminalCardID = nil }
        sessions.close(card.id)
        do { try BoardStore(context: context).deleteCard(card) } catch {}
    }
}

/// カード名編集モーダル
struct RenameCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    let onSave: (String) -> Void

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("カード名を編集").font(.headline)
            TextField("タイトル", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid { save() } }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}
