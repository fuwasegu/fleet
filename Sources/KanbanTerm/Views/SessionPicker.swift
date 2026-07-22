import SwiftUI
import Foundation

/// Claude Code の過去セッション1件。
struct ClaudeSession: Identifiable, Hashable {
    let id: String        // session_id (= jsonl のファイル名)
    let title: String
    let modified: Date
    let path: String      // jsonl のフルパス(プレビュー遅延読み込み用)
}

/// プレビュー用の1メッセージ。
struct PreviewMessage: Identifiable, Hashable {
    let id = UUID()
    let role: String      // "user" / "assistant"
    let text: String
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

    /// 指定 cwd の project ディレクトリに、このセッション id の jsonl が既にあるか。
    /// 自動復帰で「--resume(既存) か --session-id(新規) か」を決めるのに使う。
    static func sessionExists(id: String, cwd: String) -> Bool {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let dir = (base as NSString).appendingPathComponent(projectDirName(for: cwd))
        let path = (dir as NSString).appendingPathComponent("\(id).jsonl")
        return FileManager.default.fileExists(atPath: path)
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
            // session id は UUID 相当のみ採用(細工ファイル名を端末コマンドに混ぜない)
            guard sid.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            out.append(ClaudeSession(id: sid,
                                     title: firstPrompt(path) ?? "(プロンプトなし)",
                                     modified: modified,
                                     path: path))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// セッション末尾付近を読み、直近の会話(user/assistant のテキスト)を取り出す。
    static func preview(path: String, maxMessages: Int = 12) -> [PreviewMessage] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        let start = size > tail ? size - tail : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        // 途中から読んだ場合、最初の不完全な行は捨てる
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }

        var msgs: [PreviewMessage] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  let raw = messageText(o["message"]) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            msgs.append(PreviewMessage(role: type, text: String(t.prefix(600))))
        }
        return Array(msgs.suffix(maxMessages))
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
            let texts = arr.compactMap { part -> String? in
                (part["type"] as? String) == "text" ? part["text"] as? String : nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }
}

/// 過去セッションを選んで復帰するシート。左=一覧 / 右=選択セッションの直近会話プレビュー。
struct SessionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cwd: String?
    let onPick: (String) -> Void

    @State private var sessions: [ClaudeSession] = []
    @State private var loading = true
    @State private var selected: ClaudeSession?
    @State private var preview: [PreviewMessage] = []
    @State private var previewLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                ContentUnavailableView("このディレクトリのセッションはありません",
                                       systemImage: "clock.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sessionList.frame(width: 300)
                    Divider()
                    previewPane.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 780, height: 520)
        .task {
            let dir = cwd
            sessions = await Task.detached {
                guard let dir else { return [] }
                return ClaudeSessionsService.list(forCwd: dir)
            }.value
            loading = false
            if let first = sessions.first { select(first) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("セッションを再開").font(.headline)
                if let cwd {
                    Text(cwd).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Button("閉じる") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { s in
                    Button { select(s) } label: {
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
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        .background(selected?.id == s.id ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if previewLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if preview.isEmpty {
                Text(selected == nil ? "セッションを選択" : "会話を取得できませんでした")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("直近の会話").font(.caption).foregroundStyle(.tertiary)
                            .padding(.bottom, 2)
                        ForEach(preview) { m in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.role == "user" ? "You" : "Claude")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(m.role == "user" ? Color.accentColor : .green)
                                Text(m.text)
                                    .font(.callout)
                                    .foregroundStyle(m.role == "user" ? .primary : .secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    if let s = selected { onPick(s.id); dismiss() }
                } label: {
                    Label("このセッションを再開", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
            .padding(12)
        }
    }

    private func select(_ s: ClaudeSession) {
        selected = s
        previewLoading = true
        preview = []
        let path = s.path
        Task {
            let msgs = await Task.detached { ClaudeSessionsService.preview(path: path) }.value
            if selected?.id == s.id {   // 選択が変わっていなければ反映
                preview = msgs
                previewLoading = false
            }
        }
    }
}
