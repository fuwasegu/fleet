# DONE / BLOCKED の通知 — 設計

作成日: 2026-07-28
更新日: 2026-07-29（システム通知 → Dock へ方式変更。「結論」節を参照）
ステータス: 実装済み（v0.9.2）

## 背景と動機

Fleet はカードの状態（Working / Blocked / Done / Idle）を端末出力から自動検知して
盤面に出す。しかし **盤面を見ていなければ気づけない**。エージェントが完了しても、
承認待ちで止まっていても、他のアプリを触っていれば放置時間がそのまま積み上がる。
上部バーの要対応バッジ（`BoardView.attentionCards`）は Fleet 自身が前面にいる時にしか効かない。

Fleet が背面にいても手番が来たことが届くようにする。

当初はカード名をタイトルにした macOS のシステム通知で実装したが、自己署名配布では
原理的に使えないことが分かり、Dock のバウンス + バッジ + 音に差し替えた（「結論」節）。

## 決定事項（確定）

| 項目 | 決定 |
|---|---|
| 発火条件 | エージェント状態の遷移。カードを Done 列へドラッグした時ではない |
| 知らせる状態 | DONE（完了・未読）と BLOCKED（承認待ち）の2種 |
| 伝達手段 | Dock アイコンのバウンス + 要対応件数のバッジ + 音（当初はシステム通知） |
| どのカードか | 盤面上部の「要対応」リスト（カード名が並ぶ）。Dock には名前を出せない |
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

`AgentDetection` と同じ方針で分ける。**判定は KanbanKit の純粋ロジック、伝達はアプリ側**。

