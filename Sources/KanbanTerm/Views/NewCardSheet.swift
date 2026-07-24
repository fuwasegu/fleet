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

    /// worktree を作成してカードを紐づけるときの入力値。
    struct WorktreeCreationInfo {
        let repoRoot: String
        let branch: String
        let baseRef: String
    }

    /// (title, workingDirPath?, autoStartAgent, dangerSkip, agentKind, worktreeInfo?)
    /// worktree 作成やカード作成が失敗した場合は throw する。呼び出し側はエラーを
    /// シートの `wtError` に反映させ、シートを閉じない。
    let onCreate: (String, String?, Bool, Bool, AgentKind, WorktreeCreationInfo?) throws -> Void

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

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("作成") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
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
        let info: WorktreeCreationInfo?
        if makeWorktree, let dir = directory, isGitRepo {
            info = WorktreeCreationInfo(repoRoot: dir, branch: branchName, baseRef: baseBranch)
        } else {
            info = nil
        }
        do {
            try onCreate(resolvedTitle, directory, true, danger, kind, info)
            dismiss()
        } catch let error as WorktreeService.GitError {
            // worktree 作成/バインドに失敗。シートは閉じずカードも作らない(呼び出し側が
            // worktree 作成をカード作成より先に行うため、ここに来た時点でカードは未作成)。
            wtError = error.message
        } catch {
            wtError = error.localizedDescription
        }
    }
}
