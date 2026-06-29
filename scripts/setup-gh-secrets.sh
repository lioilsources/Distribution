#!/usr/bin/env bash
# setup-gh-secrets.sh
#
# Populates GitHub Actions secrets for a Flutter project from Bitwarden + the
# centralized Distribution directory layout:
#
#   Distribution/
#   ├── Android/<AppName>/upload-keystore.jks
#   ├── Apple/Key/AuthKey_*.p8              (shared per developer account)
#   └── Apple/<AppName>/*.mobileprovision
#
# Prerequisites: gh, jq, keytool (JDK), bw (only for creating new BW items)
#
# Before first run — dump your Bitwarden vault to a cache file (once, in your terminal):
#   bw list items --pretty > ~/.bw_cache.json
# Refresh it any time secrets change. Default path: ~/.bw_cache.json
#
# Usage (run from anywhere):
#   /path/to/Distribution/scripts/setup-gh-secrets.sh \
#     --repo lioilsources/Kiran \
#     [--app Kirian]                  # override app folder name if differs from repo name
#     [--bw-cache /path/to/items.json]  # override cache file path
#
# All file paths are auto-resolved from the Distribution directory.
# CLI overrides (--provision-profile, --asc-private-key, --android-keystore) are
# still accepted to bypass auto-discovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── helpers ──────────────────────────────────────────────────────────────────
die()  { echo "❌  $*" >&2; exit 1; }
info() { echo "▶  $*"; }
ok()   { echo "✅  $*"; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
  done
}

# macOS system `openssl` is LibreSSL: it can't decrypt modern PBES2/AES p12s
# exported from Keychain and lacks -legacy, so it reports false "wrong password"
# results. Find a real OpenSSL 3 (Homebrew) for p12 validation.
OPENSSL3="$(
  for c in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
    command -v "$c" &>/dev/null && "$c" version 2>/dev/null | grep -q '^OpenSSL 3' && { echo "$c"; break; }
  done
)"

# validate_p12 <file> <password> → 0 if the password opens the cert.
# Uses OpenSSL 3 (keychain-free, reliable for modern Keychain-exported p12s).
# A throwaway `security import` keychain is NOT used here — a freshly created
# keychain is locked, so it yields false negatives regardless of the password.
# Falls back to `security` only when no OpenSSL 3 exists (non-macOS / no brew).
validate_p12() {
  local file="$1" pass="$2"
  if [[ -n "$OPENSSL3" ]]; then
    "$OPENSSL3" pkcs12 -in "$file" -passin pass:"$pass" -noout 2>/dev/null && return 0
    "$OPENSSL3" pkcs12 -in "$file" -passin pass:"$pass" -legacy -noout 2>/dev/null && return 0
    return 1
  fi
  local kc rc=1
  kc="$(mktemp -d)/validate.keychain-db"
  if security create-keychain -p tmp "$kc" >/dev/null 2>&1; then
    security unlock-keychain -p tmp "$kc" >/dev/null 2>&1
    security import "$file" -P "$pass" -k "$kc" -A >/dev/null 2>&1 && rc=0
    security delete-keychain "$kc" >/dev/null 2>&1
    return $rc
  fi
  return 0  # can't validate → don't block the run
}

gh_secret() {
  local name="$1" value="$2"
  # NOTE: do NOT pass `--body -`. gh treats `--body` as a literal string when
  # given (so `--body -` sets the secret to "-"!); it only reads stdin when
  # --body is omitted entirely. Pipe the value and leave --body off.
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
  ok "$name"
}

# All three lookup functions read from $BW_ITEMS (fetched once at startup).
bw_password() {
  local item_name="$1"
  echo "$BW_ITEMS" \
    | jq -r --arg n "$item_name" 'first(.[] | select(.name == $n)) | .login.password // .notes // empty'
}

bw_field() {
  local item_name="$1" field_name="$2"
  echo "$BW_ITEMS" \
    | jq -r --arg n "$item_name" --arg f "$field_name" \
        'first(.[] | select(.name == $n)) | (.fields // [])[] | select(.name == $f) | .value'
}

