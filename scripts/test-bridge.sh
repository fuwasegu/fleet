#!/usr/bin/env bash
# fleet-bridge(MCP サーバ)の JSON-RPC プロトコルをライブ claude 無しで検証する。
# 使い方: scripts/test-bridge.sh <path-to-fleet-bridge>
set -euo pipefail
BRIDGE="${1:?usage: test-bridge.sh <fleet-bridge>}"

# --card + binding.json でチャンネルを解決する新方式を再現する。
ROOT="$(mktemp -d)"
CARD="11111111-1111-1111-1111-111111111111"
CHAN="22222222-2222-2222-2222-222222222222"
mkdir -p "$ROOT/cards/$CARD" "$ROOT/channels/$CHAN"
echo "{\"channel\":\"$CHAN\",\"name\":\"cardA\"}" > "$ROOT/cards/$CARD/binding.json"
# peers.json は {id,name,status,...} の配列(live-aware)
cat > "$ROOT/channels/$CHAN/peers.json" <<JSON
[{"id":"$CARD","name":"cardA","status":"working"},
 {"id":"33333333-3333-3333-3333-333333333333","name":"cardB","status":"blocked","blocked":"Do you want to proceed?"}]
JSON
# board.json スナップショット(fleet_board が読む)
cat > "$ROOT/channels/$CHAN/board.json" <<JSON
{"columns":[{"name":"Todo"},{"name":"Done"}],"cards":[{"id":"$CARD","title":"cardA","column":"Todo","status":"working"}]}
JSON

BIG="$(python3 -c 'print("x"*20000)')"   # 16KB 上限超え
OUT="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fleet_remember","arguments":{"text":"hello-ci"}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fleet_recall","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fleet_peers","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"fleet_message","arguments":{"to":"cardB","text":"api is ready"}}}'
  echo '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"fleet_handoff","arguments":{"to":"cardB","text":"take over the client"}}}'
  echo '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"fleet_status","arguments":{"text":"building the API"}}}'
  # 構造化メモリ(kind/refs)
  echo '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"fleet_remember","arguments":{"text":"chose SwiftData","kind":"decision","refs":["Models.swift"]}}}'
  echo '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"fleet_recall","arguments":{"kind":"decision"}}}'
  # advisory ロック
  echo '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"fleet_claim","arguments":{"resource":"Models.swift"}}}'
  echo '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"fleet_locks","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"fleet_release","arguments":{"resource":"Models.swift"}}}'
  # kanban 操作
  echo '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"fleet_board","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"client work","column":"Todo"}}}'
  echo '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"fleet_move_card","arguments":{"card":"client work","column":"Done"}}}'
  # 委譲: agent/model 付きのカード作成(「Codex のカードを立ててレビューさせて」の要)
  echo '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"review","agent":"codex","model":"gpt-5-codex"}}}'
  echo '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"bad agent","agent":"gemini"}}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"fleet_remember\",\"arguments\":{\"text\":\"$BIG\"}}}"
  echo 'this is not json'
  echo '{"jsonrpc":"2.0","id":6,"method":"nonsense/method"}'
} | "$BRIDGE" --root "$ROOT" --card "$CARD" > "$OUT"

fail() { echo "FAIL: $1"; echo "--- output ---"; cat "$OUT"; exit 1; }
grep -q '"serverInfo"'            "$OUT" || fail "initialize missing serverInfo"
grep -q '"protocolVersion":"2025-06-18"' "$OUT" || fail "initialize did not negotiate known protocol"
grep -q 'fleet_recall'            "$OUT" || fail "tools/list missing fleet_recall"
grep -q 'fleet_remember'          "$OUT" || fail "tools/list missing fleet_remember"
grep -q 'fleet_peers'             "$OUT" || fail "tools/list missing fleet_peers"
grep -q 'fleet_worktree_create'   "$OUT" || fail "tools/list missing fleet_worktree_create"
grep -q 'Saved to shared memory'  "$OUT" || fail "remember not saved"
grep -q 'hello-ci'                "$OUT" || fail "recall did not return remembered text"
# fleet_peers の結果行(id:5)だけを取り出して検証する(他ツールの出力と混ざらないよう)。
PEERS_LINE="$(grep '"id":5' "$OUT" || true)"
echo "$PEERS_LINE" | grep -q 'cardB'                   || fail "peers did not list cardB"
echo "$PEERS_LINE" | grep -q 'blocked on: Do you want' || fail "peers did not surface blocked question"
if echo "$PEERS_LINE" | grep -q 'cardA'; then fail "peers must exclude self (cardA)"; fi
grep -q 'Note too large'          "$OUT" || fail "oversized remember not rejected"
grep -q '"code":-32700'           "$OUT" || fail "malformed JSON did not return parse error"
grep -q '"code":-32601'           "$OUT" || fail "unknown method not rejected"

