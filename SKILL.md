# SKILL: Nová Flutter appka → Firebase (Android) + TestFlight (iOS)

Kompletní postup od nuly. Předpokládá existující Flutter projekt v `lioilsources/<AppName>`.

---

## Prerekvizity (jednou za developer account — už hotovo)

- iOS Distribution Certificate → **zdroj pravdy = Bitwarden poznámka `CI / IOS_P12_BASE64`**
  (sdílená pro všechny appky). Soubor `Apple/_Keys/distribution.p12` je jen záloha a může
  být stale — skript ho **nepoužívá**.
- App Store Connect API Key (`AuthKey_5YH964A9M4.p8`) → `Apple/_Keys/`
- Apple Team ID: `P82HWPG7FN`
- ASC Issuer ID: `edeaacd0-9ce8-4fae-91b7-e451efabc799`
- **OpenSSL 3** (`brew install openssl@3`) — skript ho potřebuje pro validaci p12.
  Systémový `openssl` na macOS je **LibreSSL** a moderní (Keychain-exportované)
  p12 neumí dešifrovat → hlásí "wrong password" i pro správné heslo. Viz Troubleshooting.

---

## Krok 1 — Apple Developer Portal (manuálně, ~5 min)

**URL:** https://developer.apple.com → Certificates, IDs & Profiles

### 1a. App ID
→ Identifiers → `+` → App IDs → App → Continue  
→ Bundle ID: `com.ol1n.<appname>` (Explicit)  
→ Capabilities: nic speciálního  
→ Register

### 1b. Provisioning Profile
→ Profiles → `+` → Distribution → App Store → Continue  
→ App ID: vyber `com.ol1n.<appname>`  
→ Name: např. `<AppName> AppStore`  
→ Generate → Download → ulož sem:

```bash
Apple/<AppName>/<cokoliv>.mobileprovision
```

---

## Krok 2 — App Store Connect (manuálně, ~3 min)

**URL:** https://appstoreconnect.apple.com → My Apps → `+` → New App

| Pole | Hodnota |
|------|---------|
| Platform | iOS |
| Name | <AppName> (jak se bude jmenovat v App Store) |
| Primary Language | Czech nebo English |
| Bundle ID | `com.ol1n.<appname>` (z dropdownu, musí existovat z kroku 1) |
| SKU | `ol1n<appname>` (lowercase, bez mezer) |

> **Proč:** TestFlight upload selže s `409 Conflict` pokud appka neexistuje v ASC.

---

## Krok 3 — Firebase App Distribution (manuálně, ~5 min)

**URL:** https://console.firebase.google.com

1. Vyber nebo vytvoř Firebase projekt
2. Add app → Android → Package name: `com.ol1n.<appname>`
3. Stáhni `google-services.json` → ulož do `<AppDir>/android/app/google-services.json`
4. Project Settings → Service Accounts → **Generate new private key** → ulož JSON

```bash
# Nastav secrets
gh secret set FIREBASE_ANDROID_APP_ID \
  --repo lioilsources/<AppName> \
  --body "1:XXXXXXXXXX:android:XXXXXXXXXX"

gh secret set FIREBASE_SERVICE_ACCOUNT_KEY \
  --repo lioilsources/<AppName> \
  < /path/to/firebase-service-account.json
```

App ID najdeš: Project Settings → Your apps → Android app → App ID

---

## Krok 4 — project.pbxproj (jednou za appku, lokálně)

Zkontroluj Release konfiguraci Runner targetu:

```bash
grep -n "CODE_SIGN_IDENTITY\|CODE_SIGN_STYLE\|PROVISIONING_PROFILE_SPECIFIER\|DEVELOPMENT_TEAM" \
  <AppDir>/ios/Runner.xcodeproj/project.pbxproj
```

**Funkční přístup (ověřeno na SwypeKids): podpis NE v projektu, ale až při exportu.**
Runner target v Release má jen **automatic** signing — aby šel lokální `flutter run`:

```
CODE_SIGN_STYLE = Automatic;
DEVELOPMENT_TEAM = P82HWPG7FN;
```

> ❌ **Nedávej do projektu manuální podpis** (`CODE_SIGN_STYLE = Manual` +
> `PROVISIONING_PROFILE_SPECIFIER`). S placeholderem (`CI_PROFILE_NAME`) rozbiješ
> lokální `flutter run` (`"Runner" requires a provisioning profile`).
>
> ❌ **A nepředávej podpis ani jako globální `xcodebuild` build settings**
> (`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=... PROVISIONING_PROFILE_SPECIFIER=...`).
> Aplikuje se to na **všechny targety včetně CocoaPods** → archive selže na
> `Pods-Runner / flutter_tts does not support provisioning profiles`.

