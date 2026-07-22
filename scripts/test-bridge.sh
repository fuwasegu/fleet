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

# 上限超えの巨大ノートが memory.jsonl に書かれていないこと(hello-ci + decision の2行)
LINES="$(wc -l < "$ROOT/channels/$CHAN/memory.jsonl" | tr -d ' ')"
[ "$LINES" = "2" ] || fail "oversized note should not be persisted (memory has $LINES lines)"
grep -q '"kind":"decision"'       "$ROOT/channels/$CHAN/memory.jsonl" || fail "kind not persisted"

# board-intents に create + move の2行
BINT="$ROOT/channels/$CHAN/board-intents.jsonl"
[ -f "$BINT" ] || fail "board-intents.jsonl not created"
[ "$(wc -l < "$BINT" | tr -d ' ')" = "2" ] || fail "expected 2 board intents"
grep -q '"kind":"create_card"'    "$BINT" || fail "create_card intent missing"
grep -q '"kind":"move_card"'      "$BINT" || fail "move_card intent missing"
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

echo "fleet-bridge protocol test: OK"
