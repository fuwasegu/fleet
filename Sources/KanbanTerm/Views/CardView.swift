import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import KanbanKit

/// Prompt デザイン(Claude Design 案C)のトークン。
/// カードは「机の上のターミナル窓」= システム外観に依らずダーク固定。
enum PromptTheme {
    static let surface = Color(hex: "171B1B")!   // カード地
    static let text    = Color(hex: "CBCDD4")!   // 主テキスト
    static let muted   = Color(hex: "6A7078")!   // 補助 / 記号
    static let ok      = Color(hex: "7FD962")!   // 稼働
    static let blocked = Color(hex: "E54B4D")!   // 承認待ち
    static let done    = Color(hex: "F5A623")!   // 完了・未読(注意を引く琥珀)
    static let mono    = Font.system(size: 12, design: .monospaced)
}

/// Agent 状態 → 先頭グリフ / タグ / 状態語 / 色。色は Blocked(赤)と 稼働・完了(緑)のみ、他は無彩色。
struct AgentStatusStyle {
    let glyph: String     // ● ◐ ✓ ○
    let tag: String       // BLOCKED / WORKING / DONE / IDLE / READY
    let status: String    // タグ右の補助語(承認待ち / 未読 など)
    let color: Color      // グリフ+タグの色
    let spin: Bool        // WORKING グリフを回す
    let ping: Bool        // レーダーのブリップ(リングが広がる) = 稼働/承認待ち
    let showQuestion: Bool // Blocked のみ、実際の問い + 点滅キャレット行

    init(card: Card) {
        if card.isDone {
            glyph = "✓"; tag = "DONE"; status = String(localized: "未読"); color = PromptTheme.done; spin = false; ping = true; showQuestion = false
            return
        }
        switch card.agentState {
        case .working:
            glyph = "◐"; tag = "WORKING"; status = "";        color = PromptTheme.ok;      spin = true;  ping = true;  showQuestion = false
        case .blocked:
            glyph = "●"; tag = "BLOCKED"; status = String(localized: "承認待ち"); color = PromptTheme.blocked; spin = false; ping = true;  showQuestion = true
        case .idle:
            glyph = "○"; tag = "IDLE";    status = "";        color = PromptTheme.muted;   spin = false; ping = false; showQuestion = false
        case .unknown:
            glyph = "○"; tag = "READY";   status = "";        color = PromptTheme.muted;   spin = false; ping = false; showQuestion = false
        }
    }
}

/// カードの見た目(ドラッグ中のオーバーレイでも再利用する非依存ビュー)。
/// 行構成: `● [TAG] 状態語` → タイトル → `cwd on branch ▸` → (Blockedのみ)`$ 問い ▏` → ターミナルを開く
struct CardFace: View {
    let card: Card
    var showActions: Bool = false
    var hasPendingMessage: Bool = false   // A2A: 未配信メッセージが溜まっている(封筒バッジ)
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onOpenTerminal: () -> Void = {}
    var onChannelTap: () -> Void = {}
    /// プロンプト行のホバー。active は "board" 座標のカーソル位置、nil で解除。
    var onPromptHover: (CGPoint?) -> Void = { _ in }

