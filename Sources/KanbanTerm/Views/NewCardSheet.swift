import SwiftUI
import UniformTypeIdentifiers
import KanbanKit

/// カード新規作成ショートカット: 作業ディレクトリをGUIで選び、Agent種別/自動起動/危険モードを選ぶ。
/// 「worktree を作る」モードでは、リポジトリ・ブランチ名・ベースを選んで
/// Fleet 管理 worktree を新規作成し、そこにカードを紐づけることもできる。
struct NewCardSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// worktree モードで作成するときの入力値。
    struct WorktreeCreationInfo {
        let repoRoot: String
        let branch: String
        let base: WorktreeBase
    }

    /// (title, workingDirPath?, autoStartAgent, dangerSkip, agentKind, worktreeInfo?)
    /// worktree 作成やカード作成が失敗した場合は throw する。呼び出し側はエラーを
    /// シートの `wtError` に反映させ、シートを閉じない。
    let onCreate: (String, String?, Bool, Bool, AgentKind, WorktreeCreationInfo?) throws -> Void

    enum Mode: String, CaseIterable {
        case folder = "既存フォルダ"
        case worktree = "worktree を作る"
    }

    @State private var title = ""
    @State private var directory: String?
    @State private var picking = false
    @State private var danger = false
    @State private var kind: AgentKind = .claude

    @State private var mode: Mode = .folder
    @State private var repoRoot: String?
    @State private var pickingRepo = false
    @State private var repoCurrentBranch: String?
    @State private var repoDefaultBranch: String?
    @State private var branchName = ""
    @State private var branchEditedByUser = false
    @State private var base: WorktreeBase = .current
    @State private var wtError: String?

    private var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if mode == .worktree {
            return repoRoot.map { ($0 as NSString).lastPathComponent } ?? ""
        }
        if let dir = directory { return (dir as NSString).lastPathComponent }
        return ""
    }

    private var canCreate: Bool {
        guard !resolvedTitle.isEmpty else { return false }
        if mode == .worktree {
            return repoRoot != nil && !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新しいカード").font(.headline)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .folder {
                folderFields
            } else {
                worktreeFields
            }

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
            }
        }
        .fileImporter(isPresented: $pickingRepo, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                repoRoot = url.path
                repoCurrentBranch = WorktreeService.currentBranch(repoRoot: url.path)
                repoDefaultBranch = WorktreeService.defaultBranch(repoRoot: url.path)
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
        if mode == .worktree {
            return repoRoot.map { ($0 as NSString).lastPathComponent } ?? String(localized: "タイトル")
        }
        return directory.map { ($0 as NSString).lastPathComponent } ?? String(localized: "タイトル")
    }

    private var folderFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("作業ディレクトリ").font(.caption).foregroundStyle(.secondary)
            HStack {
                (directory.map(Text.init) ?? Text("未選択"))
                    .font(.callout)
                    .foregroundStyle(directory == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("選択…") { picking = true }
            }
        }
    }

    private var worktreeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("リポジトリ").font(.caption).foregroundStyle(.secondary)
                HStack {
                    (repoRoot.map(Text.init) ?? Text("未選択"))
                        .font(.callout)
                        .foregroundStyle(repoRoot == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { pickingRepo = true }
                }
                if repoRoot != nil {
                    if let repoCurrentBranch {
                        Text("現在のブランチ: \(repoCurrentBranch)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("git リポジトリではありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ブランチ名").font(.caption).foregroundStyle(.secondary)
                TextField("ブランチ名", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branchName) { _, _ in branchEditedByUser = true }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ベース").font(.caption).foregroundStyle(.secondary)
                Picker("ベース", selection: $base) {
                    Text(baseLabel(.current)).tag(WorktreeBase.current)
                    Text(baseLabel(.defaultBranch)).tag(WorktreeBase.defaultBranch)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func baseLabel(_ b: WorktreeBase) -> String {
        switch b {
        case .current:
            return repoCurrentBranch.map { "現在のブランチ (\($0))" } ?? "現在のブランチ"
        case .defaultBranch:
            return repoDefaultBranch.map { "デフォルトブランチ (\($0))" } ?? "デフォルトブランチ"
        }
    }

    private func create() {
        wtError = nil
        let info: WorktreeCreationInfo?
        if mode == .worktree, let repo = repoRoot {
            info = WorktreeCreationInfo(repoRoot: repo, branch: branchName, base: base)
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
