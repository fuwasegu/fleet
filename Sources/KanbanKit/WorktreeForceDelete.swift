import Foundation

// 差分を確認したうえでの worktree 強制削除。
//
// `WorktreeService.removeSafely` は risk == .clean 以外を必ず拒否するが、`git status --porcelain`
// は `.serena/` のような未追跡ゴミも dirty として報告するため、それ1つで削除ルートが完全に塞がる
// (= 「安全のために何もしない」だけが成立し、許されるべき結末に到達できない)。
//
// ここが提供するのは、捨てられる差分を提示する `dirtyPreview` / `fileDiff` と、それを見たうえで
// 実行する `removeForcibly`。「差分を見せてから捨てる」の担保は UI 層(WorktreeForceDeleteSheet を
// 通らないと removeForcibly に到達しない)にあり、この層が守るのは
// 「使用中は消さない」「ブランチ ref は消さない」の2点だけ。
// 詳細は docs/superpowers/specs/2026-07-30-worktree-force-delete-design.md と
// worktree_force_delete.fsl を参照。
extension WorktreeService {
    /// 強制削除で捨てられるものの一覧。レビュー用ではなく「これは捨てていいゴミか」の即断用に絞る。
    public struct DirtyPreview: Sendable {
        public struct Entry: Sendable, Identifiable, Equatable {
            /// 表示グルーピングの単位。porcelain の XY コードをユーザー向けに畳んだもの。
            public enum Kind: Sendable, Equatable {
                case conflicted, deleted, staged, modified, untracked
            }

            public let kind: Kind
            public let path: String
            /// porcelain の XY 2文字。分類の根拠を UI/デバッグで示せるよう保持する。
            public let code: String

            public var id: String { path }

            /// porcelain は未追跡ディレクトリを "dir/" と末尾スラッシュ付きで1行に畳んで返す。
            /// これが true の行は diff の展開対象にしない(中身は git が追跡していない)。
            public var isDirectory: Bool { path.hasSuffix("/") }

            public init(kind: Kind, path: String, code: String) {
                self.kind = kind
                self.path = path
                self.code = code
            }
        }

        public let entries: [Entry]
        /// `git status` 自体が失敗した場合のみ非nil(index.lock 競合など)。
        /// このとき entries は空で、UI は「中身を確認せずに削除する」警告へ切り替える。
        public let statusError: String?

        public init(entries: [Entry], statusError: String? = nil) {
            self.entries = entries
            self.statusError = statusError
        }

        public func entries(of kind: Entry.Kind) -> [Entry] {
            entries.filter { $0.kind == kind }
        }
    }

    /// `git status --porcelain` (v1) の出力を表示用エントリへ分類する純関数。
    ///
    /// 優先順位: untracked(`??`) > conflicted(X/Y に U、または AA/DD) > deleted(D を含む) >
    /// staged(Y が空白 = worktree 側は変更なし) > modified。
    /// これは安全性の判定ではなく、リストのグルーピングのための分類。
    public static func parsePorcelain(_ s: String) -> [DirtyPreview.Entry] {
        s.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let raw = String(line)
            // "XY path" — XY は必ず2文字、続く1文字は区切りの空白。それより短い行は壊れているので捨てる。
            guard raw.count > 3 else { return nil }
            let code = String(raw.prefix(2))
            var path = String(raw.dropFirst(3))
            // rename/copy は "old -> new"。今ディスクにあるのは new 側なのでそちらを表示する。
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            guard !path.isEmpty else { return nil }
            guard let x = code.first, let y = code.last else { return nil }

            let kind: DirtyPreview.Entry.Kind
            if code == "??" {
                kind = .untracked
            } else if x == "U" || y == "U" || code == "AA" || code == "DD" {
                kind = .conflicted
            } else if x == "D" || y == "D" {
                kind = .deleted
            } else if y == " " {
                kind = .staged
            } else {
                kind = .modified
            }
            return DirtyPreview.Entry(kind: kind, path: path, code: code)
        }
    }
}
