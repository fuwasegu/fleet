import SwiftUI
import Foundation
import KanbanKit

/// 過去セッションを選んで復帰するシート。左=一覧 / 右=選択セッションの直近会話プレビュー。
/// `cwds` は列挙する project ディレクトリ群(worktree カードなら worktree 本体 + 元 repo の2つ、
/// フォルダカードなら1つ)。session id で重複排除し、更新日時降順にまとめて一覧表示する。
struct SessionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 列挙する project ディレクトリ群。フォルダカードは effectiveCwd 1件のみ、
    /// worktree カードは呼び出し側(CardView)が [effectiveCwd, repoRoot] を渡す。
    let cwds: [String]
    /// カードに割り当てられた `ClaudeProfile.configDirPath`。nil/空ならデフォルトの `~/.claude`。
    let configDir: String?
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
            let dirs = cwds
            let cfgDir = configDir
            sessions = await Task.detached {
                var seen = Set<String>()
                var merged: [ClaudeSession] = []
                for dir in dirs {
                    for s in ClaudeSessionsService.list(forCwd: dir, configDir: cfgDir) where seen.insert(s.id).inserted {
                        merged.append(s)
                    }
                }
                return merged.sorted { $0.modified > $1.modified }
            }.value
            loading = false
            if let first = sessions.first { select(first) }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("セッションを再開").font(.headline)
                if let primary = cwds.first {
                    Text(primary).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if cwds.count > 1 {
                    Text("+ 元リポジトリのセッションも含む")
                        .font(.caption2).foregroundStyle(.tertiary)
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