bw_notes() {
  local item_name="$1"
  echo "$BW_ITEMS" \
    | jq -r --arg n "$item_name" 'first(.[] | select(.name == $n)) | .notes // empty'
}

# ── arg parsing ───────────────────────────────────────────────────────────────
REPO=""
APP_NAME=""                  # defaults to repo basename; use --app to override
PROVISION_PROFILE=""         # auto-discovered if empty
ASC_PRIVATE_KEY=""           # auto-discovered if empty
ANDROID_KEYSTORE=""          # auto-discovered if empty
ANDROID_KEY_ALIAS="upload"
ANDROID_KEYSTORE_PASSWORD="" # looked up in BW or generated

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                      REPO="$2";                      shift 2 ;;
    --app)                       APP_NAME="$2";                  shift 2 ;;
    --provision-profile)         PROVISION_PROFILE="$2";         shift 2 ;;
    --asc-private-key)           ASC_PRIVATE_KEY="$2";           shift 2 ;;
    --android-keystore)          ANDROID_KEYSTORE="$2";          shift 2 ;;
    --android-key-alias)         ANDROID_KEY_ALIAS="$2";         shift 2 ;;
    --android-keystore-password) ANDROID_KEYSTORE_PASSWORD="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── validation ────────────────────────────────────────────────────────────────
require bw gh jq keytool

[[ -n "$REPO" ]] || die "--repo is required (e.g. lioilsources/Kiran)"

# ── Bitwarden: unlock + fetch vault ──────────────────────────────────────────
if [[ -z "${BW_SESSION:-}" ]]; then
  # --passwordenv obejde readline — heslo se nechytá přes subshell
  IFS= read -r -s -p "▶  Bitwarden master password: " _BW_PASS; echo
  export _BW_PASS
  BW_SESSION=$(bw unlock --passwordenv _BW_PASS --raw) \
    || die "Bitwarden unlock failed"
  unset _BW_PASS
  export BW_SESSION
fi

info "Fetching vault..."
BW_ITEMS=$(bw --session "$BW_SESSION" list items) \
  || die "Failed to fetch vault — session may have expired, unset BW_SESSION and retry"
ok "Vault loaded ($(echo "$BW_ITEMS" | jq length) items)"
echo ""

[[ -n "$APP_NAME" ]] || APP_NAME="${REPO##*/}"

info "Repo:     $REPO"
info "App name: $APP_NAME  (Distribution folder key)"
info "Dist dir: $DIST_DIR"
echo ""

# ── auto-discover file paths ──────────────────────────────────────────────────

# iOS provisioning profile
if [[ -z "$PROVISION_PROFILE" ]]; then
  PP_GLOB="$DIST_DIR/Apple/${APP_NAME}/*.mobileprovision"
  # shellcheck disable=SC2206
  PP_MATCHES=( $PP_GLOB )
  if [[ -f "${PP_MATCHES[0]}" ]]; then
    PROVISION_PROFILE="${PP_MATCHES[0]}"
    info "Auto-discovered provisioning profile: $PROVISION_PROFILE"
  fi
fi

# ASC private key
if [[ -z "$ASC_PRIVATE_KEY" ]]; then
  KEY_GLOB="$DIST_DIR/Apple/_Keys/AuthKey_*.p8"
  # shellcheck disable=SC2206
  KEY_MATCHES=( $KEY_GLOB )
  if [[ -f "${KEY_MATCHES[0]}" ]]; then
    ASC_PRIVATE_KEY="${KEY_MATCHES[0]}"
    info "Auto-discovered ASC private key: $ASC_PRIVATE_KEY"
  fi
fi

# Android keystore
if [[ -z "$ANDROID_KEYSTORE" ]]; then
  CANDIDATE="$DIST_DIR/Android/${APP_NAME}/upload-keystore.jks"
  if [[ -f "$CANDIDATE" ]]; then
    ANDROID_KEYSTORE="$CANDIDATE"
    info "Auto-discovered Android keystore: $ANDROID_KEYSTORE"
  fi
