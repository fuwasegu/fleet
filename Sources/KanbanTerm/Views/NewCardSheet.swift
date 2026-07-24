import SwiftUI
import UniformTypeIdentifiers
import KanbanKit

/// カード新規作成ショートカット: 作業ディレクトリをGUIで選び、Agent種別/自動起動/危険モードを選ぶ。
/// フォルダ選択は1つだけで、「Git worktree を作成」トグルは選んだフォルダが git リポジトリの
/// 場合にのみ有効になるオプションとして重ねる(排他的なタブではない)。トグルON時は
/// ベースブランチ(リポジトリのローカルブランチ一覧から選択)と新ブランチ名を指定し、
/// Fleet 管理 worktree を新規作成してそこにカードを紐づける。
struct NewCardSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// worktree を作成してカードを紐づける場合に必要な store/column。
    /// worktree 作成の git 呼び出し(数秒かかりうる)をシート自身が非同期に実行し、
    /// 成功したらそのままシート内で `store.addCard` + `store.setWorktree` まで行う。
    let store: BoardStore
    let column: BoardColumn

    /// (title, workingDirPath?, autoStartAgent, dangerSkip, agentKind)
    /// worktree を伴わない(フォルダ紐づけ or 何もなし)カード作成。同期・即座に完了するため
    /// スピナーは出さない。カード作成が失敗した場合は throw する。呼び出し側はエラーを
    /// シートの `wtError` に反映させ、シートを閉じない。
    let onCreate: (String, String?, Bool, Bool, AgentKind) throws -> Void

    @State private var title = ""
    @State private var directory: String?
    @State private var picking = false
    @State private var danger = false
    @State private var kind: AgentKind = .claude

    @State private var repoCurrentBranch: String?
    @State private var branchList: [String] = []
    @State private var makeWorktree = false
    @State private var baseBranch: String = ""
    @State private var branchName = ""
    @State private var branchEditedByUser = false
    @State private var wtError: String?
    /// worktree 作成 (git worktree add) が進行中かどうか。true の間はボタンを無効化し
    /// スピナーを表示する(git-lfs のチェックアウトが数秒かかりうるため)。
    @State private var creating = false

    private var isGitRepo: Bool { repoCurrentBranch != nil }

    private var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let dir = directory { return (dir as NSString).lastPathComponent }
        return ""
    }

    private var canCreate: Bool {
        guard !resolvedTitle.isEmpty else { return false }
        if makeWorktree {
            return directory != nil && isGitRepo && !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var predictedWorktreePath: String {
        guard let directory else { return "" }
        return WorktreeService.worktreePath(repoRoot: directory, branch: branchName, baseDir: "../.fleet-worktrees")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新しいカード").font(.headline)

            directoryFields

            VStack(alignment: .leading, spacing: 4) {
                Text("タイトル").font(.caption).foregroundStyle(.secondary)
                TextField(titlePlaceholder, text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("エージェント").font(.caption).foregroundStyle(.secondary)
                Picker("エージェント", selection: $kind) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // カードを開くと Agent は自動起動・自動復帰するので、起動トグルは廃止。
            Toggle("権限確認をスキップ (自動承認)", isOn: $danger)

            if let wtError {
                Text(wtError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if creating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("worktree を作成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .disabled(creating)
                Button {
                    create()
                } label: {
                    if creating {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("作成中…")
                        }
                    } else {
                        Text("作成")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || creating)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                directory = url.path
                repoCurrentBranch = WorktreeService.currentBranch(repoRoot: url.path)
                branchList = WorktreeService.branches(repoRoot: url.path)
                baseBranch = repoCurrentBranch ?? (branchList.first ?? "")
                if repoCurrentBranch == nil {
                    makeWorktree = false
                }
            }
        }
        .onAppear {
            if branchName.isEmpty {
                branchName = WorktreeService.sanitizeBranch(title)
            }
        }
        .onChange(of: title) { _, newValue in
            guard !branchEditedByUser else { return }
            branchName = WorktreeService.sanitizeBranch(newValue)
        }
    }

    private var titlePlaceholder: String {
        directory.map { ($0 as NSString).lastPathComponent } ?? String(localized: "タイトル")
    }

    private var directoryFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("作業ディレクトリ").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    (directory.map(Text.init) ?? Text("フォルダを選択"))
                        .font(.callout)
                        .foregroundStyle(directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { picking = true }
                }
                if let repoCurrentBranch {
                    Text("現在: \(repoCurrentBranch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Git worktree を作成", isOn: $makeWorktree)
                .disabled(!isGitRepo)

            if makeWorktree && isGitRepo {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ベース").font(.caption).foregroundStyle(.secondary)
                        Picker("ベース", selection: $baseBranch) {
                            ForEach(branchList, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("新ブランチ名").font(.caption).foregroundStyle(.secondary)
                        TextField("新ブランチ名", text: $branchName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: branchName) { _, _ in branchEditedByUser = true }
                    }

                    Text("→ \(predictedWorktreePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.leading, 20)
            }
        }
    }

    private func create() {
        wtError = nil
        if makeWorktree, let dir = directory, isGitRepo {
            createWithWorktree(repoRoot: dir, branch: branchName, baseRef: baseBranch)
        } else {
            do {
                try onCreate(resolvedTitle, directory, true, danger, kind)
                dismiss()
            } catch let error as WorktreeService.GitError {
                wtError = error.message
            } catch {
                wtError = error.localizedDescription
            }
        }
    }

    /// worktree 作成(`git worktree add`, git-lfs チェックアウトで数秒かかりうる)をメインスレッド外で
    /// 実行し、その間 `creating` でスピナー表示・ボタン無効化する。git 呼び出しは `Task.detached` で
    /// バックグラウンド実行し(`WorktreeService` は nonisolated な値型引数のみを取るので安全)、
    /// 完了後の `await` 以降はこのビュー(MainActor)に戻ってから SwiftData のカード作成・
    /// worktree 紐づけを行う。worktree 作成をカード作成より先に行う順序は維持する
    /// (git 失敗時に孤児カードを残さないため)。
    private func createWithWorktree(repoRoot: String, branch: String, baseRef: String) {
        creating = true
        let title = resolvedTitle
        let dangerSkip = danger
        let agentKind = kind
        Task {
            do {
                let path = try await Task.detached(priority: .userInitiated) {
                    try WorktreeService.create(
                        repoRoot: repoRoot, branch: branch, baseRef: baseRef,
                        baseDir: "../.fleet-worktrees"
                    )
                }.value

                // ここから先は MainActor: SwiftData への書き込み。
                let card = try store.addCard(
                    title: title, to: column,
                    workingDirPath: nil, dangerSkip: dangerSkip, autoStartAgent: true,
                    agentKind: agentKind
                )
                try store.setWorktree(
                    card, repoRoot: repoRoot, worktreePath: path,
                    branch: WorktreeService.sanitizeBranch(branch), fleetOwned: true
                )
                creating = false
                dismiss()
            } catch let error as WorktreeService.GitError {
                // worktree 作成/バインドに失敗。シートは閉じずカードも作らない。
                wtError = error.message
                creating = false
            } catch {
                wtError = "\(error)"
                creating = false
            }
        }
    }
}
