# SKILL: Nová Flutter appka → Firebase (Android) + TestFlight (iOS)

Kompletní postup od nuly. Předpokládá existující Flutter projekt v `lioilsources/<AppName>`.

---

## Prerekvizity (jednou za developer account — už hotovo)

- iOS Distribution Certificate (`distribution.p12`) → `Apple/distribution.p12` + Bitwarden
- App Store Connect API Key (`AuthKey_5YH964A9M4.p8`) → `Apple/Key/`
- Apple Team ID: `P82HWPG7FN`
- ASC Issuer ID: `edeaacd0-9ce8-4fae-91b7-e451efabc799`

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

Release sekce **musí** obsahovat (všechny čtyři):

```
CODE_SIGN_IDENTITY = "Apple Distribution";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = P82HWPG7FN;
PROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";
```

Pokud chybí `CODE_SIGN_IDENTITY = "Apple Distribution"` v Release → přidej:

```bash
# Najdi řádek s CODE_SIGN_STYLE = Manual; v Release sekci a přidej nad něj
# Nebo edituj ručně v Xcode: Runner → Signing & Capabilities → Release → Manual
```

`CI_PROFILE_NAME` je placeholder — CI ho nahradí UUID profilu při každém buildu.

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

**Po skriptu:** okamžitě nastav Issuer ID ručně (Bitwarden položka je prázdná):

```bash
gh secret set APPSTORE_ISSUER_ID \
  --repo lioilsources/<AppName> \
  --body "edeaacd0-9ce8-4fae-91b7-e451efabc799"
```

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
| `IOS_P12_BASE64` | Bitwarden (sdílený) |
| `IOS_P12_PASSWORD` | Bitwarden (sdílený) |
| `IOS_KEYCHAIN_PASSWORD` | Bitwarden (sdílený) |
| `IOS_PROVISION_PROFILE_BASE64` | `Apple/<AppName>/*.mobileprovision` |
| `APPSTORE_ISSUER_ID` | **ručně** (`edeaacd0-9ce8-4fae-91b7-e451efabc799`) |
| `APP_STORE_CONNECT_API_KEY_ID` | `5YH964A9M4` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | base64 z `Apple/Key/AuthKey_5YH964A9M4.p8` |
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

**Příznak:** `No profile for team matching 'XYZ' found`  
→ Zkontroluj že inject kroku správně nahradil `CI_PROFILE_NAME` UUID:
```bash
grep PROVISIONING_PROFILE_SPECIFIER ios/Runner.xcodeproj/project.pbxproj
```
Musí obsahovat UUID (tvar `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`), ne jméno profilu.

**Příznak:** `project 'Runner' is damaged - parse error`  
→ Zkontroluj sed v inject kroku — musí mít **dvě expresky** (s i bez uvozovek):
```bash
sed -i '' \
  -e "s/\"CI_PROFILE_NAME\"/\"$PROFILE_UUID\"/g" \
  -e "s/CI_PROFILE_NAME/\"$PROFILE_UUID\"/g"
```

**Příznak:** `X has conflicting provisioning settings`  
→ Odstraň `CODE_SIGN_IDENTITY="Apple Distribution"` z xcodebuild příkazové řádky.
Toto nastavení musí být POUZE v `project.pbxproj` pro Runner target.

**Příznak:** `No signing certificate iOS Distribution found`  
→ `CODE_SIGN_IDENTITY = "Apple Distribution"` chybí v Release sekci `project.pbxproj`.

### iOS — TestFlight upload selže

**Příznak:** `Expected --api-issuer argument to have a value`  
→ Secret `APPSTORE_ISSUER_ID` je špatný. Ověř délku (musí být 36):
```bash
# Přidej do workflow dočasně:
echo "Issuer length: ${#CLEAN_ISSUER}"
```
Nastav ručně: `gh secret set APPSTORE_ISSUER_ID --repo ... --body "edeaacd0-9ce8-4fae-91b7-e451efabc799"`

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