grep -q 'Sent to cardB'          "$OUT" || fail "fleet_message not acknowledged"
grep -q 'Status updated'         "$OUT" || fail "fleet_status not acknowledged"
# 構造化メモリ: kind フィルタで decision のみ返る
grep -q '(decision) chose SwiftData' "$OUT" || fail "kind-tagged recall missing decision entry"
# advisory ロック
grep -q 'Claimed.*Models.swift'   "$OUT" || fail "fleet_claim not acknowledged"
grep -q -- '- Models.swift → cardA' "$OUT" || fail "fleet_locks did not list the claim"
grep -q 'Released.*Models.swift'  "$OUT" || fail "fleet_release not acknowledged"
# kanban
grep -q 'Board columns: Todo | Done' "$OUT" || fail "fleet_board did not render columns"
grep -q 'Requested new card'       "$OUT" || fail "fleet_create_card not acknowledged"
grep -q 'Requested move'           "$OUT" || fail "fleet_move_card not acknowledged"
# agent/model が intent に載ること / 未知の agent は載らない(本体側で claude に落ちる)

# 上限超えの巨大ノートが memory.jsonl に書かれていないこと(hello-ci + decision の2行)
LINES="$(wc -l < "$ROOT/channels/$CHAN/memory.jsonl" | tr -d ' ')"
[ "$LINES" = "2" ] || fail "oversized note should not be persisted (memory has $LINES lines)"
grep -q '"kind":"decision"'       "$ROOT/channels/$CHAN/memory.jsonl" || fail "kind not persisted"

# board-intents に create + move の2行
BINT="$ROOT/channels/$CHAN/board-intents.jsonl"
[ -f "$BINT" ] || fail "board-intents.jsonl not created"
# create_card x3 (通常/agent+model/未知の agent) + move_card x1
[ "$(wc -l < "$BINT" | tr -d ' ')" = "4" ] || fail "expected 4 board intents (has $(wc -l < "$BINT" | tr -d ' '))"
grep -q '"kind":"create_card"'    "$BINT" || fail "create_card intent missing"
grep -q '"kind":"move_card"'      "$BINT" || fail "move_card intent missing"
# 委譲: agent/model が intent に載ること
grep -q '"agent":"codex"'         "$BINT" || fail "agent not persisted in board intent"
grep -q 'gpt-5-codex'             "$BINT" || fail "model not persisted in board intent"
# 未知の agent はそもそも intent に載せない(本体側で claude に落ちる)
grep -q 'gemini'                  "$BINT" && fail "unknown agent should not be written to the intent" || true
# locks.json は release 後に空
grep -q 'Models.swift' "$ROOT/channels/$CHAN/locks.json" && fail "lock not cleared after release" || true

# outbox に message + handoff の2行、宛先 toID が解決されていること
OBX="$ROOT/channels/$CHAN/outbox.jsonl"
[ -f "$OBX" ] || fail "outbox.jsonl not created"
OLINES="$(wc -l < "$OBX" | tr -d ' ')"
[ "$OLINES" = "2" ] || fail "outbox should have 2 messages (has $OLINES)"
grep -q '"kind":"handoff"'       "$OBX" || fail "handoff not recorded in outbox"
grep -q '33333333-3333-3333-3333-333333333333' "$OBX" || fail "outbox did not resolve toID for cardB"
# status ファイルが書かれていること
[ -f "$ROOT/channels/$CHAN/status-$CARD.json" ] || fail "status file not written"

