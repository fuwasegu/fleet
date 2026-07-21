#!/usr/bin/env bash
# Fleet.app を自己署名する(TCC 許可を更新後も維持させるため)。
# 使い方: scripts/sign-app.sh <path-to-Fleet.app>
# 環境変数:
#   SIGNING_CERT_P12_BASE64  ... 署名用 .p12 を base64 化したもの
#   SIGNING_CERT_PASSWORD    ... その .p12 のパスワード
#   SIGNING_IDENTITY         ... 証明書名(省略時 "Fleet Self-Signed (fuwasegu)")
# secret 未設定なら署名せず正常終了(未署名のまま継続)。
set -euo pipefail
APP="${1:?usage: sign-app.sh <Fleet.app>}"

if [ -z "${SIGNING_CERT_P12_BASE64:-}" ] || [ -z "${SIGNING_CERT_PASSWORD:-}" ]; then
  echo "signing: 証明書 secret 未設定 → 署名スキップ(未署名で継続)"
  exit 0
fi

IDENTITY="${SIGNING_IDENTITY:-Fleet Self-Signed (fuwasegu)}"
WORK="$(mktemp -d)"
KC="$WORK/fleet-sign.keychain-db"
KCPW="$(openssl rand -hex 12)"
CERT="$WORK/cert.p12"
cleanup() {
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v "$(basename "$KC")") 2>/dev/null || true
  security delete-keychain "$KC" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$CERT"
security create-keychain -p "$KCPW" "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$CERT" -k "$KC" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

echo "signing: $APP を '$IDENTITY' で署名"
codesign --force --deep --timestamp=none --sign "$IDENTITY" --keychain "$KC" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "signing: designated requirement →"
codesign -d -r- "$APP" 2>&1 | grep designated || true
echo "signing: 完了"
