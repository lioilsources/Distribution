#!/usr/bin/env bash
# diag-ios-import.sh — replikuje přesně CI `security import` BW-note certu a zkusí
# opravu re-encodem do legacy (3DES/SHA1) formátu, který macOS `security` čte.
# Vypisuje jen exit kódy / hlášky, žádné hodnoty secretů. Apple/iOS only.
set -uo pipefail

OSSL="$( { command -v /opt/homebrew/bin/openssl || command -v /usr/local/bin/openssl; } 2>/dev/null | head -1 )"
[[ -n "$OSSL" ]] || { echo "❌ OpenSSL 3 nenalezen (brew install openssl@3)"; exit 1; }
echo "openssl: $("$OSSL" version)"

echo "▶  Čtu vault (zeptá se na master heslo)…"
ITEMS="$(bw list items)" || { echo "❌ bw list items selhalo"; exit 1; }
B64="$(jq -r '.[]|select(.name=="CI / IOS_P12_BASE64")|.notes // empty'        <<<"$ITEMS")"
PW="$(jq  -r '.[]|select(.name=="CI / IOS_P12_PASSWORD")|.login.password // empty' <<<"$ITEMS")"
[[ -n "$B64" && -n "$PW" ]] || { echo "❌ nenašel jsem base64 nebo heslo v BW"; exit 1; }

CUR="$(mktemp)"; NEW="$(mktemp)"; PEM="$(mktemp)"
trap 'rm -f "$CUR" "$NEW" "$PEM"' EXIT
printf '%s' "$B64" | base64 --decode > "$CUR" 2>/dev/null
echo "BW-note p12: $(wc -c <"$CUR") B ($(file -b "$CUR"))"

# Přesná replika CI importu
ci_import() {  # <p12-soubor>
  local f="$1" kc=/tmp/ci-import-test.keychain-db rc
  security delete-keychain "$kc" 2>/dev/null
  security create-keychain -p ci "$kc" >/dev/null 2>&1
  security set-keychain-settings -lut 21600 "$kc" >/dev/null 2>&1
  security unlock-keychain -p ci "$kc" >/dev/null 2>&1
  security import "$f" -P "$PW" -A -t cert -f pkcs12 -k "$kc" 2>&1; rc=$?
  security delete-keychain "$kc" 2>/dev/null
  return $rc
}

echo; echo "=== 1) CI import současného certu z BW ==="
if ci_import "$CUR"; then echo "✅ security import OK (problém je jinde)"; else echo "❌ security import SELHAL (viz hláška výše)"; fi

echo; echo "=== 2) re-encode do legacy (3DES/SHA1) a zkusit znovu ==="
if "$OSSL" pkcs12 -in "$CUR" -passin pass:"$PW" -nodes -out "$PEM" 2>/dev/null \
   || "$OSSL" pkcs12 -in "$CUR" -passin pass:"$PW" -nodes -legacy -out "$PEM" 2>/dev/null; then
  if "$OSSL" pkcs12 -export -in "$PEM" -passout pass:"$PW" -legacy \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$NEW" 2>/dev/null; then
    echo "re-encoded p12: $(wc -c <"$NEW") B"
    if ci_import "$NEW"; then
      echo "✅✅ legacy p12 SE NAIMPORTOVAL → tohle je oprava!"
      echo "    → nový base64 (vlož do BW poznámky CI / IOS_P12_BASE64):"
      echo "    base64 -i '$NEW'   # vypíše base64; ale soubor se po skončení smaže (trap)"
      echo "    Pokud chceš, spusť skript znovu s ULOZ=1 a uloží legacy p12 do ~/Desktop/distribution-legacy.p12"
      [[ "${ULOZ:-0}" == "1" ]] && { cp "$NEW" "$HOME/Desktop/distribution-legacy.p12"; echo "    ✅ uloženo: ~/Desktop/distribution-legacy.p12 (heslo zůstává stejné)"; }
    else
      echo "❌ ani legacy se nenaimportoval — problém není jen ve formátu"
    fi
  else
    echo "❌ re-export selhal"
  fi
else
  echo "❌ nepodařilo se extrahovat cert/klíč (špatné heslo?)"
fi