# --- SECURITY item 1: binding.json の channel が UUID でない(パス脱出狙い)場合、
#     「無所属」に丸められてクラッシュもパス脱出もしないこと。 ---
ROOT2="$(mktemp -d)"
CARD2="44444444-4444-4444-4444-444444444444"
mkdir -p "$ROOT2/cards/$CARD2"
printf '{"channel":"../../../tmp/evil-channel","name":"cardX"}' > "$ROOT2/cards/$CARD2/binding.json"
OUT2="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fleet_recall","arguments":{}}}'
} | "$BRIDGE" --root "$ROOT2" --card "$CARD2" > "$OUT2"
grep -q 'not currently in a shared channel' "$OUT2" || fail "malicious channel id in binding.json was not rejected"
[ -e "$ROOT2/tmp" ] && fail "path traversal via channel id escaped the fleet root"

# --- SECURITY item 1: 不正な --card 引数(パス脱出狙い)もクラッシュせず「無所属」になること。 ---
OUT3="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fleet_recall","arguments":{}}}'
} | "$BRIDGE" --root "$ROOT2" --card "../../../etc/passwd" > "$OUT3"
grep -q 'not currently in a shared channel' "$OUT3" || fail "malicious --card argument was not rejected"

# --- SECURITY item 3: fleet_create_card の dir は絶対パス+実在ディレクトリのみ許可。 ---
OUT4="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"bad dir","dir":"relative/path"}}}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"missing dir","dir":"/no/such/dir/hopefully-not-real"}}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"fleet_create_card\",\"arguments\":{\"title\":\"good dir\",\"dir\":\"$ROOT\"}}}"
} | "$BRIDGE" --root "$ROOT" --card "$CARD" > "$OUT4"
[ "$(grep -c 'dir must be an absolute path' "$OUT4")" = "2" ] || fail "relative/nonexistent dir was not rejected (want 2 rejections)"
GOOD_DIR_LINE="$(grep '"id":4' "$OUT4" || true)"
echo "$GOOD_DIR_LINE" | grep -q 'Requested new card' || fail "valid absolute existing dir was wrongly rejected"
echo "$GOOD_DIR_LINE" | grep -q 'good dir'          || fail "valid absolute existing dir was wrongly rejected (wrong card)"

# --- SECURITY item 2: fleet_remember の refs は件数(20)と各要素長(200)が切り詰められる。 ---
REFS_JSON="$(python3 -c "import json; print(json.dumps(['ref-' + str(i) + ('X' * 250) for i in range(25)]))")"
OUT5="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fleet_remember\",\"arguments\":{\"text\":\"refs cap test\",\"refs\":$REFS_JSON}}}"
} | "$BRIDGE" --root "$ROOT" --card "$CARD" > "$OUT5"
grep -q 'Saved to shared memory' "$OUT5" || fail "refs-cap remember was not saved"
LAST_LINE="$(tail -n1 "$ROOT/channels/$CHAN/memory.jsonl")"
REFS_COUNT="$(printf '%s' "$LAST_LINE" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("refs", [])))')"
[ "$REFS_COUNT" = "20" ] || fail "refs array was not capped to 20 elements (got $REFS_COUNT)"
MAXLEN="$(printf '%s' "$LAST_LINE" | python3 -c 'import json,sys; refs=json.load(sys.stdin).get("refs", []); print(max((len(r) for r in refs), default=0))')"
[ "$MAXLEN" -le 200 ] || fail "a ref element was not truncated to 200 chars (got $MAXLEN)"


# --- 無所属カードからの委譲: fleet_create_card だけはチャンネル無しでも通ること ---
#     ここが塞がっていると「カードを作るにはチャンネルが必要 / チャンネルを作るには
#     カードを2枚手で結線」という鶏と卵になり、1枚目のカードは何も委譲できない。
ROOT4="$(mktemp -d)"
CARD4="55555555-5555-5555-5555-555555555555"
mkdir -p "$ROOT4/cards/$CARD4"
printf '{"name":"loneCard"}' > "$ROOT4/cards/$CARD4/binding.json"   # channel を持たない
OUT4="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fleet_create_card","arguments":{"title":"review this PR","agent":"codex","model":"gpt-5-codex"}}}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fleet_recall","arguments":{}}}'
} | "$BRIDGE" --root "$ROOT4" --card "$CARD4" > "$OUT4"

