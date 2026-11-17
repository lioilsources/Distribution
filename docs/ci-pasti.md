# CI/CD pasti: podepisování, Android, secrets

Přesunuto z `CLAUDE.md`. Platí pro golden šablony ve `workflows/` a skripty ve `scripts/`.
Hodnoty ID (Team ID, Issuer ID, Key ID) sem nepatří; jsou v Bitwardenu a v `.env`
(vzor `.env.example`).

## iOS podepisování (Xcode 26 / macos-26)

### 1. PROVISIONING_PROFILE_SPECIFIER musí obsahovat UUID, ne jméno

Na runneru `macos-26` (Xcode 26) **nefunguje lookup profilu podle jména**: Xcode profil nenajde,
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
rozbije SPM (Swift Package Manager) pluginy: ty mají Automatic signing a konflikují
s explicitní distribuční identitou.

**Správně:** `CODE_SIGN_IDENTITY = "Apple Distribution"` musí být v `project.pbxproj`
v Release konfiguraci cíle Runner, a nikde jinde se to nenastavuje.

### 5. project.pbxproj Release konfigurace: povinné hodnoty

```
CODE_SIGN_IDENTITY = "Apple Distribution";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = <TeamID>;
PROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";
```

`CI_PROFILE_NAME` je placeholder, který CI nahradí UUID profilu.
Pokud chybí `CODE_SIGN_IDENTITY`, Xcode 26 sáhne po Development certifikátu a build selže.

> Pozn.: `SKILL.md` (Krok 4) popisuje jiný přístup (automatic signing v projektu, archive
> s `CODE_SIGNING_ALLOWED=NO`, podpis až při exportu) a ten starý označuje za opuštěný.
> Golden `workflows/release-ios.yml` a `scripts/align-project.sh` ale dnes používají
> přístup popsaný výše (placeholder + sed na UUID).

## Android

### Race condition při souběžném iOS + Android CI

Když iOS a Android workflow běží současně pro stejný tag, oba se pokoušejí vytvořit
GitHub Release. Druhý neuspěje s chybou `already_exists` a zablokuje Firebase upload.

**Fix:** `continue-on-error: true` na kroku "Upload to GitHub Release" (v golden
`workflows/release-android.yml` už je):

```yaml
- name: Upload to GitHub Release
  if: startsWith(github.ref, 'refs/tags/')
  continue-on-error: true
  uses: softprops/action-gh-release@v2
```

## Secrets

### Issuer ID

Bitwarden položka s ASC Issuer ID bývala prázdná. `setup-gh-secrets.sh` proto hodnotu
validuje jako UUID a při neplatné použije zabudovaný fallback (a vypíše varování, ať se
položka v Bitwardenu opraví). Ruční `gh secret set` už pro novou appku netřeba.

Když je přesto potřeba nastavit ručně (hodnota je v `.env` jako `ASC_ISSUER_ID`):

```bash
gh secret set APP_STORE_CONNECT_API_ISSUER_ID \
  --repo lioilsources/<AppName> \
  --body "$ASC_ISSUER_ID"
```

### Jak ověřit správnost secretu

Přidej do TestFlight kroku před `xcrun altool`:
```bash
echo "Key ID length: ${#CLEAN_KEY_ID}, Issuer ID length: ${#CLEAN_ISSUER}"
```
Issuer ID musí mít délku **36** (UUID s pomlčkami). Pokud je jiná, secret je špatný.

### Pojmenování secretů

Golden `release-ios.yml` čte `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_ID`
a `APP_STORE_CONNECT_API_KEY_BASE64`. `setup-gh-secrets.sh` nastavuje tyto i starší názvy
(`APPSTORE_ISSUER_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_PRIVATE_KEY`) kvůli zpětné kompatibilitě.

## Časté chyby a jejich příznaky

| Příznak | Příčina | Fix |
|---------|---------|-----|
| `No profile for team matching 'XYZ' found` | Xcode 26 nenajde profil podle jména | Inject UUID místo jména |
| `project 'Runner' is damaged - parse error` | flutter build smaže uvozovky → sed vyrobil nevalidní pbxproj | Dvě sed expresky (quoted + unquoted) |
| `X has conflicting provisioning settings` | `CODE_SIGN_IDENTITY` na cmd line aplikuje na SPM targety | Odstranit z xcodebuild cmd, ponechat jen v pbxproj |
| `No signing certificate iOS Distribution found` | Špatný `DEVELOPMENT_TEAM` nebo chybí `CODE_SIGN_IDENTITY` v Release config | Čerpat TEAM_ID z profilu; přidat `CODE_SIGN_IDENTITY` do pbxproj |
| `does not match the selected team` | `IOS_TEAM_ID` secret je prázdný nebo špatný | Čerpat TEAM_ID z mobileprovision přímo |
| `Expected --api-issuer argument to have a value` | Issuer secret chybí nebo je garbage | Pustit znovu `setup-gh-secrets.sh`, případně ručně (viz Secrets) |
| `Cannot determine the Apple ID from Bundle ID 'X'` | Appka s bundle ID X v ASC není (jiný tým, velikost písmen), **je založená jen pro jinou platformu** (Papanek: jen macOS), nebo `APP_STORE_CONNECT_API_*` secrets k sobě nepatří | `scripts/asc-check.py` (spouští ho i `setup-gh-secrets.sh`): exit 3 = založit appku, exit 4 = Add Platform → iOS, exit 2 = opravit secrets |
| Firebase upload přeskočen (skipped) | GitHub Release krok selhal s `already_exists` | `continue-on-error: true` na Release kroku |
| `Run Release iOS has already completed` | `gh run watch` zachytil starý run | Zkontrolovat ID nového runu: `gh run list --limit 3` |
