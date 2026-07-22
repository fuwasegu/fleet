import SwiftUI
import SwiftData
import Darwin
import KanbanKit

/// A2A の常駐プリミティブ。各チャンネルの `~/.fleet/channels/<id>/` を監視し、
/// Agent がファイルに書いたもの(outbox の有向メッセージ / status の作業申告)を
/// 読んで Fleet 本体側で作用させる — これが「共有 dead-drop」を「協調する Agent 群」に変える。
///
/// - outbox.jsonl の有向メッセージ → 宛先カードの live セッションへ term.send で注入(push 配信)。
///   宛先が idle のときだけ注入し、作業中/blocked のものは次の idle 遷移で流す。
/// - peers.json を状態変化に追従させ、fleet_peers を live-aware に保つ。
@MainActor
@Observable
final class A2AChannelHub {
    private var watchers: [UUID: any DispatchSourceFileSystemObject] = [:]
    private var debounce: [UUID: Task<Void, Never>] = [:]
    private weak var sessions: TerminalSessions?
    private var context: ModelContext?
    private weak var uiState: BoardUIState?

    func configure(sessions: TerminalSessions, context: ModelContext, uiState: BoardUIState) {
        self.sessions = sessions
        self.context = context
        self.uiState = uiState
        // Agent が idle/状態変化したら該当チャンネルを処理(peers 更新 + キュー配信)。
        sessions.onCardStateChange = { [weak self] cardID in self?.noteStateChange(cardID) }
    }

    /// 現在のチャンネル集合に watcher を合わせる。接続/解除で呼ぶ(冪等)。
    func sync(channelIDs: [UUID]) {
        let ids = Set(channelIDs)
        for (id, w) in watchers where !ids.contains(id) { w.cancel(); watchers[id] = nil }
        for id in ids where watchers[id] == nil { startWatch(id) }
        for id in ids { schedule(id) }   // 初回/再同期時に一度処理
    }

    private func noteStateChange(_ cardID: UUID) {
        guard let context, let chID = BoardStore(context: context).card(withID: cardID)?.channel?.id else { return }
        schedule(chID)
    }

    private func startWatch(_ id: UUID) {
        let dir = ChannelStore.dir(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.schedule(id) }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[id] = src
    }

    /// 監視イベントはまとめて弾けるので 150ms デバウンスしてから処理する。
    private func schedule(_ id: UUID) {
        debounce[id]?.cancel()
        debounce[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.process(id)
        }
    }

    private func process(_ channelID: UUID) {
        guard let context else { return }
        let store = BoardStore(context: context)
        store.applyBoardIntents(for: channelID)                 // Agent の盤面操作(create/move)を適用
        if let ch = store.channel(withID: channelID) { store.syncChannel(ch) }  // peers を live 同期
        store.writeBoardSnapshot(for: channelID)                // fleet_board 用スナップショット
        deliverOutbox(channelID, store: store)                  // outbox の push 配信
    }

    private func deliverOutbox(_ channelID: UUID, store: BoardStore) {
        let messages = ChannelStore.outbox(for: channelID)
        guard !messages.isEmpty else { return }

        // 宛先カード毎に配信済み集合を1回だけ読む
        var deliveredCache: [UUID: Set<String>] = [:]
        var stillPending: Set<UUID> = []

        for m in messages {
            guard let toID = resolveTarget(m, channelID: channelID, store: store) else { continue }
            var delivered = deliveredCache[toID] ?? ChannelStore.deliveredIDs(cardID: toID, channelID: channelID)
            if delivered.contains(m.id) { deliveredCache[toID] = delivered; continue }

            guard let card = store.card(withID: toID) else { continue }
            let ready = sessions?.hasSession(toID) == true && card.agentState == .idle
            if ready {
                let line = Self.frame(m)
                if sessions?.inject(line, into: toID) == true {
                    delivered.insert(m.id)
                    deliveredCache[toID] = delivered
                    ChannelStore.writeDelivered(delivered, cardID: toID, channelID: channelID)
                }
            } else {
                // まだ配信できない(未起動 or 作業中/blocked)。次の idle 遷移で再試行。
                stillPending.insert(toID)
                deliveredCache[toID] = delivered
            }
        }
        // 封筒バッジ: 未配信が残っているカードを uiState に反映
        if let uiState {
            for id in stillPending { uiState.pendingMessageCardIDs.insert(id) }
            // すべて配信済みになったカードはバッジを消す
            let resolved = uiState.pendingMessageCardIDs.subtracting(stillPending)
            for id in resolved { uiState.pendingMessageCardIDs.remove(id) }
        }
    }

    /// メッセージの宛先カード id を解決する。toID があればそれ、無ければチャンネル内で名前一致。
    private func resolveTarget(_ m: OutboxMessage, channelID: UUID, store: BoardStore) -> UUID? {
        if let toID = m.toID, let uuid = UUID(uuidString: toID) { return uuid }
        guard let ch = store.channel(withID: channelID) else { return nil }
        let target = m.to.lowercased()
        return ch.cards.first { $0.title.lowercased() == target && $0.id.uuidString != m.fromID }?.id
    }

    /// 注入する1行。provenance を明示し、複数行は1行に畳む(改行=送信になるため)。
    private static func frame(_ m: OutboxMessage) -> String {
        let kind = m.kind == "handoff" ? "handoff" : "message"
        let body = m.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "[A2A \(kind) from \(m.from)] \(body)"
    }
}
