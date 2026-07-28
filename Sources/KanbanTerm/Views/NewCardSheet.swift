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

    /// (title, workingDirPath?, autoStartAgent, dangerSkip, agentKind, claudeProfileID?)
    /// worktree を伴わない(フォルダ紐づけ or 何もなし)カード作成。同期・即座に完了するため
    /// スピナーは出さない。カード作成が失敗した場合は throw する。呼び出し側はエラーを
    /// シートの `wtError` に反映させ、シートを閉じない。claudeProfileID は Claude Code 選択時に
    /// ピッカーで選んだ `ClaudeProfile.id`(既定=nil)。
    let onCreate: (String, String?, Bool, Bool, AgentKind, UUID?) throws -> Void

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
    /// `creating` 中に見せるラベル。fetch フェーズと create フェーズの2状態のみ
    /// (それ以上の粒度は不要)。
    @State private var creatingLabel = "worktree を作成中…"
    /// ベースを origin から最新化してから作成するか(既定 ON)。ローカルの `main` が
    /// origin より遅れているのが常態なので、デフォルトで安全な方(最新化する)を選ぶ。
    @State private var refreshBase = true
    /// fetch が(リモート無し/失敗/リモートにブランチ無し等で)ローカルへフォールバックした
    /// 場合の理由。カード自体は作成済みだが、ベースが陳腐化している可能性があることを
    /// ユーザーが見落とさないよう、成功後もシートを閉じずにこの警告を表示し続ける
    /// (トースト等の自動消滅する通知だと見逃されるため、明示的に閉じる操作を要求する)。
    @State private var wtNote: String?
    /// worktree 作成時、実際にどの ref をベースにしたか(origin/main など)。
    /// リモートを使えた場合のみ設定し、作成中の予測パス表示に添える。
    @State private var effectiveBaseRef: String?

    /// 選択中の Claude プロファイル(nil = 既定 `~/.claude`)。Claude Code 選択時のみ表示。
    @State private var selectedProfileID: UUID?
    @State private var profiles: [ClaudeProfile] = []
    @State private var managingProfiles = false

    private func reloadProfiles() {
        profiles = (try? store.profiles()) ?? []
        if let id = selectedProfileID, !profiles.contains(where: { $0.id == id }) {
            selectedProfileID = nil   // 削除された場合は既定にフォールバック
        }
    }

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
        return WorktreeService.worktreePath(repoRoot: directory, branch: branchName, baseDir: WorktreeService.defaultWorktreeBaseDir)
    }

    /// 予測パスのキャプション。実際に origin から最新化できた場合、作成中/作成直後に
    /// 実際使ったベース ref (`origin/main` 等)を添えてユーザーに伝える。
    private var predictedPathCaption: String {
        if let effectiveBaseRef {
            return "→ \(predictedWorktreePath) (\(effectiveBaseRef) から作成)"
        }
        return "→ \(predictedWorktreePath)"
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

            if kind == .claude {
                claudeProfileFields
            }

            // カードを開くと Agent は自動起動・自動復帰するので、起動トグルは廃止。
            Toggle("権限確認をスキップ (自動承認)", isOn: $danger)

            if let wtError {
                Text(wtError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // カードは作成済みだが、ベース最新化がフォールバックした(陳腐化しうるローカル
            // ブランチから作成された)ことを示す警告。トースト等の自動で消える通知にはしない:
            // ユーザーがこの警告に気づかず陳腐化したベースで作業を続けるのを防ぐため、
            // シートを自動で閉じずにこの警告を残し、明示的な「閉じる」操作を要求する。
            if let wtNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(wtNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if creating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(creatingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if wtNote != nil {
                    // カード作成は既に完了している。残す操作は「警告を読んで閉じる」のみ。
                    Button("閉じる") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
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
            reloadProfiles()
        }
        .onChange(of: title) { _, newValue in
            guard !branchEditedByUser else { return }
            branchName = WorktreeService.sanitizeBranch(newValue)
        }
        .sheet(isPresented: $managingProfiles, onDismiss: reloadProfiles) {
            ManageProfilesSheet(store: store)
        }
    }

    private var claudeProfileFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude プロファイル").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("管理…") { managingProfiles = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Picker("Claude プロファイル", selection: $selectedProfileID) {
                Text("既定 (~/.claude)").tag(UUID?.none)
                ForEach(profiles) { profile in
                    Text(profile.label).tag(Optional(profile.id))
                }
            }
            .labelsHidden()
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

                    Toggle("ベースを最新化してから作成 (git fetch)", isOn: $refreshBase)
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("新ブランチ名").font(.caption).foregroundStyle(.secondary)
                        TextField("新ブランチ名", text: $branchName)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: branchName) { _, _ in branchEditedByUser = true }
                    }

                    Text(predictedPathCaption)
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
        wtNote = nil
        effectiveBaseRef = nil
        if makeWorktree, let dir = directory, isGitRepo {
            createWithWorktree(repoRoot: dir, branch: branchName, baseRef: baseBranch)
        } else {
            do {
                try onCreate(resolvedTitle, directory, true, danger, kind,
                              kind == .claude ? selectedProfileID : nil)
                dismiss()
            } catch let error as WorktreeService.GitError {
                wtError = error.message
            } catch {
                wtError = error.localizedDescription
            }
        }
    }

    /// worktree 作成(ベース最新化の `git fetch` + `git worktree add`、git-lfs チェックアウトで
    /// 数秒かかりうる)をメインスレッド外で実行し、その間 `creating` でスピナー表示・ボタン
    /// 無効化する。git 呼び出しは `Task.detached` でバックグラウンド実行し(`WorktreeService`
    /// は nonisolated な値型引数のみを取るので安全)、完了後の `await` 以降はこのビュー
    /// (MainActor)に戻ってから SwiftData のカード作成・worktree 紐づけを行う。worktree 作成を
    /// カード作成より先に行う順序は維持する(git 失敗時に孤児カードを残さないため)。
    ///
    /// フェーズは2段: まず `resolveFreshBase` (トグル ON なら origin から fetch) でベース ref を
    /// 決め、それから `create` で実際に worktree を掘る。ラベルは "最新化しています…" →
    /// "worktree を作成中…" の2状態のみ切り替える(それ以上の粒度は過剰)。
    private func createWithWorktree(repoRoot: String, branch: String, baseRef: String) {
        creating = true
        creatingLabel = refreshBase ? "最新化しています…" : "worktree を作成中…"
        let title = resolvedTitle
        let dangerSkip = danger
        let agentKind = kind
        let profileID = agentKind == .claude ? selectedProfileID : nil
        let fetch = refreshBase
        Task {
            do {
                let resolved = await Task.detached(priority: .userInitiated) {
                    WorktreeService.resolveFreshBase(repoRoot: repoRoot, base: baseRef, fetch: fetch)
                }.value

                creatingLabel = "worktree を作成中…"
                if resolved.usedRemote { effectiveBaseRef = resolved.ref }

                let path = try await Task.detached(priority: .userInitiated) {
                    try WorktreeService.create(
                        repoRoot: repoRoot, branch: branch, baseRef: resolved.ref,
                        baseDir: WorktreeService.defaultWorktreeBaseDir
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
                if let profileID, let profile = try store.profiles().first(where: { $0.id == profileID }) {
                    try store.setCardProfile(card, profile: profile)
                }
                creating = false
                if let note = resolved.note {
                    // カードは既に作成済み。ベースが陳腐化しうるローカルブランチへフォールバック
                    // したことをユーザーが見落とさないよう、シートは閉じずに警告を出したままにする
                    // (ユーザーが「閉じる」を押すまで残る = 自動消滅する通知より確実に気づかせる)。
                    wtNote = note
                } else {
                    dismiss()
                }
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
