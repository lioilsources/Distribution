# Distribution

Centralizované CI/CD assets pro všechny Flutter projekty.  
Secrets se nastavují skriptem — jednou za app, pak se vše tahá z Bitwardenu nebo odsud.

---

## Adresářová struktura

```
Distribution/
├── Android/
│   └── <AppName>/
│       └── upload-keystore.jks      ← podpisový keystore pro Google Play
├── Apple/
│   ├── Key/
│   │   └── AuthKey_<KeyID>.p8       ← sdílený App Store Connect API klíč
│   └── <AppName>/
│       └── *.mobileprovision        ← App Store Distribution profil pro danou appku
└── scripts/
    └── setup-gh-secrets.sh          ← nastaví GitHub Actions secrets
```

---

## Co je sdílené (jednou za developer account)

Už nastaveno, není potřeba řešit pro každou appku.

| Co | Kde |
|----|-----|
| iOS Distribution Certificate (`.p12`) | Bitwarden → `CI / IOS_P12_BASE64` |
| Heslo k certifikátu | Bitwarden → `CI / IOS_P12_PASSWORD` |
| Keychain password | Bitwarden → `CI / IOS_KEYCHAIN_PASSWORD` |
| Apple Team ID | Bitwarden → `CI / IOS_TEAM_ID` |
| App Store Connect API Issuer ID | Bitwarden → `CI / ASC_API_ISSUER_ID` |
| App Store Connect API Key ID | Bitwarden → `CI / ASC_API_KEY_ID` |
| App Store Connect API Private Key | `Apple/Key/AuthKey_<KeyID>.p8` |

---

## Checklist pro novou appku

### iOS