```
AgentStateMonitor.apply()          [KanbanTerm]  端末 → 状態
      │  previous / current / isViewing
      ▼
AgentNotification.decide()         [KanbanKit]   純粋関数・ユニットテスト対象
      │  Kind? (.done / .blocked)
      ▼
Notifier.signal(kind)              [KanbanTerm]  Dock バウンス + 音
                                                 （バッジは BoardView が要対応件数から更新）
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

### 2. 伝達（KanbanTerm / `Notifier.swift`）

権限を必要としない Dock の機構だけを使う。

- `.blocked` … `NSSound(named: "Funk")` + `NSApp.requestUserAttention(.criticalRequest)`
  （応答が要るので、戻ってくるまで跳ね続ける）
- `.done` … `NSSound(named: "Glass")` + `.informationalRequest`（一度だけ跳ねる）
- Dock バッジ … `NSApp.dockTile.badgeLabel = AgentNotification.badgeLabel(attentionCount:)`。
  件数は `BoardView.attentionCards`（承認待ち or 未読完了、開いているカードは除く）から取り、
  対応し終えて盤面に戻ると自然に減る。0 件で消える

設定トグルの参照はここで行う。判定ロジックは設定を知らない。

Fleet が前面にいるとき Dock は反応しない = 見えているので不要、という macOS の挙動に乗る。

### 3. 「どのカードか」（KanbanTerm）

Dock にはカード名を出せない。これは既存の**盤面上部の「要対応」ポップオーバー**が担う
（`BoardView.attentionPopover`）。カード名が並び、行をタップでそのカードのターミナルへ切り替わる。
Dock クリックで Fleet が前面に出れば、バッジの件数とこのリストで「誰が待っているか」が分かる。

### 4. 設定（`TerminalSettings.swift`）

`TerminalSettingsPopover` に「通知」セクションを追加。

- `完了 (DONE) を知らせる` — `@AppStorage("notifyOnDone")`、既定 `true`
- `承認待ち (BLOCKED) を知らせる` — `@AppStorage("notifyOnBlocked")`、既定 `true`

OS の許可は不要なので、権限まわりの UI は無い。

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

同じファイルに Dock バッジの表示判定 `badgeLabel(attentionCount:)` のテスト
（0 件と負数で `nil` = バッジを消す、正数はそのまま文字列に）。

Dock / 音（AppKit の副作用）はユニットテストの対象外。実機で手動確認する。

## 結論（v0.9.2 で方式変更）

**`UNUserNotificationCenter` は Fleet では使えない。** 自己署名配布のため Gatekeeper に
rejected され、その状態のアプリは `requestAuthorization` が許可ダイアログを出さないまま
`denied` になる。Dock のバウンス + バッジ + 音に差し替えた（下の「実測」参照）。

以下、当初設計のうち **変わっていない部分**:

- 発火条件（`AgentNotification.decide`）とその呼び出し位置（`AgentStateMonitor.apply()`）
- DONE / BLOCKED の2種、開いているカードでは鳴らさない
- 設定での種別ごとのオン・オフ

**変わった部分**:

| | 当初 | 現在 |
|---|---|---|
| 伝達手段 | システム通知（タイトル = カード名） | Dock バウンス + バッジ（件数）+ 音 |
| カード名 | 通知タイトルに出す | **Dock には出せない**。盤面上部の「要対応」リストが担う |
| クリック導線 | 通知タップ → そのカードの端末 | Dock クリックで Fleet が前面に → 「要対応」から選ぶ |
| 権限 | `requestAuthorization` が必要 | 不要 |
| 音の別 | 共通 | BLOCKED は Funk + 戻るまで跳ね続ける / DONE は Glass + 一度だけ |

`NotificationRouter`（delegate → SwiftUI の橋渡し）は不要になったので削除した。

## 実測: なぜシステム通知が使えないか

v0.9.0 / v0.9.1 では実際に通知が届かなかった。使い捨ての最小 .app バンドルを段階的に
条件を変えて実測し、原因を特定した。

### スパイクの結果

| 条件 | `requestAuthorization` | `add` |
|---|---|---|
| ad-hoc 署名（`CODE_SIGNING_ALLOWED=NO` のローカルビルド相当） | `denied` / Code 1 | 失敗 Code 1 |
| Apple Development 署名・裸のアプリ（ウィンドウなし） | `denied` / Code 1 | 成功 |
| Apple Development 署名・SwiftUI の実ウィンドウあり・`applicationDidFinishLaunching` で要求 | `notDetermined` → **ダイアログなしで `denied`** | 成功 |

ウィンドウの有無も要求タイミングも効かなかった。`add` は成功するので**呼び出し側は
正しく、ただ表示されない**。

### 決め手: Gatekeeper 評価との相関

| アプリ | `spctl -a -vv` | 通知 |
|---|---|---|
| Fleet（自己署名） | **rejected** `origin=Fleet Self-Signed (fuwasegu)` | 通知設定に登録すらされない |
| スパイク（Apple Development 署名） | **rejected** | ダイアログ出ず `denied` |
| Ghostty / Slack / Claude / iTerm | accepted `Notarized Developer ID` | 動く |

この Mac の通知設定（`~/Library/Preferences/com.apple.ncprefs.plist`）に登録されている
サードパーティアプリは**すべて Notarized Developer ID**。Gatekeeper に rejected される
署名のアプリは、許可ダイアログが出ないまま `denied` になる。

**つまり通知センターを使うには Apple Developer Program での Developer ID 署名 +
notarization が必要**。署名の有無ではなく、署名の「種類」が効いていた。

### 除外した要因

- **quarantine 属性**: `/Applications/Fleet.app` には付いていない（`com.apple.provenance` のみ）
- **MDM の制限**: `com.apple.notificationsettings` プロファイルはあるが、業務アプリ28個を
  強制許可するホワイトリストで、他アプリを禁止するものではない。`com.apple.applicationaccess`
  にも通知関連の制限なし
- **集中モード**: アサーションなし
- **要求タイミング**: 当初 `KanbanTermApp.init()` で呼んでいたのが早すぎるという仮説を
  持ったが、`applicationDidFinishLaunching` で呼ぶスパイクでも同じ結果だった

なお、この Mac では `log show` が何も返さない（管理設定による制限）ため、
通知デーモン側のログは証拠に使えなかった。

## やらないこと（YAGNI）

- カードを Done 列へドラッグしたことによる通知（列名依存になる）
- Working / Idle の通知
- 音のカスタマイズ
- Developer ID 署名 + notarization（通知センターを使いたくなったら再検討）

## 影響ファイル

| ファイル | 変更 |
|---|---|
| `Sources/KanbanKit/AgentNotification.swift` | 新規（判定ロジック） |
| `Tests/KanbanKitTests/AgentNotificationTests.swift` | 新規（遷移表テスト） |
| `Sources/KanbanTerm/Views/Notifier.swift` | 新規（Dock バウンス + バッジ + 音） |
| `Sources/KanbanTerm/Views/TerminalView.swift` | `apply()` を `decide()` 経由に |
| `Sources/KanbanTerm/Views/BoardView.swift` | 要対応件数 → Dock バッジ |
| `Sources/KanbanTerm/Views/TerminalSettings.swift` | 通知トグル |
| `Sources/KanbanTerm/en.lproj/Localizable.strings` | 英語文言 |
| `README.md` / `README.ja.md` / `docs/index.html` | 機能の追記 |
