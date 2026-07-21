import SwiftUI
import KanbanKit

/// チャンネルの共有メモリ(~/.fleet/channels/<id>/memory.jsonl)を閲覧・整理するシート。
/// Agent が書き込んだノート(author/text/時刻)を表示し、不要なものは削除できる。
struct ChannelMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let channelID: UUID
    let channelName: String

    @State private var entries: [ChannelEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(channelName).font(.headline).lineLimit(1)
                Text("共有メモリ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("再読み込み")
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
                            }
                            .padding(.vertical, 10).padding(.horizontal, 16)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 460)
        .task { reload() }
    }

    private func reload() {
        entries = ChannelStore.entries(for: channelID)
    }
}