1. **Vytvoř App ID** na [developer.apple.com](https://developer.apple.com)  
   → Identifiers → `+` → App IDs → zadej bundle ID (např. `com.ol1n.mojeapp`)

2. **Vytvoř App Store Distribution provisioning profile**  
   → Profiles → `+` → Distribution → App Store → vyber App ID → stáhni

3. **Ulož profil sem:**
   ```
   Apple/<AppName>/<cokoliv>.mobileprovision
   ```

4. **Vytvoř appku v App Store Connect**  
   → [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps → `+`  
   (nutné aby TestFlight upload prošel)

### Android

Nic nepřipravuješ — skript vygeneruje keystore automaticky, uloží ho do:
```
Android/<AppName>/upload-keystore.jks
```
a zároveň vytvoří Bitwarden položku `<AppName> Android Signing` s těmito poli:

| Pole BW | Obsah |
|---------|-------|
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEYSTORE_PASSWORD` | vygenerované heslo |
| `ANDROID_KEY_PASSWORD` | shodné s heslem |
| `ANDROID_KEYSTORE_BASE64` | base64 keystore souboru |

> **Důležité:** Keystore **nikdy nesmaž** — Google Play ho vyžaduje pro všechny budoucí updaty.

---

## Spuštění skriptu

### Prerekvizity

```bash
# BW_SESSION musí být exportovaný (ne jen nastavený)
export BW_SESSION=$(bw unlock --raw)
```

Bez `export` script proměnnou nevidí a zeptá se na heslo znovu.

### Spuštění

```bash
cd /Users/ol1n/Dev/Distribution
./scripts/setup-gh-secrets.sh --repo <owner/repo> --app <AppName>
```

`--app` použij pokud se název složky liší od názvu repozitáře.

### Příklady

```bash
# Kiran (složky se jmenují Kirian)
./scripts/setup-gh-secrets.sh --repo lioilsources/Kiran --app Kirian

# MirrorBooth (název složky = název repo)
./scripts/setup-gh-secrets.sh --repo lioilsources/MirrorBooth
```

### Nastavené GitHub secrets

Po spuštění skript nastaví těchto 12 secrets:

| Secret | Zdroj |
|--------|-------|
| `IOS_P12_BASE64` | Bitwarden |
| `IOS_P12_PASSWORD` | Bitwarden |
| `IOS_KEYCHAIN_PASSWORD` | Bitwarden |
| `IOS_TEAM_ID` | Bitwarden |
| `APPSTORE_ISSUER_ID` | Bitwarden |
| `APPSTORE_API_KEY_ID` | Bitwarden |
| `APPSTORE_API_PRIVATE_KEY` | `Apple/Key/AuthKey_*.p8` |
| `IOS_PROVISION_PROFILE_BASE64` | `Apple/<AppName>/*.mobileprovision` |
| `ANDROID_KEYSTORE_BASE64` | `Android/<AppName>/upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Bitwarden → `<AppName> Android Signing` |
| `ANDROID_KEY_ALIAS` | `upload` (default) |
| `ANDROID_KEY_PASSWORD` | shodné s `ANDROID_KEYSTORE_PASSWORD` |

---

## HOW-TO: Nová appka (checklist)

Pořadí kroků je důležité — provisioning profile musí existovat **před** spuštěním `setup-gh-secrets.sh`.

### Krok 1 — Apple Developer Portal (manuálně)

- [ ] **App ID**: [developer.apple.com](https://developer.apple.com) → Certificates, IDs & Profiles → Identifiers → `+` → App IDs → zadej bundle ID (např. `com.ol1n.mojeapp`)
- [ ] **Provisioning profile**: Profiles → `+` → Distribution → App Store → vyber App ID → stáhni
- [ ] **Ulož sem**: `Apple/<AppName>/<cokoliv>.mobileprovision`

### Krok 2 — App Store Connect (manuálně)

- [ ] [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps → `+` → New App
- [ ] Platform: iOS, Bundle ID z dropdownu (musí existovat z kroku 1), SKU: např. `ol1nmojeapp`
- [ ] Ikona: App Information → App Icon (1024×1024 px, bez alfa kanálu, PNG)

### Krok 3 — Google Play Console (manuálně)

- [ ] [play.google.com/console](https://play.google.com/console) → Create app → vyplň základní info
- [ ] Lokálně sestav release AAB: `flutter build appbundle --release` (v adresáři appky)
- [ ] Nahraj AAB manuálně: Internal Testing → Create release  
  _(Google Play vyžaduje první upload manuálně, teprve pak funguje API/CI)_

### Krok 4 — Firebase App Distribution (pro internal testing)

- [ ] [console.firebase.google.com](https://console.firebase.google.com) → přidej Android app (package name = bundle ID)
- [ ] Stáhni `google-services.json` → ulož do `<AppDir>/android/app/google-services.json`
- [ ] Project Settings → Service Accounts → vygeneruj klíč JSON → nastav GitHub secret `FIREBASE_SERVICE_ACCOUNT_KEY`
- [ ] Project Settings → Your apps → App ID (tvar `1:xxx:android:xxx`) → nastav GitHub secret `FIREBASE_ANDROID_APP_ID`

```bash
gh secret set FIREBASE_ANDROID_APP_ID --repo lioilsources/<AppName> --body "1:xxx:android:xxx"
gh secret set FIREBASE_SERVICE_ACCOUNT_KEY --repo lioilsources/<AppName> < service-account.json
```

### Krok 5 — Align CI/CD workflows (skripty)

```bash
cd /Users/ol1n/Dev/Distribution

# CI workflow — align-project.sh ho nekopíruje, přidej ručně
cp /Users/ol1n/Dev/GitHub/Kiran/.github/workflows/ci.yml \
   /Users/ol1n/Dev/GitHub/<AppName>/.github/workflows/

# Release workflows — app-dir je "." pokud appka není v subdirectory
./scripts/align-project.sh \
  --target /Users/ol1n/Dev/GitHub/<AppName> \
  --app-dir <app-dir> \
  --app-name <AppName> \
  --bundle-id com.ol1n.<bundleid> \
  --repo lioilsources/<AppName>
```

### Krok 6 — GitHub secrets (skript)

```bash
export BW_SESSION=$(bw unlock --raw)
./scripts/setup-gh-secrets.sh --repo lioilsources/<AppName> --app <AppName>
```

> Pokud se název složky v Distribution liší od názvu repozitáře, použij `--app <FolderName>`.

Po spuštění pro novou appku commitni vygenerovaný keystore:

```bash
git add Android/<AppName>/ && git commit -m "Add Android keystore for <AppName>"
```

> ⚠️ **Keystore nikdy nesmaž** — Google Play ho vyžaduje pro všechny budoucí updates.

### Krok 7 — Test release

```bash
git -C /Users/ol1n/Dev/GitHub/<AppName> tag v0.1.0-alpha
git -C /Users/ol1n/Dev/GitHub/<AppName> push origin v0.1.0-alpha
# Sleduj průběh: github.com/lioilsources/<AppName>/actions
```

---

## Přehled všech appek

| App | `--app-dir` | `--app` | `--bundle-id` |
|-----|-------------|---------|----------------|
| Kiran | `tyrian_mobile` | `Kirian` | `com.ol1n.kiran` |
| MirrorBooth | `mirrorbooth` | `MirrorBooth` | `com.ol1n.mirrorbooth` |
| PoetryStream | `poetry_stream` | `PoetryStream` | `com.ol1n.poetrystream` |
| DuolingoCards | `.` | `DuolingoCards` | `com.ol1n.duolingoCards` |
| SwypeKids | `.` | `SwypeKids` | `com.ol1n.swypeKids` |