# create_card は成功する
grep -q 'Requested new card' "$OUT4" || fail "create_card from an unconnected card was rejected"
grep -q 'review this PR'     "$OUT4" || fail "created card title missing from the response"
# 逆に、本当にチャンネルが要るツールは従来どおり拒否される
grep -q 'not currently in a shared channel' "$OUT4" || fail "fleet_recall should still require a channel"
# intent は委譲キューへ「1 intent = 1ファイル」で書かれ、agent/model も載る。
# 追記ログにしないのは、Fleet 本体がディレクトリ監視で拾うため(既存ファイルへの追記では
# 監視イベントが発火せず永久に拾われない — 実機で踏んだ)。
DCOUNT="$(ls "$ROOT4/delegations"/*.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$DCOUNT" = "1" ] || fail "expected exactly 1 delegation file (has $DCOUNT)"
DFILE="$(ls "$ROOT4/delegations"/*.json | head -1)"
grep -q '"kind":"create_card"' "$DFILE" || fail "create_card intent missing from delegation queue"
grep -q '"agent":"codex"'      "$DFILE" || fail "agent not persisted in delegation queue"
grep -q 'gpt-5-codex'          "$DFILE" || fail "model not persisted in delegation queue"
# チャンネル dir を勝手に作っていないこと(無所属のまま)
[ -d "$ROOT4/channels" ] && fail "unconnected card must not create a channel dir from the bridge" || true


# --- hook イベントモード(--hook-event): Claude の hooks から直接起動されるモード。
#     セッションの中で動くプロセスなので、何が起きても stdout には何も書かず exit 0 で
#     終わらなければならない(stdout はモデルへのコンテキストになり得る/非0終了はセッションに
#     影響し得る)。 ---
ROOT5="$(mktemp -d)"
CARD5="66666666-6666-6666-6666-666666666666"
mkdir -p "$ROOT5/cards/$CARD5"
# Stop イベントの実測フィールド一式(仕様の「Verified ground truth」どおり)。
STOP_JSON='{"hook_event_name":"Stop","background_tasks":[],"cwd":"/tmp","effort":"medium","last_assistant_message":"done","permission_mode":"default","prompt_id":"p1","session_crons":[],"session_id":"sess-abc123","stop_hook_active":false,"transcript_path":"/tmp/transcript.jsonl"}'
HOOK_OUT="$(mktemp)"
set +e
printf '%s' "$STOP_JSON" | "$BRIDGE" --hook-event --card "$CARD5" --root "$ROOT5" > "$HOOK_OUT"
HOOK_STATUS=$?
set -e
[ "$HOOK_STATUS" = "0" ] || fail "hook-event mode exited non-zero ($HOOK_STATUS) on a Stop event"
[ -s "$HOOK_OUT" ] && fail "hook-event mode wrote to stdout (must stay silent inside the user's session)"
STATE_FILE="$ROOT5/cards/$CARD5/agent-hook-state.json"
[ -f "$STATE_FILE" ] || fail "hook-event mode did not write agent-hook-state.json for a Stop event"
grep -q '"state":"idle"' "$STATE_FILE" || fail "Stop event should map to state idle (got: $(cat "$STATE_FILE"))"
grep -q '"event":"Stop"' "$STATE_FILE" || fail "state file missing the source event name"
grep -q '"sessionID":"sess-abc123"' "$STATE_FILE" || fail "state file missing sessionID"

# 壊れた JSON でも exit 0・stdout 無し・状態ファイルを書かないこと(純観測: 失敗は握って諦める)。
ROOT6="$(mktemp -d)"
CARD6="77777777-7777-7777-7777-777777777777"
mkdir -p "$ROOT6/cards/$CARD6"
BAD_OUT="$(mktemp)"
set +e
printf 'not valid json{{{' | "$BRIDGE" --hook-event --card "$CARD6" --root "$ROOT6" > "$BAD_OUT"
BAD_STATUS=$?
set -e
[ "$BAD_STATUS" = "0" ] || fail "hook-event mode exited non-zero ($BAD_STATUS) on malformed JSON"
[ -s "$BAD_OUT" ] && fail "hook-event mode wrote to stdout on malformed JSON"
[ -f "$ROOT6/cards/$CARD6/agent-hook-state.json" ] && fail "malformed JSON should not produce a state file" || true

echo "fleet-bridge protocol test: OK"
