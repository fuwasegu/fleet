# DONE / BLOCKED のシステム通知 — 設計

作成日: 2026-07-28
ステータス: 承認済み（実装着手）

## 背景と動機

Fleet はカードの状態（Working / Blocked / Done / Idle）を端末出力から自動検知して
盤面に出す。しかし **盤面を見ていなければ気づけない**。エージェントが完了しても、
承認待ちで止まっていても、他のアプリを触っていれば放置時間がそのまま積み上がる。
上部バーの要対応バッジ（`BoardView.attentionCards`）は Fleet 自身が前面にいる時にしか効かない。

macOS のシステム通知を出せば、Fleet が背面でも「どのカードが終わったか」が届く。
通知にはカード名を載せる（どのタスクの話かが分からなければ通知の意味がない）。

## 決定事項（確定）

| 項目 | 決定 |
|---|---|
| 発火条件 | エージェント状態の遷移。カードを Done 列へドラッグした時ではない |
| 通知する状態 | DONE（完了・未読）と BLOCKED（承認待ち）の2種 |
| 通知本文 | タイトル = カード名。副題 = 「完了」/「承認待ち」、Blocked は問いを本文に |
| クリック時 | Fleet を前面に出し、そのカードのターミナルを開く |
| 表示中の抑制 | そのカードのターミナルを開いている間は発火しない |
| 設定 | DONE / BLOCKED を個別にオン・オフ（既定はどちらもオン） |

## 「Done」の定義（既存仕様の確認）

Fleet の Done は独立した `AgentState` ではなく派生値である（`Models.swift:150`）。

```swift
public var isDone: Bool { agentState == .idle && !seen }
```

`seen` は `AgentStateMonitor.apply()`（`TerminalView.swift:127-131`）で更新される。
「そのカードのターミナルを見ていない間に working → idle になった」瞬間に `seen = false`
となり、カードが `✓ DONE 未読` になる。つまり **通知すべき瞬間は、既に seen を落として
いる分岐そのもの**。新しい監視機構は要らない。

## アーキテクチャ

`AgentDetection` と同じ方針で分ける。**判定は KanbanKit の純粋ロジック、配信はアプリ側**。

```
AgentStateMonitor.apply()          [KanbanTerm]  端末 → 状態
      │  previous / current / isViewing
      ▼
AgentNotification.decide()         [KanbanKit]   純粋関数・ユニットテスト対象
      │  Kind? (.done / .blocked)
      ▼
Notifier.post(kind:card:)          [KanbanTerm]  UNUserNotificationCenter
      │  クリック
      ▼
NotificationRouter.pendingCardID   [KanbanTerm]  @Observable
      ▼
BoardView → uiState.terminalCardID = id
```

### 1. 判定ロジック（KanbanKit / `AgentNotification.swift`）

```swift
public enum AgentNotification {
    public enum Kind: Sendable, Equatable { case done, blocked }

    public static func decide(previous: AgentState,
                              current: AgentState,
                              isViewing: Bool) -> Kind?
}
```

- `.done` … `previous == .working && current == .idle && !isViewing`
- `.blocked` … `previous != .blocked && current == .blocked && !isViewing`
- それ以外は `nil`

`.done` の条件は現在 `seen = false` を立てている条件と同一なので、`apply()` 側は
この戻り値から `seen` 更新も通知も導出する。Done の定義を二箇所に持たない。

重要な非発火ケース:

- `unknown → idle`: 起動直後や `resetAgentStates()` の直後。working を経ていないので通知しない。
- `blocked → blocked`: 端末出力のたびに再評価されるが、遷移していないので通知しない。
- `isViewing == true`: 目の前で見ているものを通知しない。

### 2. 配信（KanbanTerm / `Notifier.swift`）

`UNUserNotificationCenter` のローカル通知。