**Místo toho CI:**
1. **archivuje bez podpisu** — `xcodebuild archive ... DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGNING_ALLOWED=NO`
2. **podepíše až při exportu** — `xcodebuild -exportArchive -exportOptionsPlist ios/ExportOptions.plist`

Potřebuješ `ios/ExportOptions.plist` (CI do něj jen doplní teamID a jméno profilu):

```xml
<key>method</key><string>app-store</string>
<key>teamID</key><string>P82HWPG7FN</string>
<key>signingStyle</key><string>manual</string>
<key>provisioningProfiles</key>
<dict><key>com.ol1n.<appname></key><string><jméno profilu></string></dict>
```

> Pozn.: `align-project.sh` zatím generuje starý placeholder+sed přístup — při dalším
> setupu ho srovnej na tenhle (automatic v projektu + archive `CODE_SIGNING_ALLOWED=NO`
> + export přes plist).

---

## Krok 5 — Workflows (skripty, ~2 min)

```bash
cd /Users/ol1n/Dev/Distribution

# Zkopíruj CI workflow (lint, testy)
cp /Users/ol1n/Dev/GitHub/Kiran/.github/workflows/ci.yml \
   /Users/ol1n/Dev/GitHub/<AppName>/.github/workflows/

# Přizpůsob release workflows
# --app-dir je "." pokud Flutter kód je v root (ne v subdirectory)
./scripts/align-project.sh \
  --target /Users/ol1n/Dev/GitHub/<AppName> \
  --app-dir <app-dir> \
  --app-name <AppName> \
  --bundle-id com.ol1n.<bundleid> \
  --repo lioilsources/<AppName>
```

Výsledek: přepíše `.github/workflows/release-ios.yml` a `release-android.yml`.

---

## Krok 6 — GitHub Secrets (skript, ~2 min)

```bash
export BW_SESSION=$(bw unlock --raw)
./scripts/setup-gh-secrets.sh --repo lioilsources/<AppName> --app <AppName>
```

Skript dnes:
- **iOS p12 base64 bere ze sdílené Bitwarden poznámky** `CI / IOS_P12_BASE64`
  (stejná hodnota pro všechny appky, ověřeně funguje v CI). **NEBER ho z volného
  souboru** `Apple/_Keys/distribution.p12` — ten může být starý/jiný export, jehož
  heslo už nesedí, a tiše rozbije podpis. (Pravidlo: zdroj pravdy je BW poznámka.)
- **Validuje p12 přes OpenSSL 3** (`openssl pkcs12`) — keychain-free a spolehlivý.
  ⚠️ **Nevaliduj přes `security import` do čerstvé klíčenky** — ta je zamčená, takže
  selže i pro správné heslo (falešný negativ). OpenSSL 3 = `brew install openssl@3`,
  systémový macOS `openssl` (LibreSSL) moderní p12 neumí.
- **Keystore validuje přes `keytool -list`** (heslo + alias) ze souboru `.jks`.
- **Issuer ID nastaví sám** (s hardcoded fallbackem), a to pod **oběma** názvy:
  `APPSTORE_ISSUER_ID` i `APP_STORE_CONNECT_API_ISSUER_ID` — ruční krok už netřeba.

> Když validace umře: u iOS nesedí pár `CI / IOS_P12_BASE64` + `CI / IOS_P12_PASSWORD`
> v Bitwardenu (musí být ze stejného exportu certu). U Androidu nesedí
> `<AppName> Android Signing` heslo na `.jks`. Oprav v BW, nebo (Android) přegeneruj
> keystore — pozor: **nelze** pokud už appka je na Google Play (viz níže). Pak spusť znovu.
>
> **Pozn.:** Když appka padá v CI na `passphrase not correct`, ale jiné appky jedou,
> jsou jen **stale GitHub secrety** té appky — stačí pustit tento skript, přepíše je
> aktuální (správnou) hodnotou z BW.

Commitni vygenerovaný Android keystore:

```bash
git -C /Users/ol1n/Dev/Distribution add Android/<AppName>/
git -C /Users/ol1n/Dev/Distribution commit -m "Add Android keystore for <AppName>"
```

> ⚠️ **Keystore nikdy nesmaž** — Google Play ho vyžaduje pro všechny budoucí updaty.

---

## Krok 7 — Ověřit secrets

```bash
gh secret list --repo lioilsources/<AppName>
```

Musí existovat (minimálně):

