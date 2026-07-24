import Foundation
import Testing
import SwiftData
@testable import KanbanKit

@MainActor
struct ClaudeProfileTests {

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    @Test func addProfileAssignsIncreasingOrder() throws {
        let store = try makeStore()
        let a = try store.addProfile(label: "会社", configDirPath: "/Users/x/.claude-work")
        let b = try store.addProfile(label: "個人", configDirPath: "/Users/x/.claude-personal")
        #expect(a.order == 0)
        #expect(b.order == 1)
        let all = try store.profiles()
        #expect(all.count == 2)
        #expect(all.map(\.label) == ["会社", "個人"])
    }

    @Test func profilesAreOrderedByOrderThenLabel() throws {
        let store = try makeStore()
        _ = try store.addProfile(label: "Zeta", configDirPath: "/z")
        _ = try store.addProfile(label: "Alpha", configDirPath: "/a")
        let all = try store.profiles()
        #expect(all.map(\.label) == ["Zeta", "Alpha"])   // order 昇順が優先
    }

    @Test func updateProfileChangesLabelAndPath() throws {
        let store = try makeStore()
        let p = try store.addProfile(label: "会社", configDirPath: "/old")
        try store.updateProfile(p, label: "会社2", configDirPath: "/new")
        #expect(p.label == "会社2")
        #expect(p.configDirPath == "/new")
    }

    @Test func setCardProfileAssignsAndClears() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let card = try store.addCard(title: "task", to: col)
        let profile = try store.addProfile(label: "会社", configDirPath: "/Users/x/.claude-work")

        try store.setCardProfile(card, profile: profile)
        #expect(card.claudeProfile?.label == "会社")

        try store.setCardProfile(card, profile: nil)
        #expect(card.claudeProfile == nil)
    }

    /// 安全性: プロファイル削除は割り当てカードを消さない(nullify、cascade ではない)。
    @Test func deletingAssignedProfileNullifiesCardWithoutDeletingIt() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let card = try store.addCard(title: "task", to: col)
        let profile = try store.addProfile(label: "会社", configDirPath: "/Users/x/.claude-work")
        try store.setCardProfile(card, profile: profile)
        #expect(card.claudeProfile != nil)

        try store.deleteProfile(profile)

        // カードは残っている(コラム経由でも取得できる)。
        #expect(try store.card(withID: card.id) != nil)
        #expect(col.cards.contains { $0.id == card.id })
        #expect(card.claudeProfile == nil)
        #expect(try store.profiles().isEmpty)
    }
}
