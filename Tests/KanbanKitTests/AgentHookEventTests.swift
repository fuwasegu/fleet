import Testing
@testable import KanbanKit

struct AgentHookEventTests {
    @Test func promptSubmitIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "UserPromptSubmit", message: nil) == .working)
    }
    @Test func preToolUseIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "PreToolUse", message: nil) == .working)
    }
    @Test func postToolUseIsWorking() {
        #expect(AgentHookEvent.state(forEventName: "PostToolUse", message: nil) == .working)
    }
    @Test func stopIsIdle() {
        #expect(AgentHookEvent.state(forEventName: "Stop", message: nil) == .idle)
    }
    // Notification は Claude Code の汎用通知チャンネルで、「権限確認」と「アイドル通知」の
    // 両方がここに流れてくる。以前はここを一律 blocked にしていたが、それは完了して1分
    // アイドルになっただけのカードが軒並み Blocked に化ける実バグだった(v0.12.0 で混入)。
    @Test func notificationWaitingForInputIsIgnored() {
        // 実際に captured した Notification hook payload の message(verbatim)。
        #expect(AgentHookEvent.state(forEventName: "Notification", message: "Claude is waiting for your input") == nil)
    }
    @Test func notificationPermissionIsBlocked() {
        #expect(AgentHookEvent.state(forEventName: "Notification", message: "Claude needs your permission to use Bash") == .blocked)
    }
    @Test func notificationWithoutMessageIsIgnored() {
        #expect(AgentHookEvent.state(forEventName: "Notification", message: nil) == nil)
    }
    @Test func permissionRequestIsBlocked() {
        // 実測では発火しなかったイベントだが、配線は仕様どおり blocked を返す。
        #expect(AgentHookEvent.state(forEventName: "PermissionRequest", message: nil) == .blocked)
    }
    @Test func sessionEndIsUnknown() {
        #expect(AgentHookEvent.state(forEventName: "SessionEnd", message: nil) == .unknown)
    }
    @Test func unknownEventNameReturnsNil() {
        #expect(AgentHookEvent.state(forEventName: "SomeFutureEvent", message: nil) == nil)
        #expect(AgentHookEvent.state(forEventName: "", message: nil) == nil)
    }
}
