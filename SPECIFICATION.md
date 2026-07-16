# KANBAN Term 仕様

カンバンボード x Terminal の Swift アプリ．

## 背景

ClaudeCode で一度に同時に開発したり，調査したりすることが増えた．
僕は iTerm2 を使っているが，大量のタブで管理するのが苦手なので，毎回新規 Window を開いて，Project まで移動して，ClaudeCode を起動する．

Window ２，３ 個ならいいが，〜８個くらいになってくると，どの Window がどのタスクをやっているのか，結局わからなくなってくる．

同じ Project をいくつも開いて， worktree で作業したり，レビュー待ちのセッションがあったり．

最近 herdr (https://herdr.dev) という Terminal ツールが人気で，使ってみたけど，GUI ではないから僕には使いにくかった．

## 機能要件

- カンバンボードのように，「作業中」「レビュー待ち」など，状態を持ったカードがある
  - 状態(列)は，自分で追加・削除・編集ができる
    - 列の削除は，その列にカードが残っている場合はできない（空にしてから削除する）
  - カンバンボードなので，状態ごとに領域があって，カードをDDで動かせる
- カードには，タイトルが自由に設定できる
- カードには，Terminal が紐づいていて（1カード = 1Terminal の1対1），カードから Terminal がモーダル的に開く
  - Terminal を閉じると，その上に開いていた Markdown プレビューも同時に閉じる
- カードには，Terminal が開いているルートディレクトリのパス（cwd）が表示されている
  - プログラムから作業ディレクトリを制御することはせず，現在の作業ディレクトリ（Current）を取得して表示する
- カードには，herdr と同じく動いている Agent の状態が表示されていて，Terminal を開いてなくても，Agent がどういう状態なのかがわかる
  - Agent 状態は herdr の実装に倣い次の4値とする：
    - **Working**（作業中）：Agent が実際に処理中．アニメーションアイコンで動いていることが分かりやすいようにする
    - **Blocked**（入力待ち）：承認・許可プロンプトなどで人間の入力を待っている
    - **Idle**（待機）：プロンプト表示・停止中で何も起きていない
    - **Unknown**（素の shell ／ Agent 未起動）
  - 「Done（完了）」は独立した状態ではなく，**Idle かつ未閲覧**（別のカード/画面を見ている間に完了した）の派生表示とする．そのカードの Terminal を開いて閲覧すると Done 表示は消える
- カードを削除すると，そのカードの Terminal（開いていれば）を閉じ，起動中の Agent を停止する（削除後に稼働し続けるプロセス・モーダルを残さない）
- カードを新規追加する際，ショートカット的機能がある
  - 開くディレクトリを GUI で選べる
  - Agent を最初から起動するかを選べる
  - 対応エージェントは **Claude Code のみ**（Codex は非対応）
  - 危険モードスキップ（`claude --dangerously-skip-permissions`）をチェックオプションで選べる（カード単位）．UI 上は強い警告を出す
- caffeinate できるボタンがある（ON/OFF が GUI 上でできる）
  - タイムアウト秒数をユーザーが入力できる（既定 86400 秒 = 24時間．`caffeinate -dimsu -t <秒>`）
  - caffeinate プロセスが終了（タイムアウト失効や外部 kill）したら，GUI トグルも自動的に OFF に戻す（トグル表示と実プロセスの状態を常に一致させる）
- Markdown の Preview 機能がある
  - その Terminal が開いているディレクトリツリーから，表示したい Markdown ファイルを選んで閲覧できる
  - プレビューは，Terminal モーダルよりさらに上のレイヤーに表示される（プレビューは Terminal に従属し，Terminal が開いていることが前提）
- 技術的に可能であれば，その Terminal で開いているブランチに紐づく GitHub PR へのリンクも，カードに表示される
- Claude Code の Token 使用量を，全セッション横断でダッシュボード的に見えるところに表示したい
  - 対象は **Claude Code のみ**．常にどれくらい使っているかをチェックできるようにする

## 技術要件

- Swift を使った GUI である
  - Agent 状態検出のためプロセステーブルへのアクセスが必要なため，**非サンドボックス配布のデベロッパツール**とする（後述）
- Terminal は **SwiftTerm**（Miguel de Icaza によるネイティブ Swift ターミナルエミュレータ, MIT）を採用し，Swift ネイティブ PTY を spawn して描画する
  - 採用理由（当初案 xterm.js + WKWebView からの変更）：
    - **日本語 IME**：`NSTextInputClient` によるネイティブ変換（marked text 対応）。WKWebView(=WebKit) は日本語ローマ字入力に既知の未解決不具合があり高リスクなため回避
    - **リッチ TUI**：Claude Code TUI / vim / tmux，代替スクリーンバッファ，真色/256色，マウス，リサイズ，CJK 幅を具備
    - **Agent 状態検出**：バッファ/セル/OSC を Swift で直読みでき，JS ブリッジが不要
  - 日本語 IME は SwiftTerm 側で対応が進んでおり（本プロジェクト作者が SwiftTerm の日本語まわりのコントリビューター）低リスク。着手時 PoC は主に「Claude Code TUI の実描画」の確認に絞る
- Agent 状態検出（Claude Code）は herdr の方式に倣い，次を組み合わせて判定する（SwiftTerm のネイティブ API で直読み）
  - **Working**：PTY のバイト活動 ＋ 端末タイトル(OSC 0/2)の先頭がスピナー文字（点字 U+2800–U+28FF）
  - **Blocked**：現在表示中のバッファ最下部 N 行が承認/許可プロンプトにマッチ（例：`do you want to proceed?`，`enter to select` ＋ `esc to cancel` 等）
  - **Idle**：プロンプトボックス本文の行が `❯` で始まる
  - **Unknown**：ペイン前面のプロセスが `claude` として認識できない
  - OSC シーケンス（タイトル OSC 0/2，進捗 OSC 9;4）は SwiftTerm の `OscHandler` / delegate で取得し，バッファ末尾テキストはセル/行 API で読む
  - Working→Idle のちらつき抑制（デバウンス）と，起動直後の猶予期間を設ける
  - **保守的 Idle 確定（重要・FSL検証済み）**：活動が無くても `❯` アイドルプロンプトを実際に検出できないうちは Idle にせず **Unknown** 表示にフォールバックする。これにより「未知の承認/入力待ちプロンプト」を Idle（＝Done）と誤表示して放置する事故を防ぐ（`agent_detection.fsl` の `RealBlockNotIdle` を induction で証明済み）
  - **残る本質的限界**：未知パターンの入力待ちは Blocked と“特定”まではできず Unknown 止まり（ヒューリスティックの限界）。承認/許可プロンプトの検出ルールは更新可能なデータとして持ち、パターンを追加できるようにする
- **プロセス識別はネイティブ必須（E2 の核心）**
  - ペインの前面プロセス（プロセスグループのリーダー）を OS のプロセステーブル（`proc_listpids` / `proc_pidpath` 等）から **Swift 側で列挙**し，`claude` の起動かどうか（Unknown 判定）を行う
  - これは WKWebView 内の JS からは実現できないため Swift ネイティブで実装する（＝サンドボックス外配布が前提）
- 検出ルール（正規表現・対象領域）は，将来の Claude Code の表示変更に追従できるよう，コードに直書きせずデータ（設定ファイル）として持つことを推奨する
- **Token 使用量取得（Claude Code）**
  - 非対話/構造化起動時の出力（`--output-format stream-json` または `json`）に含まれる `usage`（input / output / cache トークン）を集計する
  - 全セッション横断は，各セッションの usage を蓄積してダッシュボードに表示する
  - コスト値はローカル推定であり，実請求の根拠にはしない
- **GitHub PR リンク**：Terminal の cwd の git ブランチから対応する PR を解決して表示する（取得できる場合のみ）
- herdr での実現方法は https://github.com/ogulcancelik/herdr を参照のこと

## 参考：形式検証

UI / ライフサイクルの整合性（プレビューの重なり，カード・列・Terminal・Agent のライフサイクル，caffeinate トグル同期，Done バッジの消去）は `kanban_ui.fsl` に FSL で形式化し，`fslc verify` / `induction` で以下の不変条件を証明済み：

- プレビューは Terminal が開いているときのみ存在する
- カードは必ず存在する列に属す（孤児カードなし．列は空でないと削除不可）
- 開いている Terminal は存在するカードのもの
- 削除済みカードの Agent は稼働しない（ゾンビ Agent なし）
- caffeinate トグル ON ⇒ 実プロセス生存（終了時は自動 OFF）
- 閲覧中のカードに未読 Done は表示されない

Agent 状態検出（非UI）は `agent_detection.fsl` で形式化し、`fslc verify` / `induction` で以下を証明済み：

- 死んだ/不在の claude を Working・Blocked と表示しない
- Blocked 表示は本当に入力待ちのときだけ（偽 Blocked なし）
- デバウンス保留中の表示は Working
- **実際に入力待ちなら Idle（＝Done）と誤表示しない**（保守的 Idle 確定）

FSL が炙り出した残課題：未知パターンの入力待ちは Blocked と特定できず Unknown 止まり（安全側だが完全ではない。検出ルールの更新で緩和）。