fi

echo ""

# ── 1. Shared iOS signing secrets from Bitwarden ─────────────────────────────
info "Reading shared iOS secrets from Bitwarden..."

P12_PASSWORD=$(bw_password "CI / IOS_P12_PASSWORD")
[[ -n "$P12_PASSWORD" ]] || die "Could not read CI / IOS_P12_PASSWORD from Bitwarden"

# The shared distribution cert lives in the Bitwarden note 'CI / IOS_P12_BASE64'
# (same value all apps use — proven working in CI). Do NOT read the loose
# Apple/_Keys/distribution.p12 file: it can be a stale/different export whose
# password no longer matches, which silently breaks signing.
P12_BASE64=$(bw_notes "CI / IOS_P12_BASE64")
[[ -n "$P12_BASE64" ]] || die "Could not read CI / IOS_P12_BASE64 from Bitwarden"

# Validate the password actually opens this cert (same check CI's security import does).
_P12_TMP="$(mktemp)"
if ! printf '%s' "$P12_BASE64" | base64 --decode > "$_P12_TMP" 2>/dev/null || ! validate_p12 "$_P12_TMP" "$P12_PASSWORD"; then
  rm -f "$_P12_TMP"
  die "IOS_P12_PASSWORD does not open the cert in CI / IOS_P12_BASE64. Both Bitwarden items must come from the same cert export."
fi
rm -f "$_P12_TMP"

KEYCHAIN_PASSWORD=$(bw_password "CI / IOS_KEYCHAIN_PASSWORD")
[[ -n "$KEYCHAIN_PASSWORD" ]] || die "Could not read CI / IOS_KEYCHAIN_PASSWORD from Bitwarden"

TEAM_ID=$(bw_password "CI / IOS_TEAM_ID")
[[ -n "$TEAM_ID" ]] || die "Could not read CI / IOS_TEAM_ID from Bitwarden"

gh_secret IOS_P12_BASE64        "$P12_BASE64"
gh_secret IOS_P12_PASSWORD      "$P12_PASSWORD"
gh_secret IOS_KEYCHAIN_PASSWORD "$KEYCHAIN_PASSWORD"
gh_secret IOS_TEAM_ID           "$TEAM_ID"

# ── 2. App Store Connect API secrets from Bitwarden ──────────────────────────
echo ""
info "Reading App Store Connect secrets from Bitwarden..."

