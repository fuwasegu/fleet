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
    /// channelID ごとの「処理中」フラグ。`applyWorktreeIntentsAsync` は git 呼び出しを挟んで
    /// await するため、同じチャンネルに対するファイル監視イベントが重なって並行実行されると
    /// 同一 intent を二重に読む/適用済み集合の書き込みが競合する恐れがある。処理中は次のイベントを
    /// 素通りさせず、完了後に取りこぼしを検知した場合のみ 1 回だけ再処理する(冪等性の保護)。
    private var processing: Set<UUID> = []
    private var pendingReprocess: Set<UUID> = []
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
        // C1 緩和: binding.json の自己改竄をここ(起動時/接続/解除。ファイル監視イベント毎では
        // ない=コスト低)で真実へ強制的に戻す。件数はカード数程度なので毎回呼んでも安価。
        if let context { BoardStore(context: context).reconcileBindings() }
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
    /// `process` は git 呼び出し(worktree intent 適用)を含み await するので、ここから直接
    /// 呼ばずに `Task { }` へ切り出す(呼び出し元の同期コンテキストを塞がないため)。
    private func schedule(_ id: UUID) {
        debounce[id]?.cancel()
        debounce[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.process(id)
        }
    }

    private func process(_ channelID: UUID) async {
        // in-flight ガード: 同じチャンネルへの処理が既に進行中なら、二重実行(intent の
        // 二重適用/適用済み集合の競合書き込み)を避けて素通りさせる。ただしその間にも
        // watcher イベントが来ている可能性があるので、完了後にもう一度だけ再処理する
        // (取りこぼし防止。単なる早期 return だと、処理中に届いた新しい intent が
        // 次のイベントを待つまで永遠に処理されないままになる)。
        guard !processing.contains(channelID) else {
            pendingReprocess.insert(channelID)
            return
        }
        processing.insert(channelID)
        await runOnce(channelID)
        processing.remove(channelID)
        if pendingReprocess.remove(channelID) != nil {
            await process(channelID)
        }
    }

    private func runOnce(_ channelID: UUID) async {
        guard let context else { return }
        let store = BoardStore(context: context)
        store.applyBoardIntents(for: channelID)                      // Agent の盤面操作(create/move)を適用
        await store.applyWorktreeIntentsAsync(for: channelID)         // Agent の worktree 作成 intent を適用(git は MainActor 外)
        if let ch = store.channel(withID: channelID) { store.syncChannel(ch) }  // peers を live 同期
        store.writeBoardSnapshot(for: channelID)                // fleet_board 用スナップショット(worktree 反映)
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
    /// どちらの経路でも、宛先は必ず `channelID` に所属するカードに限定する(他チャンネル/無関係カードへの
    /// 注入を防ぐ)。自分自身への送信も除外する。
    private func resolveTarget(_ m: OutboxMessage, channelID: UUID, store: BoardStore) -> UUID? {
        guard let ch = store.channel(withID: channelID) else { return nil }
        if let toID = m.toID, let uuid = UUID(uuidString: toID) {
            return ch.cards.first { $0.id == uuid && $0.id.uuidString != m.fromID }?.id
        }
        let target = m.to.lowercased()
        return ch.cards.first { $0.title.lowercased() == target && $0.id.uuidString != m.fromID }?.id
    }

    /// 注入する1行。provenance を明示し、複数行は1行に畳む(改行=送信になるため)。
    /// body/送信者名はいずれも Agent 制御下のテキストなので、ANSI/OSC エスケープ注入や
    /// 偽装 prefix を防ぐため必ずサニタイズ・長さ制限を通す。
    private static func frame(_ m: OutboxMessage) -> String {
        let kind = m.kind == "handoff" ? "handoff" : "message"
        let from = ChannelStore.sanitizeForTerminal(m.from, maxLength: 60)
        let body = ChannelStore.sanitizeForTerminal(m.text)
        return "[A2A \(kind) from \(from)] \(body)"
    }
}
