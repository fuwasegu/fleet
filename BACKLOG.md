# Backlog（優先度順ではなく発生順のメモ）

## セッションの永続化 / 再接続（アプリ再起動後も前回セッションを自動再開）※要注意
- 要望: アプリを終了→再起動しても、各カードが前回のターミナル/Agentセッションを自動的に選んで起動する。
- **試して撤去**: 起動時に `claude --continue` で自動再開を実装したが、`--continue` は「その cwd の“直近”会話」を拾うだけで **別のカードの/意図しない会話を引っ張る事故**が起きた（cwd が被る/曖昧なケース）。→ 撤去済み。
- **正しくやるには**: カード毎に実際の **`session_id` を保存**し、`claude --resume <session-id>` でピンポイント再開する。
  - Claude のセッションは `~/.claude/projects/<project>/<session-id>.jsonl`。起動した claude の session_id を取得する手段が要る（stream-json の system/init に session_id が出る／rollout ファイル監視 等）。
  - 加えて「起動時に自動再開する / しない」をカード or 全体でトグルにする（重さ・API消費対策）。
- 関連: 「一度も開いてないカードの状態表示」= バックグラウンド PTY 起動。これも上記と一緒に設計（起動時に裏で session を立てる）。今は撤去したので、状態が見えるのは一度開いたカードのみ。

## その他
- 既存カードの cwd を後から変更できるようにする（今は作成時のみ）。→ 実装済み（右クリック）
- ターミナル自動起動タイミング → 実装済み。固定 700ms をやめ、シェル初回出力(プロンプト)が落ち着いてから送信。

## ターミナルの最低限の設定機能 → 実装済み（フォント + 配色テーマ）
- フォント（ファミリ/サイズ）と配色テーマ（背景/文字/カーソル）を設定できるツールバーを追加。
- テーマ: Midnight / Solarized Dark / Dracula / Nord / Light。UserDefaults 永続化、開いている全ターミナルへ即時反映。
- 残（任意）: ANSI16色パレット（SwiftTerm に一括 installColors API が無いため保留）。

## Markdown プレビューの強化 → 実装済み(オフライン完全対応)
- **WKWebView + marked.js + highlight.js + mermaid.js + DOMPurify**。mermaid 図・コードのシンタックスハイライト対応。
- ライブラリはアプリ**同梱**(Resources/markdown)をインライン展開。**ネットワーク不要・CDN 非依存・オフライン動作**。
- セキュリティ: DOMPurify でサニタイズ、mermaid securityLevel=strict、baseURL=nil(不透明オリジン)、
  Markdown 埋め込み時の "<"/U+2028/2029 エスケープで script ブレイクアウト遮断。

## トークン使用量: API 経由（低優先）
- 現状はローカル transcript(jsonl) 集計で十分（Claude Code のセッション使用量が取れるのはこれ）。
- 組織 Admin API キーがあれば Anthropic の Usage/Cost Admin API で組織横断の集計も可能（個人用途には過剰）。必要時のみ。

## 多言語化 → 実装済み(英語 / 日本語)
- 基準言語=日本語(日本語文字列をローカライズキーに)、en.lproj/ja.lproj を variant group で用意。
- Text/Button/Label/help 等は自動ローカライズ。動的 String は String(localized:) / LocalizedStringKey で対応。
- カード名・列名はユーザーデータのため翻訳対象外(入力どおり表示)。

## オーケストレーター構想 → 作ってから **やめた**（2026-07）※判断の記録

「Fleet 自身が Agent を持ち、カードを束ねてオーケストレーションする」構想。
**動くところまで作ったが採用しなかった。** ブランチ `work-orchestrator-dream` に残置。

### やめた理由（これが本命）

**`fleet_create_card` + `fleet_message` があれば、自然語で頼めば済む。**

> 「別で 〇〇 ディレクトリからカード作って、そっちで調査させてから Fleet 経由で情報もらってね」

これで通る。この能力は **v0.3.0 から既にある**。レシピ機構が足すのは決定性とゲートだけで、
欲しかった能力自体は最初から手に入っていた。

### 副因

一番魅力的だったのは「**常駐カード（現行仕様エキスパートが知識を溜め、実装カードから
質問される）**」だった。1カード内の subagent harness に原理的に真似できない部分。
だが作ったのはステージ遷移とゲートという**配管**で、常駐カード（Phase 2）は未着手のまま。
配管だけでは「欲しかったもの」に見えない。

### 拾った知見（オーケストレーションとは無関係に有効）