- `content.title` = カード名（`Card.title`）
- `.done` … subtitle「完了」
- `.blocked` … subtitle「承認待ち」、body に `Card.blockedPrompt`（あれば）
- `identifier = "card-<uuid>-<kind>"` … 同一カード・同一種別の未読通知は上書きされ、積み上がらない
- `threadIdentifier = cardID` … 通知センターでカード単位にまとまる
- `userInfo["cardID"]` … クリック時の遷移先
- 起動時に `requestAuthorization([.alert, .sound])`。拒否・失敗時は静かに no-op
- `willPresent` → `[.banner, .sound]`。Fleet が前面でも banner を出す
  （そのカードの端末を開いている場合はそもそも `decide` が nil を返すので出ない）

設定トグルの参照は配信層で行う。判定ロジックは設定を知らない。

### 3. クリック導線（KanbanTerm）

`UNUserNotificationCenterDelegate` は SwiftUI ビュー階層の外にいるため、`@Observable` な
`NotificationRouter` を挟む。`didReceive` で `NSApp.activate()` し `pendingCardID` を立て、
`BoardView` が `.onChange` で `uiState.terminalCardID` に流す。カードが既に削除されて
いれば無視する。これは要対応ポップオーバーからのジャンプ（`BoardView.swift:162`）と同じ導線。

### 4. 設定（`TerminalSettings.swift`）

`TerminalSettingsPopover` に「通知」セクションを追加。

- `完了 (DONE) を通知` — `@AppStorage("notifyOnDone")`、既定 `true`
- `承認待ち (BLOCKED) を通知` — `@AppStorage("notifyOnBlocked")`、既定 `true`
- OS 側で通知が拒否されている場合はヒント文と「システム設定を開く」ボタン

## テスト

`Tests/KanbanKitTests/AgentNotificationTests.swift` に `decide()` の遷移表テスト。

| previous | current | isViewing | 期待 |
|---|---|---|---|
| working | idle | false | `.done` |
| working | idle | true | `nil` |
| unknown | idle | false | `nil` |
| idle | idle | false | `nil` |
| working | blocked | false | `.blocked` |
| blocked | blocked | false | `nil` |
| working | blocked | true | `nil` |
| blocked | working | false | `nil` |

配信層（`UNUserNotificationCenter`）はユニットテストの対象外。実機で手動確認する。

## リスク

`project.yml` は `CODE_SIGNING_ALLOWED: NO` のため、ローカルの開発ビルドは未署名。
`UNUserNotificationCenter` は未署名バンドルで動作しないことがある。リリース版は
`scripts/sign-app.sh` による自己署名済み（配布中の `/Applications/Fleet.app` で確認）
なので配布物は問題ない見込み。

実装の最初に疎通確認を行い、未署名で動かない場合のみ Debug 構成に ad-hoc 署名
（`CODE_SIGN_IDENTITY = "-"`）を足す。`debugEnabled: false`（Developer Tools Access
認証の回避）には影響しない。

## やらないこと（YAGNI）

- カードを Done 列へドラッグしたことによる通知（列名依存になる）
- Working / Idle の通知
- 通知音のカスタマイズ、通知履歴画面
- 通知アクションボタン（返信・スヌーズ等）

## 影響ファイル

| ファイル | 変更 |
|---|---|
| `Sources/KanbanKit/AgentNotification.swift` | 新規（判定ロジック） |
| `Tests/KanbanKitTests/AgentNotificationTests.swift` | 新規（遷移表テスト） |
| `Sources/KanbanTerm/Views/Notifier.swift` | 新規（配信 + ルータ） |
| `Sources/KanbanTerm/Views/TerminalView.swift` | `apply()` を `decide()` 経由に |
| `Sources/KanbanTerm/Views/BoardView.swift` | クリック遷移の受け口 |
| `Sources/KanbanTerm/KanbanTermApp.swift` | 起動時の権限要求・delegate 設定 |
| `Sources/KanbanTerm/Views/TerminalSettings.swift` | 通知トグル |
| `Sources/KanbanTerm/en.lproj/Localizable.strings` | 英語文言 |
| `README.md` / `README.ja.md` / `docs/index.html` | 機能の追記 |
