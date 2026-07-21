import SwiftUI
import Foundation

/// Claude Code の過去セッション1件。
struct ClaudeSession: Identifiable, Hashable {
    let id: String        // session_id (= jsonl のファイル名)
    let title: String
    let modified: Date
}

/// `~/.claude/projects/<cwd由来>/<session-id>.jsonl` から、指定 cwd のセッション一覧を取り出す。
/// (ディレクトリ名は cwd の "/" と "." を "-" に置換したもの。トークン集計と同じ領域)
enum ClaudeSessionsService {
    static func projectDirName(for cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        return expanded
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    static func list(forCwd cwd: String, limit: Int = 40) -> [ClaudeSession] {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let dir = (base as NSString).appendingPathComponent(projectDirName(for: cwd))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var out: [ClaudeSession] = []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(file)
            let sid = (file as NSString).deletingPathExtension
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            out.append(ClaudeSession(id: sid, title: firstPrompt(path) ?? "(プロンプトなし)", modified: modified))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// 先頭付近を読み、最初の「実プロンプト」(メタ/コマンド/ツール結果でない user 発言)をタイトルに。
    private static func firstPrompt(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["type"] as? String) == "user",
                  let raw = messageText(o["message"]) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // <local-command-...> / <command-...> / <system-reminder> 等のメタは飛ばす
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            let oneLine = t.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(100))
        }
        return nil
    }

    private static func messageText(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s }
        if let arr = m["content"] as? [[String: Any]] {
            for part in arr where (part["type"] as? String) == "text" {
                if let t = part["text"] as? String { return t }
            }
        }
        return nil
    }
}

/// 過去セッションを選んで復帰するシート。
struct SessionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cwd: String?
    let onPick: (String) -> Void

    @State private var sessions: [ClaudeSession] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("セッションを再開").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(16)
            if let cwd {
                Text(cwd).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity).frame(height: 160)
            } else if sessions.isEmpty {
                ContentUnavailableView("このディレクトリのセッションはありません",
                                       systemImage: "clock.badge.questionmark")
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { s in
                            Button { onPick(s.id); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).lineLimit(2).font(.callout)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        Text(s.modified, format: .relative(presentation: .named))
                                        Text(s.id.prefix(8)).font(.system(.caption2, design: .monospaced))
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 9).padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 420)
        .task {
            let dir = cwd
            sessions = await Task.detached {
                guard let dir else { return [] }
                return ClaudeSessionsService.list(forCwd: dir)
            }.value
            loading = false
        }
    }
}
