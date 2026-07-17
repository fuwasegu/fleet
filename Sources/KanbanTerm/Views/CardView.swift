import SwiftUI
import SwiftData
import KanbanKit

struct CardView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Bindable var card: Card

    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                agentBadge
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
                Button {
                    draft = card.title
                    renaming = true
                } label: {
                    Image(systemName: "pencil").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("カード名を編集")
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .contentShape(Rectangle())
        .opacity(uiState.draggingCardID == card.id ? 0.05 : 1)
        .onDrag {
            uiState.draggingCardID = card.id
            return NSItemProvider(object: card.id.uuidString as NSString)
        } preview: {
            cardPreview
        }
        .sheet(isPresented: $renaming) {
            RenameCardSheet(title: $draft) { newTitle in
                do { try BoardStore(context: context).renameCard(card, to: newTitle) } catch {}
            }
        }
    }

    /// ドラッグ中カーソルに追従するプレビュー（元カードは opacity で隠す）
    private var cardPreview: some View {
        Text(card.title)
            .font(.body.weight(.medium))
            .lineLimit(2)
            .padding(10)
            .frame(width: 248, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .shadow(radius: 8, y: 4)
    }

    @ViewBuilder private var agentBadge: some View {
        let style = badgeStyle
        HStack(spacing: 3) {
            Image(systemName: style.icon)
            Text(style.label)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.color.opacity(0.2), in: Capsule())
        .foregroundStyle(style.color)
    }

    private var badgeStyle: (label: String, color: Color, icon: String) {
        if card.isDone {
            return ("Done", .blue, "checkmark.circle")
        }
        switch card.agentState {
        case .working: return ("Working", .green, "arrow.triangle.2.circlepath")
        case .blocked: return ("Blocked", .orange, "hand.raised")
        case .idle:    return ("Idle", .gray, "pause.circle")
        case .unknown: return ("—", .gray, "terminal")
        }
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