    var body: some View {
        let style = AgentStatusStyle(card: card)
        let blocked = style.tag == "BLOCKED"
        let done = style.tag == "DONE"

        VStack(alignment: .leading, spacing: 8) {
            // 状態行
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusGlyph(glyph: style.glyph, color: style.color, spin: style.spin, ping: style.ping)
                Text("[\(style.tag)]").foregroundStyle(style.color)
                if !style.status.isEmpty {
                    Text(style.status).foregroundStyle(PromptTheme.muted)
                }
                Text(card.agentKind.rawValue)   // claude / codex を常に表示
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(PromptTheme.muted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(PromptTheme.text.opacity(0.08), in: Capsule())
                Spacer(minLength: 4)
                if showActions {
                    Button(action: onEdit) { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PromptTheme.muted)
                        .help("カード名を編集")
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PromptTheme.muted)
                        .help("カードを削除")
                }
            }
            .font(PromptTheme.mono.weight(.semibold))

            // タイトル(唯一の自由入力 = 唯一のプロポーショナル体)
            Text(card.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PromptTheme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // プロンプト行: cwd on branch ▸   (右端に PR 番号)
            promptLine

            // A2A: 所属チャンネル(共有メモリ)のバッジ。タップで共有メモリを開く。
            if let ch = card.channel {
                let color = Color(hex: ch.colorHex ?? "") ?? PromptTheme.ok
                HStack(spacing: 6) {
                    Button(action: onChannelTap) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text(ch.name).lineLimit(1).truncationMode(.tail)
                        }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(color.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("共有メモリを開く")

                    if hasPendingMessage {
                        // 宛先が作業中/未起動でまだ配信できていないメッセージがある
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PromptTheme.blocked)
                            .help("届いた A2A メッセージがあります(次に手が空いたら反映されます)")
                            .transition(.opacity)
                    }
                }
            }

            // Blocked: Agent の実際の問い + 点滅キャレット(カード内で動くのはここだけ)
            if style.showQuestion {
                HStack(spacing: 0) {
                    Text("$ ").foregroundStyle(PromptTheme.muted)
                    Text(blockedQuestion)
                        .foregroundStyle(PromptTheme.blocked)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    BlinkingCaret().foregroundStyle(PromptTheme.blocked)
                }
                .font(PromptTheme.mono)
            }

            if showActions {
                Button(action: onOpenTerminal) {
                    HStack(spacing: 6) {
                        Text("▸").font(PromptTheme.mono.weight(.bold))
                        Text("ターミナルを開く").font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(PromptTheme.text)
                    .background(PromptTheme.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(PromptTheme.text.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("ターミナルを開く")
            }
        }
        .padding(12)
        .background(PromptTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(blocked ? PromptTheme.blocked.opacity(0.6)
                        : done ? PromptTheme.done.opacity(0.75)
                        : Color.white.opacity(0.08),
                        lineWidth: (blocked || done) ? 1.5 : 1)
        )
        // 未読(完了)は琥珀のグローで盤面上で目立たせる
        .shadow(color: done ? PromptTheme.done.opacity(0.35) : .clear, radius: done ? 9 : 0)
    }

    /// `cwd on branch ▸` + 右端 PR 番号。方向記号は ▸ に統一(CHANEL)。
    /// 切り詰められても、行全体のホバーで cwd フルパス + branch 全文を自前 tooltip で見せる。
    /// (SwiftUI 標準の .help() はカード全体の DragGesture と競合して発火しないため onHover 方式)
    private var promptLine: some View {
        HStack(spacing: 4) {
            Text(dirName).foregroundStyle(PromptTheme.text)
            if let branch = card.branch {
                Text("on").foregroundStyle(PromptTheme.muted)
                Text(branch)
                    .foregroundStyle(PromptTheme.ok.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("▸").foregroundStyle(PromptTheme.muted)
            Spacer(minLength: 4)
            if let pr = card.prURL, let url = URL(string: pr), let num = prNumber {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(num).foregroundStyle(PromptTheme.text.opacity(0.75))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)   // クリックできると分かるよう指カーソルに
            }
        }
        .font(PromptTheme.mono)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named("board")) { phase in
            guard showActions, !card.promptTooltipText.isEmpty else { return }
            switch phase {
            case .active(let location): onPromptHover(location)
            case .ended:                onPromptHover(nil)
            }
        }
    }

    /// cwd の末尾ディレクトリ名(プロンプトのカレント表示)。
    private var dirName: String {
        guard let p = card.workingDirPath, !p.isEmpty else { return "~" }
        let last = (p as NSString).lastPathComponent
        return last.isEmpty ? "~" : last
    }

    /// PR URL 末尾の番号を "#827" 形式で。
    private var prNumber: String? {
        guard let pr = card.prURL,
              let last = pr.split(separator: "/").last,
              !last.isEmpty else { return nil }
        return "#\(last)"
    }

    private var blockedQuestion: String {
        if let q = card.blockedPrompt, !q.isEmpty { return q }
        return String(localized: "承認待ち — 応答が必要")
    }
}

/// 状態グリフ。WORKING は ◐ をゆっくり回転。
struct StatusGlyph: View {
    let glyph: String
    let color: Color
    let spin: Bool
    var ping: Bool = false
    @State private var rotate = false
    @State private var pinging = false

    var body: some View {
        Text(glyph)
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(spin ? .linear(duration: 1.4).repeatForever(autoreverses: false) : .default,
                       value: rotate)
            .background {
                // レーダーのブリップ: リングが広がって消える
                if ping {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .scaleEffect(pinging ? 2.4 : 0.5)
                        .opacity(pinging ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false),
                                   value: pinging)
                }
            }
            // onAppear だけでなく状態変化でも開始/停止する
            // (カードは READY で現れてから Working/Blocked になるため onAppear のみだと発火しない)
            .onAppear { sync() }
            .onChange(of: spin) { _, _ in sync() }
            .onChange(of: ping) { _, _ in sync() }
    }

    private func sync() {
        rotate = spin
        pinging = ping
    }
}

extension Card {
    /// プロンプト行ホバー時の tooltip 本文: cwd フルパス + ブランチ全文 + PR URL(各1行)。
    var promptTooltipText: String {
        var lines: [String] = []
        if let p = workingDirPath, !p.isEmpty { lines.append(p) }
        if let b = branch { lines.append("⎇ \(b)") }
        if let pr = prURL, !pr.isEmpty { lines.append(pr) }
        return lines.joined(separator: "\n")
    }
}

/// ボード最上位に浮かせる自前ツールチップ。ターミナル調のコンテキストカード。
/// アイコン付きの構造化行 + cwd 末尾強調 + 緑ブランチ + PR チップ。
struct PromptTooltip: View {
    let card: Card

    private static let link = Color(hex: "6FB0FF")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダ: 小さな窓装飾 + eyebrow
            HStack(spacing: 5) {
                Circle().fill(PromptTheme.ok).frame(width: 5, height: 5)
                Text("CONTEXT")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(PromptTheme.muted)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 7) {
                row("folder") { cwdText }
                if card.branch != nil { row("arrow.triangle.branch") { branchText } }
                if prNumber != nil { row("arrow.up.forward.square") { prText } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [Color(hex: "1C2126")!, Color(hex: "0C0E10")!],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
    }

    private func row<C: View>(_ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PromptTheme.muted)
                .frame(width: 13, alignment: .center)
            content()
        }
    }

    /// cwd: 親パスを muted、末尾ディレクトリを強調。
    @ViewBuilder private var cwdText: some View {
        let full = card.workingDirPath ?? ""
        let base = (full as NSString).lastPathComponent
        let parent = (full as NSString).deletingLastPathComponent
        (
            Text(parent.isEmpty || parent == "/" ? (parent == "/" ? "/" : "") : parent + "/")
                .foregroundStyle(PromptTheme.muted)
            + Text(base).foregroundStyle(PromptTheme.text).fontWeight(.semibold)
        )
        .font(.system(size: 11.5, design: .monospaced))
        .fixedSize()
    }

    @ViewBuilder private var branchText: some View {
        Text(card.branch ?? "")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(PromptTheme.ok)
            .fixedSize()
    }

    @ViewBuilder private var prText: some View {
        HStack(spacing: 7) {
            Text(prNumber ?? "")
                .foregroundStyle(Self.link)
                .fontWeight(.semibold)
            if let repo = prRepo {
                Text(repo).foregroundStyle(PromptTheme.muted)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .fixedSize()
    }

    private var prParts: [String] { (card.prURL ?? "").split(separator: "/").map(String.init) }
    private var prNumber: String? {
        guard card.prURL != nil, let n = prParts.last, !n.isEmpty else { return nil }
        return "#\(n)"
    }
    private var prRepo: String? {
        let p = prParts
        guard let i = p.firstIndex(of: "github.com"), i + 2 < p.count else { return nil }
        return "\(p[i + 1])/\(p[i + 2])"
    }
}

/// ターミナル風の点滅キャレット。
struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        Text("▏")
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

struct CardView: View {
    @Environment(\.modelContext) private var context
    @Environment(BoardUIState.self) private var uiState
    @Environment(TerminalSessions.self) private var sessions
    @Bindable var card: Card

    @GestureState private var isDragging = false
    @GestureState private var isConnecting = false

    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var changingDir = false
    @State private var pickingSession = false
    @State private var showingMemory = false
    @State private var hovering = false

    // Fleet 所有 worktree カードの削除フロー用状態。
    @State private var confirmingCleanWorktreeDelete = false        // risk == .clean
    @State private var warningWorktreeRisk: WorktreeService.RemovalRisk?  // risk == .dirty/.unpushed/.inUse
    @State private var worktreeDeleteError: String?                 // removeSafely が throw した場合

    var body: some View {
        CardFace(
            card: card,
            showActions: true,
            hasPendingMessage: uiState.pendingMessageCardIDs.contains(card.id),
            onEdit: beginRename,
            onDelete: beginDelete,
            onOpenTerminal: { uiState.terminalCardID = card.id },
            onChannelTap: { showingMemory = true },
            onPromptHover: { location in
                if let location {
                    uiState.tooltipCardID = card.id
                    uiState.tooltipAnchor = location
                } else if uiState.tooltipCardID == card.id {
                    uiState.tooltipCardID = nil
                    uiState.tooltipAnchor = nil
                }
            }
        )
            .opacity(isDragging ? 0.05 : 1)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("board"))
            } action: { rect in
                uiState.cardFrames[card.id] = rect
            }
            .gesture(dragGesture)
            .onHover { hovering = $0 }
            .overlay(alignment: .trailing) { connectionHandle }
            .contextMenu {
                Button { uiState.terminalCardID = card.id } label: {
                    Label("ターミナルを開く", systemImage: "terminal")
                }
                if card.channel != nil {
                    Button { showingMemory = true } label: {
                        Label("共有メモリを見る", systemImage: "tray.full")
                    }
                    Button(role: .destructive) { try? BoardStore(context: context).disconnectCard(card) } label: {
                        Label("文脈共有を解除", systemImage: "link.badge.minus")
                    }
                    Divider()
                }
                Button(action: beginRename) {
                    Label("名前を変更", systemImage: "pencil")
                }
                Button { changingDir = true } label: {
                    Label("作業ディレクトリを変更…", systemImage: "folder")
                }
                if card.agentKind == .claude {   // 履歴ピッカーは現状 Claude セッション専用
                    Button { pickingSession = true } label: {
                        Label("過去セッションから再開…", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(card.effectiveCwd == nil)
                }
                Divider()
                Button(role: .destructive, action: beginDelete) {
                    Label("カードを削除", systemImage: "trash")
                }
            }
            .sheet(isPresented: $renaming) {
                RenameCardSheet(title: $draft) { newTitle in
                    do { try BoardStore(context: context).renameCard(card, to: newTitle) } catch {}
                }
            }
            .sheet(isPresented: $pickingSession) {
                SessionPickerSheet(cwd: card.effectiveCwd) { sessionID in
                    resumeSession(sessionID)
                }
            }
            .sheet(isPresented: $showingMemory) {
                if let ch = card.channel { ChannelMemorySheet(channelID: ch.id, channelName: ch.name) }
            }
            .alert("カードを削除しますか?", isPresented: $confirmingDelete) {
                Button("削除", role: .destructive, action: deleteCard)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(card.title)」を削除します。起動中のターミナル/Agent も終了します。")
            }
            .confirmationDialog(
                "この worktree も削除しますか?",
                isPresented: $confirmingCleanWorktreeDelete,
                titleVisibility: .visible
            ) {
                Button("worktree も削除", role: .destructive, action: removeWorktreeThenDeleteCard)
                Button("カードだけ削除(worktree は残す)", action: clearWorktreeThenDeleteCard)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(card.title)」のカードと、紐づく worktree(\(card.worktreePath ?? ""))を削除します。worktree はクリーンな状態です。")
            }
            .confirmationDialog(
                worktreeWarningTitle,
                isPresented: Binding(
                    get: { warningWorktreeRisk != nil },
                    set: { if !$0 { warningWorktreeRisk = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("カードだけ削除(worktree はディスクに残す)", role: .destructive, action: clearWorktreeThenDeleteCard)
                Button("ターミナルを開いて手動で処理") {
                    warningWorktreeRisk = nil
                    uiState.terminalCardID = card.id
                }
                Button("キャンセル", role: .cancel) { warningWorktreeRisk = nil }
            } message: {
                Text(worktreeWarningMessage)
            }
            .alert(
                "削除できませんでした",
                isPresented: Binding(
                    get: { worktreeDeleteError != nil },
                    set: { if !$0 { worktreeDeleteError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { worktreeDeleteError = nil }
            } message: {
                Text(worktreeDeleteError ?? "")
            }
            .fileImporter(isPresented: $changingDir, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    try? BoardStore(context: context).setCardDirectory(card, path: url.path)
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("board"))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                uiState.draggingCardID = card.id
                uiState.dragLocation = value.location
            }
            .onEnded { value in
                commitCardDrop(cardID: card.id, at: value.location, context: context, uiState: uiState)
                uiState.draggingCardID = nil
                uiState.dragLocation = nil
            }
    }

    /// カード右端の接続ポート。別カードへドラッグして文脈チャンネルを共有する。
    /// 平常時は端に沿った細いタブ(ポートの目印)、ホバー/接続中はリンクアイコン付きの
    /// 全円ハンドルに育つ。いずれもカード内側に収め、クリップされた半円にはしない。
    private var connectionHandle: some View {
        let color = card.channel.flatMap { Color(hex: $0.colorHex ?? "") } ?? PromptTheme.ok
        let active = hovering || isConnecting
        return ZStack(alignment: .trailing) {
            // 平常時: 端の細いタブ(常時見えて「つなげられる」と分かる目印)
            Capsule()
                .fill(color.opacity(0.85))
                .frame(width: 5, height: 26)
                .opacity(active ? 0 : 1)
            // ホバー/接続中: リンクアイコン付きの全円ハンドル
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "link").font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75)))
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: color.opacity(0.6), radius: 5)
                .opacity(active ? (isConnecting ? 0.5 : 1) : 0)
                .scaleEffect(active ? 1 : 0.6)
        }
        // 右端に沿った広めのヒット領域(常時当たり判定)。掴み損ねてカード移動になるのを防ぐ。
        .frame(width: 30, height: 52, alignment: .trailing)
        .contentShape(Rectangle())
        .offset(x: -3)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: active)
        .help("ドラッグで別カードへ伸ばすと文脈を共有")
        .highPriorityGesture(connectGesture)   // カード移動より接続を優先
    }

    private var connectGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .updating($isConnecting) { _, state, _ in state = true }
            .onChanged { value in
                uiState.connectingFromCardID = card.id
                uiState.connectDragLocation = value.location
            }
            .onEnded { value in
                if let targetID = Self.dropTarget(at: value.location, excluding: card.id, frames: uiState.cardFrames),
                   let target = BoardStore(context: context).card(withID: targetID) {
                    _ = try? BoardStore(context: context).connectCards(card, target)
                    // bridge は常時接続。通知の自動注入はしない(チャットに勝手に入り邪魔なため)。
                }
                uiState.connectingFromCardID = nil
                uiState.connectDragLocation = nil
            }
    }

    /// ドロップ地点から接続先カードを求める。矩形内なら即採用、無ければ少し外側(inset -36)で
    /// 最も近いカードを拾う(端をかすめても繋がるように)。
    private static func dropTarget(at loc: CGPoint, excluding selfID: UUID, frames: [UUID: CGRect]) -> UUID? {
        let others = frames.filter { $0.key != selfID }
        if let inside = others.first(where: { $0.value.contains(loc) })?.key { return inside }
        let near = others
            .filter { $0.value.insetBy(dx: -36, dy: -36).contains(loc) }
            .min { a, b in
                let ca = CGPoint(x: a.value.midX, y: a.value.midY), cb = CGPoint(x: b.value.midX, y: b.value.midY)
                return hypot(ca.x - loc.x, ca.y - loc.y) < hypot(cb.x - loc.x, cb.y - loc.y)
            }
        return near?.key
    }

    private func beginRename() {
        draft = card.title
        renaming = true
    }

    /// カード削除の入口。Fleet 所有 worktree が紐づく場合のみ安全確認フローに分岐し、
    /// それ以外(フォルダカード/非所有 worktree)は従来どおり即確認ダイアログ。
    private func beginDelete() {
        guard card.isFleetOwnedWorktree,
              let worktreePath = card.worktreePath,
              let repoRoot = card.repoRoot else {
            confirmingDelete = true
            return
        }
        let inUse = sessions.hasSession(card.id)
        let risk = WorktreeService.removalRisk(worktreePath: worktreePath, repoRoot: repoRoot, inUse: inUse)
        switch risk {
        case .clean:
            confirmingCleanWorktreeDelete = true
        case .dirty, .unpushed, .inUse:
            warningWorktreeRisk = risk
        }
    }

    private var worktreeWarningTitle: String {
        switch warningWorktreeRisk {
        case .dirty: return "未コミットの変更があります"
        case .unpushed: return "未プッシュのコミットがあります"
        case .inUse: return "セッションが使用中です"
        case .clean, nil: return ""
        }
    }

    private var worktreeWarningMessage: String {
        switch warningWorktreeRisk {
        case .dirty:
            return "この worktree には未コミットの変更が残っています。データを失わないよう、Fleet はこの worktree を削除しません。"
        case .unpushed:
            return "この worktree には未プッシュ/未マージのコミットがあります。履歴を失わないよう、Fleet はこの worktree を削除しません。"
        case .inUse:
            return "この worktree は現在ターミナル/Agent セッションで使用中です。使用中の worktree は削除しません。"
        case .clean, nil:
            return ""
        }
    }

    /// worktree をディスクから安全に撤去してからカードを削除する(risk == .clean のときのみ到達)。
    /// `removeSafely` は clean 以外なら throw し、`--force` は一切使わない。
    private func removeWorktreeThenDeleteCard() {
        guard let worktreePath = card.worktreePath, let repoRoot = card.repoRoot else {
            deleteCard()
            return
        }
        let inUse = sessions.hasSession(card.id)
        do {
            try WorktreeService.removeSafely(worktreePath: worktreePath, repoRoot: repoRoot, inUse: inUse)
            try BoardStore(context: context).clearWorktree(card)
            deleteCard()
        } catch let e as WorktreeService.GitError {
            worktreeDeleteError = e.message
        } catch {
            worktreeDeleteError = "\(error)"
        }
    }

    /// worktree バインディングだけ解除してカードを削除する。ディスク上の worktree は残す。
    private func clearWorktreeThenDeleteCard() {
        do { try BoardStore(context: context).clearWorktree(card) } catch {}
        deleteCard()
    }

    private func deleteCard() {
        if uiState.terminalCardID == card.id { uiState.terminalCardID = nil }
        sessions.close(card.id)
        do { try BoardStore(context: context).deleteCard(card) } catch {}
    }

    /// 選択した過去セッションを、このカードの端末で `claude --resume <id>` 起動する。
    /// 既存セッションは終了して新規に開き直す。
    private func resumeSession(_ sessionID: String) {
        sessions.close(card.id)
        uiState.resumeRequests[card.id] = sessionID
        uiState.terminalCardID = card.id
    }
}

/// カード名編集モーダル
struct RenameCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    let onSave: (String) -> Void

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("カード名を編集").font(.headline)
            TextField("タイトル", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if isValid { save() } }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}
