import Testing
import Foundation
@testable import KanbanKit

@Suite struct WorktreeForceDeleteParseTests {
    /// porcelain v1 の XY コードが表示グループへ正しく畳まれること。
    /// 分類は安全性の判定ではなく「これは捨てていいゴミか」を即断させるためのグルーピング。
    @Test func classifiesPorcelainCodes() {
        let out = """
        ?? .serena/
        ?? .DS_Store
         M Sources/KanbanKit/WorktreeService.swift
        M  Sources/KanbanTerm/Views/CardView.swift
        MM Sources/KanbanTerm/Views/ColumnView.swift
         D docs/old-note.md
        D  docs/removed.md
        UU Sources/conflict.swift
        """
        let e = WorktreeService.parsePorcelain(out)
        #expect(e.count == 8)
        #expect(e.first(where: { $0.path == ".serena/" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == ".DS_Store" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == "Sources/KanbanKit/WorktreeService.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/CardView.swift" })?.kind == .staged)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/ColumnView.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "docs/old-note.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "docs/removed.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "Sources/conflict.swift" })?.kind == .conflicted)
    }

    /// 未追跡ディレクトリは porcelain が末尾スラッシュ付きで畳んで返す。
    /// UI はこれを「ディレクトリ」として表示し、diff の展開対象にしない。
    @Test func detectsUntrackedDirectory() {
        let e = WorktreeService.parsePorcelain("?? .serena/\n?? scratch.md\n")
        #expect(e[0].isDirectory)
        #expect(!e[1].isDirectory)
    }

    /// rename は "old -> new"。ディスク上に存在する new 側を表示する。
    @Test func renameUsesNewPath() {
        let e = WorktreeService.parsePorcelain("R  docs/a.md -> docs/b.md\n")
        #expect(e.count == 1)
        #expect(e[0].path == "docs/b.md")
        #expect(e[0].kind == .staged)
    }

    /// 日本語パスは `core.quotePath=false` 前提でそのまま通る(エスケープ解除は自前でやらない)。
    @Test func keepsNonASCIIPathAsIs() {
        let e = WorktreeService.parsePorcelain("?? docs/日本語メモ.md\n")
        #expect(e[0].path == "docs/日本語メモ.md")
    }

    /// 空行・末尾改行・XY だけでパスが無い壊れた行は捨てる(クラッシュしない)。
    @Test func ignoresBlankAndMalformedLines() {
        let e = WorktreeService.parsePorcelain("\n?? a.txt\n\n?? \nM\n")
        #expect(e.count == 1)
        #expect(e[0].path == "a.txt")
    }

    /// kind ごとの取り出しヘルパ(UI のセクション分けが使う)。
    @Test func groupsByKind() {
        let p = WorktreeService.DirtyPreview(
            entries: WorktreeService.parsePorcelain("?? a\n?? b/\n M c\n"),
            statusError: nil
        )
        #expect(p.entries(of: .untracked).count == 2)
        #expect(p.entries(of: .modified).count == 1)
        #expect(p.entries(of: .deleted).isEmpty)
        #expect(p.statusError == nil)
    }
}
