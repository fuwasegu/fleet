import SwiftUI
import SwiftData
import KanbanKit

struct CardView: View {
    @Bindable var card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TextField("タイトル", text: $card.title)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Spacer(minLength: 4)
                agentBadge
            }
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // cwd プレースホルダ（後続スライスで実 cwd に差し替え）
                Text(card.workingDirPath ?? "~/path/to/project")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .draggable(card.id.uuidString)
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