- **LF は送信ではない。送信は CR**（claude 2.1.220 / codex-cli 0.145.0 で実測）。
  → 誤コメント2箇所を修正済み。bracketed paste は不要だった
- **`card.agentState` のキャッシュを信じて Enter を送ってはいけない。**
  ポーリング由来なので「idle を観測 → Agent が Working へ → キャッシュを信じて送信」が起き、
  最悪は承認プロンプトに Enter が入って危険な許可が通る。`orchestration_stale.fsl` が
  5ステップの反例を出す。**自動送信を作るなら、送信直前に同期でバッファを読み直すこと**
- **bridge は `FLEET_ROOT` を読まない。** アプリが `--root` を渡していなかった（修正済み）
- 注入テキストから **CR は必ず落とす**（混ざると途中で勝手に送信される）
- `claude --resume <id> --model X` は resume でもモデル指定が効く（実測）

### 取り出したもの（main へ）

- カード単位のモデル指定（`AgentLaunch` / `Card.model`）
- 本体と bridge の fleet root 不一致の修正 + `FLEET_ROOT` による隔離
- 上記の誤コメント修正

### もし再訪するなら

配管からではなく **常駐カードから**作る。レシピもステージ遷移も要らない。
「知識を溜めて質問に答える長命カード」だけを、既存の `fleet_message` の上に立てる。
それが刺さらなければ構想全体が刺さらない。

参考: 設計 `docs/superpowers/specs/2026-07-28-fleet-orchestration-design.md`（ブランチ側）、
FSL `orchestration.fsl`（safety proved / liveness verified）、`orchestration_stale.fsl`（反例）。

## 委譲(fleet_create_card)の残件 ※2026-08 のレビューで挙がったが未対応

### 裏で勝手に走らない(一番大きい) → 実装済み(2026-08)
`TerminalSessions.startInBackground` を追加し、委譲で**新しく作られたカードだけ**を裏起動する。
Fleet を閉じている間に届いた委譲も起動時に同じ扱いで裏起動する。

必要だったのは **初期フレームを非ゼロにすること 1 点だけ**だった(`.zero` では winsize が 0x0 に
なり TUI が描画できない)。当初「`onReady` がウィンドウ無しでは発火しない」「グリッドが 0x0」と
診断したが、**どちらも誤り**で、計測が早すぎただけ(実測 `grid=120x40`, `dataReceived` も
`onReady` も発火する)。

- 二重起動: `view(for:)` が `views[cardID]` の既存を返すため構造的に起こらない
  (プロセス生成は `startProcess` の 1 箇所だけで、このガードより後)。
- 歯止め: 対象は「この適用で新しく作られたカード」だけ。既存カードを起動ごとに焼くことはない。

### 「trust this folder」が Unknown だった → 対応済み(2026-08)
新しい作業ディレクトリの初回起動で claude は必ず信頼確認を出す。裏起動したカードは
**必ずここで止まる**のに、`AgentDetection` にルールが無く `unknown` のままで、盤面が
「人間待ち」を示せなかった。Blocked ルールを追加。実機計測で**2つの独立した原因**が出た:

1. **見ている領域が違った**。検知は端末下部 24 行の窓を見るが、起動直後は画面がまだ
   スクロールしておらず、ダイアログは画面**上部**に描かれる(実測 40 行の端末で
   全画面非空=15 / 窓内非空=4)。→ `Region.screen`(可視画面全体)を追加し、この
   ルールだけそこを見る。既存ルールの窓は変えていない(Idle の footer 証拠が壊れるため)。
2. **語間が空白ではなく制御文字**だった。SwiftTerm は書き込まれていないセルを NUL で
   返すため、バッファ上は `Accessing·workspace:` のようになり `contains` が原理的に
   当たらない。→ `AgentDetection.normalize` で制御文字/NBSP を空白に倒し連続空白を
   1 個に畳んでから照合(全ルール共通。`extractQuestion` も同じ正規化を通す)。

どちらも「ルールを足すだけ」では直らなかった。端末バッファを当てにする検知を足すときは
**領域と文字の実測から入る**こと。

### チャンネル経由の board-intents にプロセス間ロックが無い
`board-applied.json` の読み書きが無保護なので、Fleet を2つ起動すると `create_card` /
`move_card` の二重適用や applied 集合の上書きが起こり得る。委譲キュー側は claim(rename)で
閉じたが、こちらは手付かず。そもそも同一 `FLEET_ROOT` で2プロセスは SwiftData の同時書き込みに
なるため未サポートだが、構造としては穴。

