import SwiftUI
import SwiftData
import KanbanKit

/// カードの見た目（ドラッグ中のオーバーレイでも再利用する非依存ビュー）
struct CardFace: View {
    let card: Card
    var showActions: Bool = false
    var onEdit: () -> Void = {}
    var onOpenTerminal: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                AgentBadge(card: card)
            }
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(card.workingDirPath ?? "~/path/to/project")   // cwd プレースホルダ
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if showActions {
                    Button(action: onOpenTerminal) {
                        Image(systemName: "terminal").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("ターミナルを開く")
                    Button(action: onEdit) {
                        Image(systemName: "pencil").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("カード名を編集")
                }
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct AgentBadge: View {
    let card: Card

    var body: some View {
        let s = style
        HStack(spacing: 3) {
            Image(systemName: s.icon)
            Text(s.label)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(s.color.opacity(0.2), in: Capsule())
        .foregroundStyle(s.color)
    }

    private var style: (label: String, color: Color, icon: String) {
        if card.isDone { return ("Done", .blue, "checkmark.circle") }
        switch card.agentState {
        case .working: return ("Working", .green, "arrow.triangle.2.circlepath")
        case .blocked: return ("Blocked", .orange, "hand.raised")
        case .idle:    return ("Idle", .gray, "pause.circle")
        case .unknown: return ("—", .gray, "terminal")
        }
    }
}

struct CardView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Bindable var card: Card

    // ジェスチャ終了/キャンセルで必ず自動リセットされ、移動先の新viewには引き継がれない。
    // ID ベースのグローバルフラグと違い「移動先で薄いまま」が原理的に起きない。
    @GestureState private var isDragging = false

    @State private var renaming = false
    @State private var draft = ""

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
            .sheet(isPresented: $renaming) {
                RenameCardSheet(title: $draft) { newTitle in
                    do { try BoardStore(context: context).renameCard(card, to: newTitle) } catch {}
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
