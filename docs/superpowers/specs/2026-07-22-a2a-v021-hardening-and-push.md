# A2A v0.2.1 — 堅牢化と push 協調

対象: Fleet の A2A(Agent-to-Agent 共有メモリ)。v0.2.0 で導入した「盤面でつないだ
カード＝共有メモリチャンネル」を、機能/品質の両レビューを受けて堅牢化し、
「共有 dead-drop」から「協調する Agent 群」へ進化させる。

## 背景 — 2つの根本原因(両レビューが収束)

1. **ファイル層がロックなし O_APPEND で十分と仮定。** 全書き換え(deleteEntry / merge)は
   `rename(2)` でファイルを差し替えるため、並行する追記(remember)と競合してデータ消失。
   大きな書込は複数 `write` に分割されて行が交錯しうる。
2. **bridge がチャンネルdirを起動時に焼き込む。** 所属(チャンネル)は盤面操作で可変なのに、
   稼働中 bridge は起動時のパスに固定。合流(merge)でdirが消える/解除で離脱しても稼働中の
   Agent は古い実体を読み書きし続け、サイレントにメモリ分断・履歴消失。

さらに機能面: Fleet は各 Agent の稼働/blocked/branch/PR を250ms毎に把握しているのに、A2A は
それを捨てて名前一覧しか出さず、共有メモリは誰も見る義務のない dead-drop だった。

## 設計 — 唯一の新プリミティブ

**Fleet 本体の常駐チャンネル watcher(`A2AChannelHub`)。** 各 `~/.fleet/channels/<id>/` を
`DispatchSource` で監視し、Agent がファイルに書いたものを Fleet 側で作用させる。push 配信・
live peers・(将来の)kanban 操作はすべてこの上に載る、小さく一貫した面。

### ファイル配置(`~/.fleet/`)
- `channels/<channelID>/`
  - `memory.jsonl` — 共有メモリ(1行1エントリ, `authorID` 付き)
  - `peers.json` — `[{id,name,status,task,blocked,branch,pr}]`(live-aware, Fleet が源泉)
  - `outbox.jsonl` — 有向メッセージ(fleet_message / fleet_handoff)
  - `status-<cardID>.json` — Agent 自己申告の作業(fleet_status)
  - `delivered-<cardID>.json` — 宛先毎の配信済みメッセージ id
  - `.lock` — チャンネル単位の排他ロック(flock)
- `cards/<cardID>/binding.json` — `{channel, name}`(bridge が現在の所属を毎操作で解決)

### 堅牢化(Tier 1)
- **クロスプロセス flock:** 全書き換えと各 bridge の追記を `.lock` で直列化(HIGH-2 / MEDIUM-2)。
  fleet_remember に 16KB 上限。
- **bridge をカード束ね:** 起動は `fleet-bridge --card <cardID>`。所属は `binding.json` を
  毎操作で読んで解決 → 接続/解除/合流/改名が稼働中 Agent に即反映(HIGH-1/3, MEDIUM-4)。
- **破損行温存:** deleteEntry はデコード不能行を巻き添えにしない(MEDIUM-3)。
- **原子書込 / 掃除:** peers.json は原子書込かつ差分時のみ、離脱時に mcp-config を削除、
  close 時に `killpg` で孤児 bridge を防ぐ、MCP に parse-error / protocol 交渉(LOW/MEDIUM)。

### push 協調(Tier 2)
- **fleet_message / fleet_handoff:** outbox に追記 → watcher が宛先カードの live セッションへ
  `term.send` で注入。宛先が **idle のときだけ** 注入し、作業中/未起動のものは
  次の idle 遷移(`AgentStateMonitor` の状態変化通知)で配信。`delivered-<card>.json` で
  重複配信を防ぎ、未配信はカードに封筒バッジ。注入行は `[A2A message from <name>] …` と
  provenance を明示し、複数行は1行に畳む(改行=送信のため)。
- **live-aware fleet_peers:** 状態変化で peers.json を随時更新。fleet_status で task も。
- **nudge のイベント駆動化:** 節目で remember、影響時 message、引継ぎ時 handoff、再開時 recall。
  届いたメッセージは untrusted として扱うよう明示。

### watcher の自己トリガー対策
peers.json / delivered / status も channel dir 内にあり watcher を再発火させるが、
peers.json は **内容が変わらないときは書かない** ため、状態が落ち着けば1サイクルで収束する。

## 検証
- 単体テスト 26→32(binding往復 / 破損行温存 / merge温存 / outbox往復 / 配信カーソル / peers冪等)。
- `scripts/test-bridge.sh` を --card+binding / 巨大ノート拒否 / parse-error / self除外 /
  message・handoff・status・toID解決 まで拡張。
- 実 `claude` による E2E: fleet_peers → fleet_message(toID 解決) → fleet_status が
  実バイナリ経由で outbox / status に正しく永続することを確認。

## fast-follow(v0.3.0 で実装済み)
予告どおり、いずれも同じ `~/.fleet/channels/<id>/` と watcher の上に載せた:
- **構造化メモリ**: `ChannelEntry.kind`(decision|blocker|artifact|question|note)/`refs`。
  `fleet_remember(kind, refs)`、`fleet_recall(kind, unread)`(未読カーソル
  `recall-cursor-<cardID>.json`)。UI に kind バッジ + refs。
- **advisory ロック**: `fleet_claim` / `fleet_release` / `fleet_locks`(`locks.json`)。
- **kanban を MCP から操作**: `fleet_board` / `fleet_create_card` / `fleet_move_card`。
  bridge が `board-intents.jsonl` に intent を書き、watcher が `BoardStore.applyBoardIntents`
  で適用(create は作成元チャンネルへ自動参加=委譲、move はチャンネル内限定、破壊操作なし、
  適用は冪等)。観測用に `board.json` スナップショット。

## なお見送り
- メモリ肥大のコンパクション/サイズ上限(現状の規模では不要)。
- 複数チャンネル同時所属(max-1 の MVP 制約を維持)。
- クロスマシンの独自 A2A プロトコル(ローカル完結・クラウド不要の方針から対象外)。
