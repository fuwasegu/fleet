import Testing
@testable import KanbanKit

struct AgentHookEventTests {
    @Test func promptSubmitIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "UserPromptSubmit") == .working)
    }
    @Test func preToolUseIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "PreToolUse") == .working)
    }
    @Test func postToolUseIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "PostToolUse") == .working)
    }
    @Test func stopIsIdle() {
        #expect(AgentHookEvent.state(forEventName: "Stop") == .idle)
    }
    @Test func notificationIsBlocked() {
        #expect(AgentHookEvent.state(forEventName: "Notification") == .blocked)
    }
    @Test func permissionRequestIsBlocked() {
        // 実測では発火しなかったイベントだが、配線は仕様どおり blocked を返す。
        #expect(AgentHookEvent.state(forEventName: "PermissionRequest") == .blocked)
    }
    @Test func sessionEndIsUnknown() {
        #expect(AgentHookEvent.state(forEventName: "SessionEnd") == .unknown)
    }
    @Test func unknownEventNameReturnsNil() {
        #expect(AgentHookEvent.state(forEventName: "SomeFutureEvent") == nil)
        #expect(AgentHookEvent.state(forEventName: "") == nil)
    }
}
