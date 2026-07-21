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
    static let ok      = Color(hex: "7FD962")!   // 稼働 / 完了
    static let blocked = Color(hex: "E54B4D")!   // 承認待ち(唯一の警告色)
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
            glyph = "✓"; tag = "DONE"; status = String(localized: "未読"); color = PromptTheme.ok; spin = false; ping = false; showQuestion = false
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
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onOpenTerminal: () -> Void = {}
    /// プロンプト行のホバー。active は "board" 座標のカーソル位置、nil で解除。
    var onPromptHover: (CGPoint?) -> Void = { _ in }

    var body: some View {
        let style = AgentStatusStyle(card: card)
        let blocked = style.tag == "BLOCKED"

        VStack(alignment: .leading, spacing: 8) {
            // 状態行
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusGlyph(glyph: style.glyph, color: style.color, spin: style.spin, ping: style.ping)
                Text("[\(style.tag)]").foregroundStyle(style.color)
                if !style.status.isEmpty {
                    Text(style.status).foregroundStyle(PromptTheme.muted)
                }
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
                .stroke(blocked ? PromptTheme.blocked.opacity(0.55) : Color.white.opacity(0.08),
                        lineWidth: 1)
        )
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
    @State private var angle = 0.0
    @State private var pinging = false

    var body: some View {
        Text(glyph)
            .foregroundStyle(color)
            .rotationEffect(.degrees(spin ? angle : 0))
            .background {
                // レーダーのブリップ: リングが広がって消える
                if ping {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .scaleEffect(pinging ? 2.4 : 0.5)
                        .opacity(pinging ? 0 : 0.8)
                }
            }
            .onAppear {
                if spin {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                }
                if ping {
                    withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        pinging = true
                    }
                }
            }
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

    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var changingDir = false
    @State private var pickingSession = false

    var body: some View {
        CardFace(
            card: card,
            showActions: true,
            onEdit: beginRename,
            onDelete: { confirmingDelete = true },
            onOpenTerminal: { uiState.terminalCardID = card.id },
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
            .contextMenu {
                Button { uiState.terminalCardID = card.id } label: {
                    Label("ターミナルを開く", systemImage: "terminal")
                }
                Button(action: beginRename) {
                    Label("名前を変更", systemImage: "pencil")
                }
                Button { changingDir = true } label: {
                    Label("作業ディレクトリを変更…", systemImage: "folder")
                }
                Button { pickingSession = true } label: {
                    Label("過去セッションから再開…", systemImage: "clock.arrow.circlepath")
                }
                .disabled(card.workingDirPath == nil)
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("カードを削除", systemImage: "trash")
                }
            }
            .sheet(isPresented: $renaming) {
                RenameCardSheet(title: $draft) { newTitle in
                    do { try BoardStore(context: context).renameCard(card, to: newTitle) } catch {}
                }
            }
            .sheet(isPresented: $pickingSession) {
                SessionPickerSheet(cwd: card.workingDirPath) { sessionID in
                    resumeSession(sessionID)
                }
            }
            .alert("カードを削除しますか?", isPresented: $confirmingDelete) {
                Button("削除", role: .destructive, action: deleteCard)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(card.title)」を削除します。起動中のターミナル/Agent も終了します。")
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

    private func beginRename() {
        draft = card.title
        renaming = true
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
