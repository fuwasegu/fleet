import Testing
import SwiftData
@testable import KanbanKit

@MainActor
struct WorktreeBindingTests {

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    @Test func setAndClearWorktree() throws {
        let store = try makeStore()
        let column = try store.addColumn(name: "作業中")
        let card = try store.addCard(title: "t", to: column, agentKind: .claude)

        try store.setWorktree(card, repoRoot: "/repo", worktreePath: "/repo/../.fleet-worktrees/x", branch: "x", fleetOwned: true)
        #expect(card.repoRoot == "/repo")
        #expect(card.worktreePath == "/repo/../.fleet-worktrees/x")
        #expect(card.branch == "x")
        #expect(card.isFleetOwnedWorktree == true)
        #expect(card.effectiveCwd == "/repo/../.fleet-worktrees/x")

        try store.clearWorktree(card)
        #expect(card.worktreePath == nil)
        #expect(card.repoRoot == nil)
        #expect(card.isFleetOwnedWorktree == false)
    }
}
