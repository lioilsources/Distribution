# CLAUDE.md — Distribution

Tento soubor popisuje klíčové poznatky, pasti a pravidla pro práci s CI/CD v tomto repozitáři.
Čte ho Claude Code při každém sezení.

---

## Struktura repozitáře

```
Distribution/
├── Apple/
│   ├── Key/AuthKey_5YH964A9M4.p8   ← ASC API klíč (sdílený, všechny appky)
│   ├── distribution.p12             ← iOS Distribution certifikát (sdílený)
│   └── <AppName>/*.mobileprovision  ← provisioning profil pro danou appku
├── Android/
│   └── <AppName>/upload-keystore.jks
├── scripts/
│   ├── setup-gh-secrets.sh          ← nastaví 12+ GitHub secrets
│   └── align-project.sh             ← zkopíruje a přizpůsobí workflow šablony
└── workflows/                       ← šablony (zdroj pravdy pro release-ios.yml, release-android.yml)
```

### Přehled appek

| App | repo | `--app-dir` | `--app` | bundle-id |
|-----|------|-------------|---------|-----------|
| Kiran | lioilsources/Kiran | `tyrian_mobile` | `Kirian` | `com.ol1n.kiran` |
| MirrorBooth | lioilsources/MirrorBooth | `mirrorbooth` | `MirrorBooth` | `com.ol1n.mirrorbooth` |
| PoetryStream | lioilsources/PoetryStream | `poetry_stream` | `PoetryStream` | `com.ol1n.poetrystream` |
| DuolingoCards | lioilsources/DuolingoCards | `.` | `DuolingoCards` | `com.ol1n.duolingoCards` |
| SwypeKids | lioilsources/SwypeKids | `.` | `SwypeKids` | `com.ol1n.swypeKids` |

---

## Kritické poznatky — iOS podepisování (Xcode 26 / macos-26)

### 1. PROVISIONING_PROFILE_SPECIFIER musí obsahovat UUID, ne jméno

Na runneru `macos-26` (Xcode 26) **nefunguje lookup profilu podle jména** — Xcode profil nenajde,
i když je nainstalovaný v `~/Library/MobileDevice/Provisioning Profiles/`.
**Řešení:** injektovat UUID přímo do `project.pbxproj`.

### 2. `flutter build ios --no-codesign` může odstranit uvozovky z pbxproj

Xcode 26 normalizuje pbxproj a mění `"CI_PROFILE_NAME"` (s uvozovkami) na `CI_PROFILE_NAME` (bez).
Proto musí sed injection pokrýt **obě varianty**:

```bash
sed -i '' \
  -e "s/\"CI_PROFILE_NAME\"/\"$PROFILE_UUID\"/g" \
  -e "s/CI_PROFILE_NAME/\"$PROFILE_UUID\"/g" \
  ios/Runner.xcodeproj/project.pbxproj
```

### 3. DEVELOPMENT_TEAM čerpat z profilu, ne ze secretu

Secret `IOS_TEAM_ID` může být prázdný nebo špatný. Místo toho extrahovat přímo z mobileprovision:

```bash
TEAM_ID=$(echo "$DECODED" | plutil -extract TeamIdentifier.0 raw -)
echo "PROFILE_TEAM_ID=$TEAM_ID" >> $GITHUB_ENV
```

Pak v archive kroku: `DEVELOPMENT_TEAM=$PROFILE_TEAM_ID` (env proměnná z předchozího kroku).

### 4. CODE_SIGN_IDENTITY NESMÍ být na příkazové řádce xcodebuild archive

Přidání `CODE_SIGN_IDENTITY="Apple Distribution"` jako build setting na příkazové řádce
rozbije SPM (Swift Package Manager) pluginy — ty mají Automatic signing a konflikují
s explicitní distribuční identitou.

**Správně:** `CODE_SIGN_IDENTITY = "Apple Distribution"` musí být v `project.pbxproj`
v Release konfiguraci cíle Runner — a nikde jinde se to nenastavuje.

### 5. project.pbxproj Release konfigurace — povinné hodnoty

```
CODE_SIGN_IDENTITY = "Apple Distribution";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = <TeamID>;
PROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";
```

