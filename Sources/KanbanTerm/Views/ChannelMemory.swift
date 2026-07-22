import SwiftUI
import KanbanKit

/// チャンネルの共有メモリ(~/.fleet/channels/<id>/memory.jsonl)を閲覧・整理するシート。
/// Agent が書き込んだノート(author/text/時刻)を表示し、不要なものは削除できる。
struct ChannelMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let channelID: UUID
    let channelName: String

    @State private var entries: [ChannelEntry] = []
    @State private var watcher: (any DispatchSourceFileSystemObject)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(channelName).font(.headline).lineLimit(1)
                Text("共有メモリ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("まだ共有メモリはありません", systemImage: "tray")
                } description: {
                    Text("このチャンネルの Agent が fleet_remember で書き込むとここに現れます。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries.reversed()) { e in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(e.author)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.green)
                                    KindBadge(kind: e.effectiveKind)
                                    Text(e.createdAt, format: .relative(presentation: .named))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        ChannelStore.deleteEntry(e.id, from: channelID); reload()
                                    } label: { Image(systemName: "trash").font(.caption2) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                Text(e.text).font(.callout).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let refs = e.refs, !refs.isEmpty {
                                    Text(refs.joined(separator: "  ·  "))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 10).padding(.horizontal, 16)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 460)
        .task { reload(); startWatching() }
        .onDisappear { watcher?.cancel(); watcher = nil }
    }

    private func reload() {
        entries = ChannelStore.entries(for: channelID)
    }

    /// チャンネルディレクトリを監視して自動更新(Agent の fleet_remember が即座に映る)。
    /// ファイル本体でなくディレクトリを watch する(削除時の書き直しで inode が変わるため)。
    private func startWatching() {
        let dir = ChannelStore.dir(for: channelID)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { reload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}

/// メモリの種別バッジ(decision/blocker/artifact/question/note)。
private struct KindBadge: View {
    let kind: String
    private var color: Color {
        switch kind {
        case "decision": return .blue
        case "blocker":  return .red
        case "artifact": return .purple
        case "question": return .orange
        default:          return .secondary
        }
    }
    var body: some View {
        Text(kind)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
    }
}
