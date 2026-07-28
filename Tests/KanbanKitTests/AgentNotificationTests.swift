import Testing
@testable import KanbanKit

/// 状態遷移 → システム通知の判定。`AgentStateMonitor.apply()` が唯一の呼び出し元。
struct AgentNotificationTests {
    private func d(_ previous: AgentState, _ current: AgentState, viewing: Bool = false) -> AgentNotification.Kind? {
        AgentNotification.decide(previous: previous, current: current, isViewing: viewing)
    }

    // MARK: Done

    @Test func workingToIdleWhileAwayIsDone() {
        #expect(d(.working, .idle) == .done)
    }

    @Test func workingToIdleWhileViewingIsSilent() {
        // 目の前のターミナルで完了を見ている = 通知不要(かつ seen も落ちないので DONE にならない)
        #expect(d(.working, .idle, viewing: true) == nil)
    }

    @Test func unknownToIdleIsSilent() {
        // 起動直後 / resetAgentStates() 直後。working を経ていないので完了ではない
        #expect(d(.unknown, .idle) == nil)
    }

    @Test func idleToIdleIsSilent() {
        // 端末出力のたびに再評価されるが、遷移していないので再通知しない
        #expect(d(.idle, .idle) == nil)
    }

    @Test func blockedToIdleIsSilent() {
        // 承認プロンプトを Esc で消した等。作業完了ではない
        #expect(d(.blocked, .idle) == nil)
    }

    // MARK: Blocked

    @Test func workingToBlockedWhileAwayIsBlocked() {
        #expect(d(.working, .blocked) == .blocked)
    }

    @Test func unknownToBlockedIsBlocked() {
        // 起動直後にいきなり承認待ちになるケース(自動起動 + 初回プロンプト)も拾う
        #expect(d(.unknown, .blocked) == .blocked)
    }

    @Test func blockedToBlockedIsSilent() {
        #expect(d(.blocked, .blocked) == nil)
    }

    @Test func workingToBlockedWhileViewingIsSilent() {
        #expect(d(.working, .blocked, viewing: true) == nil)
    }

    // MARK: その他の遷移は無音

    @Test func blockedToWorkingIsSilent() {
        #expect(d(.blocked, .working) == nil)
    }

    @Test func idleToWorkingIsSilent() {
        #expect(d(.idle, .working) == nil)
    }
}