_RAW_ISSUER=$(bw_password "CI / ASC_API_ISSUER_ID")
# Strip whitespace; treat jq "null" string as empty
ASC_ISSUER_ID="$(printf '%s' "${_RAW_ISSUER:-}" | tr -d '[:space:]')"
[[ "$ASC_ISSUER_ID" == "null" ]] && ASC_ISSUER_ID=""
# Validate UUID format: 8-4-4-4-12 lowercase hex with dashes
if [[ ! "$ASC_ISSUER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  _FALLBACK_ISSUER="edeaacd0-9ce8-4fae-91b7-e451efabc799"
  echo "⚠️   ASC_ISSUER_ID from Bitwarden is invalid (got: '${ASC_ISSUER_ID:-<empty>}')."
  echo "    Using hardcoded fallback: $_FALLBACK_ISSUER"
  echo "    → Fix: update Bitwarden item 'CI / ASC_API_ISSUER_ID' password field."
  ASC_ISSUER_ID="$_FALLBACK_ISSUER"
fi

ASC_KEY_ID=$(bw_password "CI / ASC_API_KEY_ID")
[[ -n "$ASC_KEY_ID" ]] || die "Could not read CI / ASC_API_KEY_ID from Bitwarden"

# Set both naming variants: old names for backwards compat, new names expected by workflow templates
gh_secret APPSTORE_ISSUER_ID              "$ASC_ISSUER_ID"
gh_secret APP_STORE_CONNECT_API_ISSUER_ID "$ASC_ISSUER_ID"
gh_secret APPSTORE_API_KEY_ID             "$ASC_KEY_ID"
gh_secret APP_STORE_CONNECT_API_KEY_ID    "$ASC_KEY_ID"

if [[ -n "$ASC_PRIVATE_KEY" ]]; then
  gh_secret APPSTORE_API_PRIVATE_KEY         "$(cat "$ASC_PRIVATE_KEY")"
  gh_secret APP_STORE_CONNECT_API_KEY_BASE64 "$(base64 < "$ASC_PRIVATE_KEY")"
else
  echo "⚠️   ASC private key not found — APPSTORE_API_PRIVATE_KEY / APP_STORE_CONNECT_API_KEY_BASE64 skipped"
  echo "    Expected: $DIST_DIR/Apple/_Keys/AuthKey_${ASC_KEY_ID}.p8"
fi

# ── 3. iOS provisioning profile ───────────────────────────────────────────────
echo ""
info "iOS provisioning profile..."

if [[ -n "$PROVISION_PROFILE" ]]; then
  PP_B64=$(base64 < "$PROVISION_PROFILE")
  gh_secret IOS_PROVISION_PROFILE_BASE64 "$PP_B64"
else
  echo "⚠️   Provisioning profile not found — IOS_PROVISION_PROFILE_BASE64 skipped"
  echo "    Expected: $DIST_DIR/Apple/${APP_NAME}/*.mobileprovision"
fi

# ── 4. Android keystore ───────────────────────────────────────────────────────
echo ""
info "Android keystore..."

if [[ -n "$ANDROID_KEYSTORE" ]]; then
  # Existing keystore — look up password in Bitwarden, then fall back to CLI arg
  _BW_HAD_ITEM=false
  if [[ -z "$ANDROID_KEYSTORE_PASSWORD" ]]; then
    ANDROID_KEYSTORE_PASSWORD=$(bw_field "${APP_NAME} Android Signing" "ANDROID_KEYSTORE_PASSWORD" 2>/dev/null || true)
    [[ -n "$ANDROID_KEYSTORE_PASSWORD" ]] && _BW_HAD_ITEM=true
  fi
  [[ -n "$ANDROID_KEYSTORE_PASSWORD" ]] \
    || die "Android keystore found but no password. Pass --android-keystore-password or add '${APP_NAME} Android Signing' item to Bitwarden."
  # Password came from CLI (not BW) — save it to Bitwarden now
  if [[ "$_BW_HAD_ITEM" == false ]] && [[ -n "${BW_SESSION:-}" ]]; then
    info "Saving password to Bitwarden as '${APP_NAME} Android Signing'..."
    BW_ITEM_JSON=$(jq -n \
      --arg name   "${APP_NAME} Android Signing" \
      --arg alias  "$ANDROID_KEY_ALIAS" \
      --arg pass   "$ANDROID_KEYSTORE_PASSWORD" \
      --arg ks_b64 "$(base64 < "$ANDROID_KEYSTORE")" \
      '{
        type: 2, name: $name, notes: null, favorite: false,
        secureNote: {type: 0},
        fields: [
          {type: 0, name: "ANDROID_KEY_ALIAS",         value: $alias},
          {type: 1, name: "ANDROID_KEYSTORE_PASSWORD",  value: $pass},
          {type: 1, name: "ANDROID_KEY_PASSWORD",       value: $pass},
          {type: 1, name: "ANDROID_KEYSTORE_BASE64",    value: $ks_b64}
        ]
      }')
    BW_ENCODED=$(printf '%s' "$BW_ITEM_JSON" | openssl base64 -A)
    bw --session "$BW_SESSION" create item "$BW_ENCODED" > /dev/null \
      && ok "Bitwarden: ${APP_NAME} Android Signing" \
      || echo "⚠️   Bitwarden item creation failed — save password manually: $ANDROID_KEYSTORE_PASSWORD"
  fi
else
  # Generate a new keystore and save it into the Distribution tree
  KEYSTORE_DIR="$DIST_DIR/Android/${APP_NAME}"
  mkdir -p "$KEYSTORE_DIR"
  ANDROID_KEYSTORE="$KEYSTORE_DIR/upload-keystore.jks"

  if [[ -z "$ANDROID_KEYSTORE_PASSWORD" ]]; then
    ANDROID_KEYSTORE_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 32 || true)
    echo "🔑  Generated keystore password: $ANDROID_KEYSTORE_PASSWORD"
    echo "    → Save in Bitwarden as '${APP_NAME} Android Signing' (field ANDROID_KEYSTORE_PASSWORD)"
  fi

  info "Generating $ANDROID_KEYSTORE ..."
  keytool -genkey -v \
    -keystore "$ANDROID_KEYSTORE" \
    -alias    "$ANDROID_KEY_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" \
    -keypass   "$ANDROID_KEYSTORE_PASSWORD" \
    -dname "CN=${APP_NAME}, OU=Mobile, O=${REPO%%/*}, L=Prague, ST=Prague, C=CZ" \
    -noprompt
  ok "Keystore generated: $ANDROID_KEYSTORE"

  # Save credentials to Bitwarden (requires BW_SESSION in env)
  info "Creating Bitwarden item '${APP_NAME} Android Signing'..."
  if [[ -z "${BW_SESSION:-}" ]]; then
    echo "⚠️   BW_SESSION not set — skipping Bitwarden item creation."
    echo "    Add manually: item '${APP_NAME} Android Signing' with field ANDROID_KEYSTORE_PASSWORD=${ANDROID_KEYSTORE_PASSWORD}"
  else
    BW_ITEM_JSON=$(jq -n \
      --arg name   "${APP_NAME} Android Signing" \
      --arg alias  "$ANDROID_KEY_ALIAS" \
      --arg pass   "$ANDROID_KEYSTORE_PASSWORD" \
      --arg ks_b64 "$(base64 < "$ANDROID_KEYSTORE")" \
      '{
        type: 2,
        name: $name,
        notes: null,
        favorite: false,
        secureNote: {type: 0},
        fields: [
          {type: 0, name: "ANDROID_KEY_ALIAS",         value: $alias},
          {type: 1, name: "ANDROID_KEYSTORE_PASSWORD",  value: $pass},
          {type: 1, name: "ANDROID_KEY_PASSWORD",       value: $pass},
          {type: 1, name: "ANDROID_KEYSTORE_BASE64",    value: $ks_b64}
        ]
      }')
    BW_ENCODED=$(printf '%s' "$BW_ITEM_JSON" | openssl base64 -A)
    bw --session "$BW_SESSION" create item "$BW_ENCODED" > /dev/null \
      && ok "Bitwarden: ${APP_NAME} Android Signing" \
      || echo "⚠️   Bitwarden item creation failed — save password manually: $ANDROID_KEYSTORE_PASSWORD"
  fi
fi

# Fail fast if the password/alias do not actually open the keystore — otherwise
# Gradle only reports "keystore password was incorrect" minutes later in CI.
keytool -list -keystore "$ANDROID_KEYSTORE" -storepass "$ANDROID_KEYSTORE_PASSWORD" -alias "$ANDROID_KEY_ALIAS" >/dev/null 2>&1 \
  || die "Keystore validation failed: password or alias '$ANDROID_KEY_ALIAS' do not match $ANDROID_KEYSTORE. The '${APP_NAME} Android Signing' values in Bitwarden are out of sync with this keystore file."
ok "Keystore verified ($ANDROID_KEYSTORE, alias $ANDROID_KEY_ALIAS)"

KEYSTORE_B64=$(base64 < "$ANDROID_KEYSTORE")

gh_secret ANDROID_KEYSTORE_BASE64   "$KEYSTORE_B64"
gh_secret ANDROID_KEYSTORE_PASSWORD "$ANDROID_KEYSTORE_PASSWORD"
gh_secret ANDROID_KEY_ALIAS         "$ANDROID_KEY_ALIAS"
gh_secret ANDROID_KEY_PASSWORD      "$ANDROID_KEYSTORE_PASSWORD"

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "All secrets set for $REPO"
echo "Verify: https://github.com/${REPO}/settings/secrets/actions"