| Secret | Zdroj |
|--------|-------|
| `IOS_P12_BASE64` | Bitwarden poznámka `CI / IOS_P12_BASE64` (sdílený; **ne** soubor) |
| `IOS_P12_PASSWORD` | Bitwarden `CI / IOS_P12_PASSWORD` — musí být ze stejného exportu jako base64 |
| `IOS_KEYCHAIN_PASSWORD` | Bitwarden (sdílený) |
| `IOS_PROVISION_PROFILE_BASE64` | `Apple/<AppName>/*.mobileprovision` |
| `APPSTORE_ISSUER_ID` | skript (`edeaacd0-9ce8-4fae-91b7-e451efabc799`) |
| `APP_STORE_CONNECT_API_ISSUER_ID` | skript (stejná hodnota — workflow čte tento název) |
| `APP_STORE_CONNECT_API_KEY_ID` | `5YH964A9M4` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | base64 z `Apple/_Keys/AuthKey_5YH964A9M4.p8` |
| `ANDROID_KEYSTORE_BASE64` | `Android/<AppName>/upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Bitwarden → `<AppName> Android Signing` |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | shodné s heslem |
| `FIREBASE_ANDROID_APP_ID` | Firebase console (krok 3) |
| `FIREBASE_SERVICE_ACCOUNT_KEY` | Firebase console (krok 3) |

---

## Krok 8 — Commit + první tag

```bash
cd /Users/ol1n/Dev/GitHub/<AppName>

# Commitni všechny workflow změny
git add .github/
git commit -m "ci: add release workflows for Firebase + TestFlight"
git push origin main

# Vytvoř první release tag
git tag v0.1.0-alpha
git push origin v0.1.0-alpha
```

---

## Krok 9 — Sledování CI

```bash
# Zobraz aktuální runs
gh run list --repo lioilsources/<AppName> --limit 5

# Sleduj konkrétní run
gh run watch <RUN_ID> --repo lioilsources/<AppName>

# Logy failnutého kroku
gh run view --log-failed --job=<JOB_ID> --repo lioilsources/<AppName>
```

---

## Co dělat když to selže

### iOS — Archive selže

**Příznak:** `Pods-Runner does not support provisioning profiles` /
`flutter_tts does not support provisioning profiles, but provisioning profile ... has been manually specified`
→ Předáváš podpis jako **globální** `xcodebuild` build settings, takže leze i na
CocoaPods targety. **Archivuj bez podpisu a podepiš až při exportu** (viz Krok 4):
```bash
xcodebuild archive ... DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGNING_ALLOWED=NO
xcodebuild -exportArchive -archivePath ... -exportOptionsPlist ios/ExportOptions.plist -exportPath ...
```

**Příznak:** `"Runner" requires a provisioning profile` (lokálně i v CI)
→ V projektu je manuální podpis s placeholderem `CI_PROFILE_NAME`. Přepni Runner
Release na `CODE_SIGN_STYLE = Automatic` (viz Krok 4).

> Pozn.: Starý přístup (manuální podpis v `project.pbxproj` + sed-inject `CI_PROFILE_NAME`
> → UUID) je **opuštěný** — rozbíjel lokální buildy. Pokud na něj narazíš ve starší
> appce, migruj na automatic-v-projektu + export-přes-plist.

### iOS i Android — binárka se v CI nedá dekódovat (`gh secret set --body -` bug)

**Příznak:** iOS `security: ... Unable to decode the provided data`, **nebo** Android
`Failed to read key ... Tag number over 30 is not supported`. Tj. dekódovaný p12/jks
je **garbage**, ne špatné heslo.

**Příčina:** secret se nahrál jako doslova `-`. `gh secret set NAME --body -` **nepíše
ze stdin** — `--body` bere hodnotu doslova (čte stdin jen když `--body` úplně chybí),
takže `-` se uloží jako jednoznakový secret a `base64 --decode "-"` = garbage.

**Fix:** ve `gh_secret` posílej hodnotu pipou a `--body` vynech:
```bash
printf '%s' "$value" | gh secret set "$name" --repo "$REPO"   # ✅
# NE:  ... | gh secret set "$name" --repo "$REPO" --body -      # ❌ uloží "-"
```
Ověř délku po nahrání (např. base64 certu má mít tisíce znaků, ne 1).

### iOS — Import signing certificate selže

**Příznak:** `security: SecKeychainItemImport: The user name or passphrase you entered is not correct.`
→ Na GitHubu jsou **stale secrety** té appky — `IOS_P12_BASE64`/`IOS_P12_PASSWORD`
byly nastavené dřív s jinou hodnotou. Fix: spusť `setup-gh-secrets.sh`, přepíše je
aktuální (sdílenou) hodnotou z BW. Když jiné appky (MirrorBooth/Kiran) jedou, je to
skoro jistě tohle — pár v BW je v pořádku.

**Ověř pár v BW lokálně** (skript `diag-ios-p12.sh`, nebo ručně) — POZOR na dvě pasti:
```bash
# 1) Systémový openssl je LibreSSL → moderní p12 neumí, hlásí "invalid password" i pro správné heslo!
#    Vždy použij OpenSSL 3:
OSSL=$(brew --prefix openssl@3)/bin/openssl
# 2) Heslo i base64 ber z BW (NE z volného souboru distribution.p12 — ten bývá stale):
B64=$(bw get notes "CI / IOS_P12_BASE64"); PW=$(bw get password "CI / IOS_P12_PASSWORD")
T=$(mktemp); printf '%s' "$B64" | base64 --decode > "$T"
"$OSSL" pkcs12 -in "$T" -passin pass:"$PW" -noout && echo OK || echo BAD; rm -f "$T"
# u starších p12 případně přidej -legacy
```
> ❌ **Nevaliduj přes `security import` do čerstvé klíčenky** — nově vytvořená klíčenka
> je zamčená → import selže i pro správné heslo (falešný negativ). Buď OpenSSL 3, nebo
> klíčenku po `create-keychain` ještě `unlock-keychain`.

### Android — Build release AAB selže na podpisu

**Příznak:** `Failed to read key ... from store ...: keystore password was incorrect`
→ `ANDROID_KEYSTORE_PASSWORD` nesedí na `upload-keystore.jks` (typicky: keystore
přegenerován, ale Bitwarden položka `<AppName> Android Signing` zůstala stará — nebo
naopak). Skript to dnes chytí přes `keytool -list` ještě před pushnutím.

**Ověř lokálně:**
```bash
keytool -list -keystore Android/<AppName>/upload-keystore.jks \
  -storepass 'HESLO' -alias upload && echo OK || echo BAD