`CI_PROFILE_NAME` je placeholder, který CI nahradí UUID profilu.
Pokud chybí `CODE_SIGN_IDENTITY`, Xcode 26 sáhne po Development certifikátu a build selže.

---

## Kritické poznatky — Android

### Race condition při souběžném iOS + Android CI

Když iOS a Android workflow běží současně pro stejný tag, oba se pokoušejí vytvořit
GitHub Release. Druhý neuspěje s chybou `already_exists` a zablokuje Firebase upload.

**Fix:** `continue-on-error: true` na kroku "Upload to GitHub Release":

```yaml
- name: Upload to GitHub Release
  if: startsWith(github.ref, 'refs/tags/')
  continue-on-error: true
  uses: softprops/action-gh-release@v2
```

---

## Kritické poznatky — Secrets

### APPSTORE_ISSUER_ID — Bitwarden položka je prázdná

Bitwarden item `CI / ASC_API_ISSUER_ID` **nemá nastavenou hodnotu** (password field je prázdný).
Skript `setup-gh-secrets.sh` proto nastaví secret na garbage hodnotu (1 znak).

**Správný Issuer ID:** `edeaacd0-9ce8-4fae-91b7-e451efabc799`

Pro každou novou appku je nutné ho nastavit ručně po spuštění skriptu:

```bash
gh secret set APPSTORE_ISSUER_ID \
  --repo lioilsources/<AppName> \
  --body "edeaacd0-9ce8-4fae-91b7-e451efabc799"
```

Nebo opravit Bitwarden item `CI / ASC_API_ISSUER_ID` → password field → UUID výše.

### Jak ověřit správnost secretu

Přidej do TestFlight kroku před `xcrun altool`:
```bash
echo "Key ID length: ${#CLEAN_KEY_ID}, Issuer ID length: ${#CLEAN_ISSUER}"
```
Issuer ID musí mít délku **36** (UUID s pomlčkami). Pokud je jiná, secret je špatný.

### Pojmenování secretů — nesoulad

`setup-gh-secrets.sh` nastavuje: `APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_PRIVATE_KEY`  
Workflow šablona používá: `APPSTORE_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_KEY_BASE64`

Pro nové appky musí být nastaveny OBOJÍ nebo workflow aktualizován.
Kiran a MirrorBooth mají navíc starší variantu `APP_STORE_CONNECT_API_ISSUER_ID` (z května 2026).

---

## Workflow šablona — kde je pravda

Šablona v `workflows/release-ios.yml` je **zdrojová šablona** pro `align-project.sh`.
Po jakékoliv opravě v produkčním workflow (Kiran/MirrorBooth/DuolingoCards) je třeba
aktualizovat i šablonu, jinak se příší appka bude nasazovat se starým, nefunkčním kódem.

---

## Časté chyby a jejich příznaky

| Příznak | Příčina | Fix |
|---------|---------|-----|
| `No profile for team matching 'XYZ' found` | Xcode 26 nenajde profil podle jména | Inject UUID místo jména |
| `project 'Runner' is damaged - parse error` | flutter build smaže uvozovky → sed vyrobil nevalidní pbxproj | Dvě sed expresky (quoted + unquoted) |
| `X has conflicting provisioning settings` | `CODE_SIGN_IDENTITY` na cmd line aplikuje na SPM targety | Odstranit z xcodebuild cmd, ponechat jen v pbxproj |
| `No signing certificate iOS Distribution found` | Špatný `DEVELOPMENT_TEAM` nebo chybí `CODE_SIGN_IDENTITY` v Release config | Čerpat TEAM_ID z profilu; přidat `CODE_SIGN_IDENTITY` do pbxproj |
| `does not match the selected team` | `IOS_TEAM_ID` secret je prázdný nebo špatný | Čerpat TEAM_ID z mobileprovision přímo |
| `Expected --api-issuer argument to have a value` | `APPSTORE_ISSUER_ID` secret je garbage (Bitwarden prázdný) | Nastavit ručně: `edeaacd0-9ce8-4fae-91b7-e451efabc799` |
| Firebase upload přeskočen (skipped) | GitHub Release krok selhal s `already_exists` | `continue-on-error: true` na Release kroku |
| `Run Release iOS has already completed` | `gh run watch` zachytil starý run | Zkontrolovat ID nového runu: `gh run list --limit 3` |
