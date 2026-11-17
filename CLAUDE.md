# Distribution

## Účel
Sdílené CI/CD pro všechny Flutter appky `lioilsources`: golden release workflowy, skripty
pro GitHub secrets a lokální (necommitované) podpisové klíče. Release workflowy odsud
přebírají všechny appky, takže změna tady se propíše všude.

## Build a test
Repo nemá build. Gate před pushem:
```
bash -n scripts/*.sh && python3 -I -m py_compile scripts/asc-check.py
```
Použití (detail v `README.md`, celý postup nové appky v `SKILL.md`):
```
export BW_SESSION=$(bw unlock --raw)
./scripts/setup-gh-secrets.sh --repo lioilsources/<AppName> --app <AppName>
./scripts/align-project.sh --target $DEV_ROOT/<AppName> --app-dir <dir> --app-name <AppName> \
  --bundle-id com.ol1n.<id> --repo lioilsources/<AppName> [--dry-run]
```

## Mapa
```
Apple/_Keys/          ← ASC API klíč AuthKey_<KeyID>.p8, záloha distribution.p12 (gitignore)
Apple/<AppName>/      ← *.mobileprovision dané appky (gitignore)
Android/<AppName>/    ← upload-keystore.jks, google-services.json (gitignore)
scripts/              ← setup-gh-secrets.sh, align-project.sh, asc-check.py, diag-ios-*.sh
workflows/            ← golden šablony ci.yml + release-{ios,android,macos,windows,linux}.yml
docs/ci-pasti.md      ← iOS signing, Android, secrets, tabulka chyb
```

### Přehled appek

| App | repo | `--app-dir` | `--app` | bundle-id |
|-----|------|-------------|---------|-----------|
| Kiran | lioilsources/Kiran | `tyrian_mobile` | `Kirian` | `com.ol1n.kiran` |
| MirrorBooth | lioilsources/MirrorBooth | `mirrorbooth` | `MirrorBooth` | `com.ol1n.mirrorbooth` |
| PoetryStream | lioilsources/PoetryStream | `poetry_stream` | `PoetryStream` | `com.ol1n.poetrystream` |
| DuolingoCards | lioilsources/DuolingoCards | `.` | `DuolingoCards` | `com.ol1n.duolingoCards` |
| SwypeKids | lioilsources/SwypeKids | `.` | `SwypeKids` | `com.ol1n.swypeKids` |
| DoodlebugsRevival | lioilsources/doodlebugs-revival | `.` | `DoodlebugsRevival` | `com.ol1n.doodlebugsRevival` |
| MangaPrompts | lioilsources/MangaPrompts | `.` | `MangaPrompts` | `com.ol1n.MangaPrompts` |
| BioDefenseRogue | lioilsources/BioDefenseRogue | `immunorun` | `BioDefenseRogue` | `com.ol1n.bioDefenseRogue` |
| AudioScanner | lioilsources/AudioScanner | `.` | `AudioScanner` | `com.ol1n.audioScanner` |
| Skatepark | lioilsources/ChrestysSkatepark | `rattleramp` | `Skatepark` | `com.ol1n.chrestysSkatepark` |
| PMTracker | lioilsources/PMTracker | `app` | `PMTracker` | `com.ol1n.pmtracker` |

## Invarianty
- **Golden = `workflows/`.** `align-project.sh` z něj instaluje `ci.yml`, `release-ios.yml`,
  `release-android.yml` vždy a `release-{macos,windows,linux}.yml` jen pro platformy, jejichž
  adresář appka má. Substituce (Python, bez regexů): `tyrian_mobile`→app-dir,
  `com.ol1n.kiran`→bundle, `Kiran`→app-name, a `tyrian_mobile.app`→`<PRODUCT_NAME>.app`
  (macOS produkt z `macos/Runner/Configs/AppInfo.xcconfig`, proto se přejmenuje dřív než working-dir).
- **Kiran je referenční appka:** opravy workflow se odladí v Kiranu a hned se vrátí do golden:
  `cp $DEV_ROOT/Kiran/.github/workflows/{ci,release-android,release-ios,release-linux,release-macos,release-windows}.yml workflows/`.
  Jinak se příští appka nasadí se starým kódem. Ověř: `align-project.sh --target $DEV_ROOT/Kiran
  --app-dir tyrian_mobile --app-name Kiran --bundle-id com.ol1n.kiran --repo lioilsources/Kiran --dry-run`
  musí hlásit „already aligned“ u všech.
- iOS p12 se bere z Bitwarden poznámky, ne z volného `distribution.p12` (bývá stale).
- Klíče, certifikáty, profily a keystory se nikdy necommitují (`.gitignore`). Keystore nikdy nemaž.
- ID (Team ID, Issuer ID, Key ID) do docs nepiš; jsou v Bitwardenu a v `.env` (vzor `.env.example`).

## Kam dál
- `docs/ci-pasti.md`: iOS podepisování na Xcode 26, Android race, secrets, tabulka chyb.
- `SKILL.md`: krok za krokem nová appka → Firebase + TestFlight, troubleshooting.
- `README.md`: struktura, sdílené secrets, příklady spuštění skriptů.
