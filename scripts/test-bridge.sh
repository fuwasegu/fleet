#!/usr/bin/env bash
# fleet-bridge(MCP サーバ)の JSON-RPC プロトコルをライブ claude 無しで検証する。
# 使い方: scripts/test-bridge.sh <path-to-fleet-bridge>
set -euo pipefail
BRIDGE="${1:?usage: test-bridge.sh <fleet-bridge>}"
CH="$(mktemp -d)/ch"; mkdir -p "$CH"
echo '["cardA","cardB"]' > "$CH/peers.json"
OUT="$(mktemp)"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fleet_remember","arguments":{"text":"hello-ci"}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fleet_recall","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fleet_peers","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":6,"method":"nonsense/method"}'
} | FLEET_CARD="cardA" "$BRIDGE" --channel "$CH" > "$OUT"

fail() { echo "FAIL: $1"; echo "--- output ---"; cat "$OUT"; exit 1; }
grep -q '"serverInfo"'          "$OUT" || fail "initialize missing serverInfo"
grep -q 'fleet_recall'          "$OUT" || fail "tools/list missing fleet_recall"
grep -q 'fleet_remember'        "$OUT" || fail "tools/list missing fleet_remember"
grep -q 'fleet_peers'           "$OUT" || fail "tools/list missing fleet_peers"
grep -q 'Saved to shared memory' "$OUT" || fail "remember not saved"
grep -q 'hello-ci'              "$OUT" || fail "recall did not return remembered text"
grep -q 'cardB'                 "$OUT" || fail "peers did not list cardB"
grep -q '"code":-32601'         "$OUT" || fail "unknown method not rejected"
echo "fleet-bridge protocol test: OK"
