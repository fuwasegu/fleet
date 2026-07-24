import Testing
@testable import KanbanKit

@Suite struct WorktreeServiceLogicTests {
    @Test func sanitize() {
        #expect(WorktreeService.sanitizeBranch("Fix: login bug!!") == "Fix-login-bug")
        #expect(WorktreeService.sanitizeBranch("  --a//b-- ") == "a/b")
        #expect(WorktreeService.sanitizeBranch("") == "work")
    }
    @Test func pathUnderFleetWorktrees() {
        let p = WorktreeService.worktreePath(repoRoot: "/Users/me/proj", branch: "feature/x", baseDir: "../.fleet-worktrees")
        #expect(p == "/Users/me/.fleet-worktrees/feature/x")
    }
    @Test func removalPriority() {
        #expect(WorktreeService.classifyRemoval(porcelain: " M a", aheadCount: 0, mergedIntoDefault: true, inUse: false) == .dirty)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 2, mergedIntoDefault: false, inUse: false) == .unpushed)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 0, mergedIntoDefault: true, inUse: false) == .clean)
        #expect(WorktreeService.classifyRemoval(porcelain: " M a", aheadCount: 0, mergedIntoDefault: true, inUse: true) == .inUse)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 0, mergedIntoDefault: false, inUse: false) == .unpushed)
    }
}
