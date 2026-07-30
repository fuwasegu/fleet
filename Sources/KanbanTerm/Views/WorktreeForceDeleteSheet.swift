import SwiftUI
import KanbanKit

/// 捨てられる差分を確認したうえで Fleet 所有 worktree を強制削除するシート。
///
/// `risk == .dirty` のときだけ到達する。**このシートを通らずに `removeForcibly` は呼ばれない**
/// — 「差分を見せずに未コミット変更を捨てない」という不変条件を担保しているのは、
/// サービス層のガードではなくこのシートの存在そのもの(worktree_force_delete.fsl の
/// NeverDiscardUncommittedWithoutReview に対応)。
///
/// 表示方針: 判断に必要なのは diff の精読ではなく「これは捨てていいゴミか」の即断なので、
/// 種類別のグルーピングと件数を主役にし、**未追跡は既定で畳む**(ゴミの大半がそこに来るため、
/// 畳んでおけば本命の modified が最初から目に入る)。diff 本文は行を開いたときだけ遅延ロードする。
struct WorktreeForceDeleteSheet: View {
    let worktreePath: String
    /// 「ブランチ <名前> は残る」と示すための表示名。
    let branchLabel: String
    /// 「破棄して削除」が押された。実際の削除は呼び出し側(CardView)が行う。
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var preview: WorktreeService.DirtyPreview?
    @State private var loading = true
    @State private var untrackedExpanded = false

    /// tracked 側のセクション(既定で展開)。未追跡だけ別扱いにする。
    private static let trackedKinds: [(WorktreeService.DirtyPreview.Entry.Kind, String)] = [
        (.conflicted, "衝突"),
        (.modified, "変更"),
        (.staged, "ステージ済み"),
        (.deleted, "削除"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            warningBand
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .task { await loadPreview() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("差分を確認して worktree を強制削除")
                .font(.headline)
            Text(worktreePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// 何が失われ、何が失われないかを最初に言い切る。
    /// statusError のときは「中身を確認せずに削除する」ことを隠さない。
    private var warningBand: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(warningText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }

    /// `Text` は String 変数を渡すと Markdown を解釈しないので、強調は記法ではなく語順で作る
    /// (先頭に危険側を置く)。
    private var warningText: String {
        if preview?.statusError != nil {
            return "中身を確認せずに削除します — 差分を取得できませんでした。ブランチ「\(branchLabel)」は残るのでコミットは失われません。"
        }
        return "未コミットの変更と未追跡ファイルは復元できません。ブランチ「\(branchLabel)」は残るのでコミットは失われません。"
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("差分を確認中…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = preview, let err = p.statusError {
            statusErrorPane(err)
        } else if let p = preview, p.entries.isEmpty {
            // 確認ダイアログを出した後に別プロセスが片付けた等。空を空として見せる。
            Text("捨てられる差分はありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = preview {
            fileList(p)
        }
    }

    private func statusErrorPane(_ message: String) -> some View {
        VStack(spacing: 9) {
            Text("差分を取得できませんでした")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Button("再試行") { Task { await loadPreview() } }
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileList(_ p: WorktreeService.DirtyPreview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.trackedKinds, id: \.1) { kind, label in
                    let entries = p.entries(of: kind)
                    if !entries.isEmpty {
                        sectionHeader(label, count: entries.count)
                        ForEach(entries) { entry in
                            DiffRow(worktreePath: worktreePath, entry: entry)
                                .padding(.leading, 10)
                        }
                    }
                }
                let untracked = p.entries(of: .untracked)
                if !untracked.isEmpty {
                    DisclosureGroup(isExpanded: $untrackedExpanded) {
                        ForEach(untracked) { entry in
                            HStack(spacing: 7) {
                                Text(entry.code)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.orange)
                                Text(entry.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                if entry.isDirectory {
                                    Text("ディレクトリ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 1)
                            .padding(.leading, 20)
                        }
                    } label: {
                        HStack {
                            Text("未追跡").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(untracked.count) 件").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold))
            Spacer()
            Text("\(count) 件").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            Text("`.gitignore` 対象のファイル(`.build/` など)も worktree ごと削除されます")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("キャンセル") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("破棄して削除") {
                dismiss()
                onConfirm()
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            // 差分を見る前に押せてしまわないよう、プレビューの解決まで無効化する。
            .disabled(loading)
        }
        .padding(12)
    }

    // MARK: - Loading

    /// `git status` は数千件の未追跡を返すこともあるので MainActor では走らせない。
    private func loadPreview() async {
        loading = true
        let wt = worktreePath
        let p = await Task.detached(priority: .userInitiated) {
            WorktreeService.dirtyPreview(worktreePath: wt)
        }.value
        preview = p
        loading = false
    }
}

/// tracked な1ファイルの行。開いたときに初めて diff を取りに行く。
private struct DiffRow: View {
    let worktreePath: String
    let entry: WorktreeService.DirtyPreview.Entry

    /// 巨大 diff をそのまま流し込むと描画が固まるので、表示行数に上限を置く。
    /// 「捨てていいか」の判断に必要なのは冒頭なので、続きはターミナルで見ればよい。
    private static let maxLines = 400

    @State private var expanded = false
    @State private var diff: String?
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            diffBody
                .padding(.leading, 14)
                .padding(.top, 3)
        } label: {
            HStack(spacing: 7) {
                Text(entry.code)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color)
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .onChange(of: expanded) { _, now in
            if now, diff == nil, loadError == nil, !loading { load() }
        }
    }

    private var color: Color {
        switch entry.kind {
        case .conflicted: return .purple
        case .deleted: return .red
        case .staged: return .green
        case .modified: return .blue
        case .untracked: return .orange
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if let e = loadError {
            Text("diff を取得できませんでした: \(e)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let d = diff {
            let lines = d.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Self.lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.count > Self.maxLines {
                    Text("… 以下 \(lines.count - Self.maxLines) 行省略")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .textSelection(.enabled)
            .padding(6)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private static func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("@@") { return .purple }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .secondary
    }

    private func load() {
        loading = true
        let wt = worktreePath, p = entry.path
        Task {
            let result: Result<String, WorktreeService.GitError> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try WorktreeService.fileDiff(worktreePath: wt, path: p))
                } catch let e as WorktreeService.GitError {
                    return .failure(e)
                } catch {
                    return .failure(WorktreeService.GitError(message: "\(error)"))
                }
            }.value
            loading = false
            switch result {
            case .success(let d):
                diff = d.isEmpty ? "(テキスト差分なし — バイナリ、または権限/改行のみの変更)" : d
            case .failure(let e):
                loadError = e.message
            }
        }
    }
}
