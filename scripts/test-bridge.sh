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
grep -q 'cardB'                   "$OUT" || fail "peers did not list cardB"
grep -q 'blocked on: Do you want' "$OUT" || fail "peers did not surface blocked question"
# 自分(cardA)は fleet_peers に出ない。peers 整形は "- cardA [" 形式なのでそれで判定
# (recall の著者表記 "- [cardA · ..." とは別パターン)。
if grep -q -- '- cardA \[' "$OUT"; then fail "peers must exclude self (cardA)"; fi
grep -q 'Note too large'          "$OUT" || fail "oversized remember not rejected"
grep -q '"code":-32700'           "$OUT" || fail "malformed JSON did not return parse error"
grep -q '"code":-32601'           "$OUT" || fail "unknown method not rejected"

grep -q 'Sent to cardB'          "$OUT" || fail "fleet_message not acknowledged"
grep -q 'Status updated'         "$OUT" || fail "fleet_status not acknowledged"

# 上限超えの巨大ノートが memory.jsonl に書かれていないこと(1行=hello-ci のみ)
LINES="$(wc -l < "$ROOT/channels/$CHAN/memory.jsonl" | tr -d ' ')"
[ "$LINES" = "1" ] || fail "oversized note should not be persisted (memory has $LINES lines)"

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
