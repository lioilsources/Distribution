#!/usr/bin/env bash
# diag-ios-p12.sh — zjistí, jestli sdílený iOS cert v Bitwardenu sedí k heslu.
# Vypisuje jen délky a ✅/❌, žádné hodnoty secretů. Apple/iOS only.
set -uo pipefail

OSSL="$( { command -v /opt/homebrew/bin/openssl || command -v /usr/local/bin/openssl || command -v openssl; } 2>/dev/null | head -1 )"
[[ -n "$OSSL" ]] || { echo "❌ openssl nenalezen"; exit 1; }
echo "openssl: $("$OSSL" version)"

echo "▶  Čtu vault (zeptá se na master heslo)…"
ITEMS="$(bw list items)" || { echo "❌ bw list items selhalo"; exit 1; }

NOTE_B64="$(jq -r '.[]|select(.name=="CI / IOS_P12_BASE64")|.notes // empty'        <<<"$ITEMS")"
P12PW="$(jq    -r '.[]|select(.name=="CI / IOS_P12_PASSWORD")|.login.password // empty'      <<<"$ITEMS")"
KCPW="$(jq     -r '.[]|select(.name=="CI / IOS_KEYCHAIN_PASSWORD")|.login.password // empty' <<<"$ITEMS")"

echo "base64 délka: ${#NOTE_B64} | IOS_P12_PASSWORD délka: ${#P12PW} | IOS_KEYCHAIN_PASSWORD délka: ${#KCPW}"
[[ -n "$NOTE_B64" ]] || { echo "❌ CI / IOS_P12_BASE64 je prázdné nebo nenalezené"; exit 1; }

NOTE="$(mktemp)"; trap 'rm -f "$NOTE"' EXIT
printf '%s' "$NOTE_B64" | base64 --decode > "$NOTE" 2>/dev/null
echo "poznámka dekódována: $(wc -c <"$NOTE") B ($(file -b "$NOTE"))"

chk() {
  if "$OSSL" pkcs12 -in "$NOTE" -passin pass:"$1" -noout 2>/dev/null \
  || "$OSSL" pkcs12 -in "$NOTE" -passin pass:"$1" -legacy -noout 2>/dev/null; then
    echo "✅ $2"
  else
    echo "❌ $2"
  fi
}
chk "$P12PW" "BW poznámka p12 + IOS_P12_PASSWORD"
chk "$KCPW"  "BW poznámka p12 + IOS_KEYCHAIN_PASSWORD"