```
> ⚠️ Keystore **nepřegeneruj** pokud už je appka na Google Play (App Signing key musí
> zůstat stejný). Pak je jediná správná cesta opravit heslo v Bitwardenu na to pravé.

### iOS — TestFlight upload selže

**Příznak:** `Cannot determine the Apple ID from Bundle ID 'com.ol1n.<appname>' and platform 'IOS'. (19)`
→ **Appka neexistuje v App Store Connect.** Build i podpis prošly, jen není kam
nahrát. Vytvoř ji (Krok 2): ASC → My Apps → + → New App → Bundle ID `com.ol1n.<appname>`.
Pak re-trigger. (Stejná příčina jako `409 Conflict`.) API klíč/issuer jsou OK — kdyby
nebyly, chyba by byla o autentizaci, ne o Bundle ID.

**Příznak:** `Expected --api-issuer argument to have a value`
→ Issuer secret je prázdný/špatný. **Pozor na název:** workflow čte
`APP_STORE_CONNECT_API_ISSUER_ID`, ale starší skript nastavoval jen `APPSTORE_ISSUER_ID`.
Aktuální skript nastaví oba. Ověř, že existují oba a mají délku 36:
```bash
gh secret list --repo lioilsources/<AppName> | grep -i issuer
gh secret set APP_STORE_CONNECT_API_ISSUER_ID --repo ... --body "edeaacd0-9ce8-4fae-91b7-e451efabc799"
```

### Android — Firebase upload selže (HTTP 400)

**Příznak:** `Error: failed to ... release. HTTP Error: 400, Request contains an invalid argument.`
→ Dvě nejčastější příčiny:
1. **Špatné `FIREBASE_ANDROID_APP_ID`.** Musí přesně sedět s appkou v projektu —
   vezmi `mobilesdk_app_id` z `google-services.json` (tvar `1:NNN:android:XXX`):
   ```bash
   jq -r '.client[]|select(.client_info.android_client_info.package_name=="com.ol1n.<appname>")|.client_info.mobilesdk_app_id' \
     Android/<AppName>/google-services.json
   ```
2. **Skupina v `groups:` neexistuje** nebo má jiný **alias** (case-sensitive, ne
   zobrazované jméno). Firebase Console → App Distribution → Testers & groups.

### Android — Firebase upload přeskočen

**Příznak:** Firebase krok je `skipped`, přestože build proběhl  
→ GitHub Release krok selhal s `already_exists` (iOS workflow vytvořil release dřív).  
→ Přidej `continue-on-error: true` na krok "Upload to GitHub Release" v `release-android.yml`.

### Jak znovu spustit CI bez nového commitu

```bash
# Přetag existujícího tagu
git tag -f v0.1.0-alpha
git push origin v0.1.0-alpha --force

# Nebo ruční spuštění workflow
gh workflow run release-ios.yml --repo lioilsources/<AppName> --ref v0.1.0-alpha
gh workflow run release-android.yml --repo lioilsources/<AppName> --ref v0.1.0-alpha
```

---

## Hotovo — ověření výsledku

| Cíl | Kde zkontrolovat |
|-----|-----------------|
| Android → Firebase | Firebase console → App Distribution → Releases |
| iOS → TestFlight | App Store Connect → TestFlight → Builds (processing 10–30 min) |
| Artifacts | github.com/lioilsources/<AppName>/releases |
