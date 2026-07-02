#!/usr/bin/env bash
# align-project.sh
#
# Aligns a Flutter project's GitHub Actions release workflows and iOS Xcode
# signing settings with the proven Kiran CI/CD template.
#
# What it does:
#   1. release-ios.yml  — copies from source, substitutes app-specific values,
#                         fixes the sed inject pattern (CI_PROFILE_NAME bug)
#   2. release-android.yml — copies from source, adds APK build + Firebase +
#                         robustness fix (tr -d '[:space:]' for keystore b64)
#   3. ios/ExportOptions.plist — verifies bundle ID, creates if missing
#   4. ios/Runner.xcodeproj/project.pbxproj — adds CODE_SIGN_IDENTITY /
#      CODE_SIGN_STYLE / PROVISIONING_PROFILE_SPECIFIER to Debug & Profile
#      Runner configs if they are missing (Release config untouched)
#   5. ios/Runner/Info.plist — sets ITSAppUsesNonExemptEncryption=false so
#      TestFlight skips the export-compliance prompt on every build
#
# Source of truth: sibling GitHub/Kiran repo, auto-detected from script location.
#
# Usage:
#   ./align-project.sh \
#     --target /Users/ol1n/Dev/GitHub/MirrorBooth \
#     --app-dir  mirrorbooth \
#     --app-name MirrorBooth \
#     --bundle-id com.ol1n.mirrorbooth \
#     --repo lioilsources/MirrorBooth \
#     [--source /Users/ol1n/Dev/GitHub/Kiran] \
#     [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_DIR="$(cd "$SCRIPT_DIR/../../GitHub" && pwd 2>/dev/null)" || GITHUB_DIR=""

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo "❌  $*" >&2; exit 1; }
info() { echo "▶  $*"; }
ok()   { echo "✅  $*"; }
warn() { echo "⚠️   $*"; }

# ── argument parsing ──────────────────────────────────────────────────────────
TARGET_DIR=""
APP_DIR=""
APP_NAME=""
BUNDLE_ID=""
REPO=""
SOURCE_DIR=""
SOURCE_APP_DIR="tyrian_mobile"
SOURCE_APP_NAME="Kiran"
SOURCE_BUNDLE_ID="com.ol1n.kiran"
SOURCE_MACOS_PRODUCT="tyrian_mobile"   # Kiran's macOS .app product name (PRODUCT_NAME)
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)           TARGET_DIR="$2";       shift 2 ;;
    --app-dir)          APP_DIR="$2";          shift 2 ;;
    --app-name)         APP_NAME="$2";         shift 2 ;;
    --bundle-id)        BUNDLE_ID="$2";        shift 2 ;;
    --repo)             REPO="$2";             shift 2 ;;
    --source)           SOURCE_DIR="$2";       shift 2 ;;
    --source-app-dir)   SOURCE_APP_DIR="$2";   shift 2 ;;
    --source-app-name)  SOURCE_APP_NAME="$2";  shift 2 ;;
    --source-bundle-id) SOURCE_BUNDLE_ID="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true;          shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$TARGET_DIR" ]] || die "--target is required  (e.g. /Users/ol1n/Dev/GitHub/MirrorBooth)"
[[ -n "$APP_DIR"    ]] || die "--app-dir is required  (e.g. mirrorbooth)"
[[ -n "$APP_NAME"   ]] || die "--app-name is required  (e.g. MirrorBooth)"
[[ -n "$BUNDLE_ID"  ]] || die "--bundle-id is required  (e.g. com.ol1n.mirrorbooth)"
[[ -n "$REPO"       ]] || die "--repo is required  (e.g. lioilsources/MirrorBooth)"
[[ -d "$TARGET_DIR" ]] || die "Target directory not found: $TARGET_DIR"

# Source of truth: golden templates in Distribution/workflows (synced from the
# proven Kiran repo). Override with --source <repo> to pull a live .github/workflows.
GOLDEN_WF="$(cd "$SCRIPT_DIR/../workflows" 2>/dev/null && pwd)" || GOLDEN_WF=""
if [[ -n "$SOURCE_DIR" ]]; then
  [[ -d "$SOURCE_DIR/.github/workflows" ]] || die "Source workflows not found: $SOURCE_DIR/.github/workflows"
  SOURCE_WF="$SOURCE_DIR/.github/workflows"
else
  [[ -n "$GOLDEN_WF" && -d "$GOLDEN_WF" ]] || die "Golden workflows not found: $SCRIPT_DIR/../workflows"
  SOURCE_WF="$GOLDEN_WF"
fi

TARGET_WF="$TARGET_DIR/.github/workflows"
TARGET_PBXPROJ="$TARGET_DIR/$APP_DIR/ios/Runner.xcodeproj/project.pbxproj"
TARGET_EXPORT_PLIST="$TARGET_DIR/$APP_DIR/ios/ExportOptions.plist"

# macOS .app product name (used to rename the desktop release ZIP contents).
# Detected from the target's AppInfo.xcconfig; falls back to the app name.
MACOS_PRODUCT="$APP_NAME"
_APPINFO="$TARGET_DIR/$APP_DIR/macos/Runner/Configs/AppInfo.xcconfig"
if [[ -f "$_APPINFO" ]]; then
  _PN="$(grep -E '^PRODUCT_NAME' "$_APPINFO" | sed 's/.*= *//' | tr -d '[:space:]')"
  [[ -n "$_PN" ]] && MACOS_PRODUCT="$_PN"
fi

info "Source : $SOURCE_WF  (golden; $SOURCE_APP_NAME / $SOURCE_APP_DIR)"
info "Target : $TARGET_DIR  ($APP_NAME / $APP_DIR)"
info "Repo   : $REPO"
info "Bundle : $BUNDLE_ID"
info "macOS product : $MACOS_PRODUCT"
$DRY_RUN && warn "(dry run — no files will be written)"
echo ""

CHANGES=0

# ── write_or_diff ─────────────────────────────────────────────────────────────
write_or_diff() {
  local dst="$1" content="$2" label="$3"
  if [[ -f "$dst" ]]; then
    local existing; existing=$(cat "$dst")
    if [[ "$existing" == "$content" ]]; then
      echo "    ✓ $label — already aligned"
      return
    fi
    if $DRY_RUN; then
      echo "    ~ $label (diff):"
      diff --unified=2 <(echo "$existing") <(echo "$content") | head -40 || true
      echo ""
    else
      printf '%s\n' "$content" > "$dst"
      ok "$label"
      CHANGES=$((CHANGES + 1))
    fi
  else
    if $DRY_RUN; then
      echo "    + $label (would create)"
    else
      mkdir -p "$(dirname "$dst")"
      printf '%s\n' "$content" > "$dst"
      ok "$label created"
      CHANGES=$((CHANGES + 1))
    fi
  fi
}

# ── adapt_workflow ─────────────────────────────────────────────────────────────
# Applies per-project substitutions to a source workflow file using Python
# (avoids sed escaping pitfalls with ${{ }} syntax).
adapt_workflow() {
  local src="$1"
  python3 - "$src" \
      "$SOURCE_APP_DIR" "$APP_DIR" \
      "$SOURCE_APP_NAME" "$APP_NAME" \
      "$SOURCE_BUNDLE_ID" "$BUNDLE_ID" \
      "$SOURCE_MACOS_PRODUCT" "$MACOS_PRODUCT" << 'PYEOF'
import sys
src_path, src_dir, app_dir, src_name, app_name, src_bundle, app_bundle, src_prod, app_prod = sys.argv[1:]

with open(src_path) as f:
    content = f.read()

# Literal substitutions — no regex, no escaping surprises.
# Order matters: the macOS .app product name embeds src_dir (e.g. "tyrian_mobile.app"),
# so rename the product bundle BEFORE collapsing the working-directory token.
content = content.replace(src_prod + '.app', app_prod + '.app')  # macOS product bundle
content = content.replace(src_dir, app_dir)                       # working-directory / build paths
content = content.replace(src_bundle, app_bundle)                 # bundle id (lowercase)
content = content.replace(src_name, app_name)                     # app display name (release names, asset files, Firebase notes)

sys.stdout.write(content)
PYEOF
}

# ── 1. release-ios.yml ────────────────────────────────────────────────────────
info "release-ios.yml"
IOS_SRC="$SOURCE_WF/release-ios.yml"
[[ -f "$IOS_SRC" ]] || die "Source not found: $IOS_SRC"
write_or_diff "$TARGET_WF/release-ios.yml" "$(adapt_workflow "$IOS_SRC")" "release-ios.yml"

# ── 2. release-android.yml ───────────────────────────────────────────────────
info "release-android.yml"
ANDROID_SRC="$SOURCE_WF/release-android.yml"
[[ -f "$ANDROID_SRC" ]] || die "Source not found: $ANDROID_SRC"
write_or_diff "$TARGET_WF/release-android.yml" "$(adapt_workflow "$ANDROID_SRC")" "release-android.yml"

# ── 2b. ci.yml ───────────────────────────────────────────────────────────────
info "ci.yml"
CI_SRC="$SOURCE_WF/ci.yml"
if [[ -f "$CI_SRC" ]]; then
  write_or_diff "$TARGET_WF/ci.yml" "$(adapt_workflow "$CI_SRC")" "ci.yml"
else
  warn "ci.yml not in source — skipped"
fi

# ── 2c. desktop release workflows (only for platforms present in the target) ──
for _plat in macos windows linux; do
  info "release-$_plat.yml"
  if [[ -d "$TARGET_DIR/$APP_DIR/$_plat" ]]; then
    _SRC="$SOURCE_WF/release-$_plat.yml"
    if [[ -f "$_SRC" ]]; then
      write_or_diff "$TARGET_WF/release-$_plat.yml" "$(adapt_workflow "$_SRC")" "release-$_plat.yml"
    else
      warn "release-$_plat.yml not in source — skipped"
    fi
  else
    echo "    – release-$_plat.yml skipped (no $_plat/ in target)"
  fi
done

# ── 3. ExportOptions.plist ───────────────────────────────────────────────────
info "ExportOptions.plist"

EXPECTED_PLIST="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>REPLACE_WITH_YOUR_TEAM_ID</string>
    <key>compileBitcode</key>
    <false/>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>REPLACE_WITH_YOUR_ADHOC_PROFILE_NAME</string>
    </dict>
</dict>
</plist>"

if [[ -f "$TARGET_EXPORT_PLIST" ]]; then
  if grep -q "$BUNDLE_ID" "$TARGET_EXPORT_PLIST"; then
    echo "    ✓ ExportOptions.plist — bundle ID correct"
  else
    warn "ExportOptions.plist has wrong bundle ID"
    write_or_diff "$TARGET_EXPORT_PLIST" "$EXPECTED_PLIST" "ExportOptions.plist"
  fi
else
  write_or_diff "$TARGET_EXPORT_PLIST" "$EXPECTED_PLIST" "ExportOptions.plist (created)"
fi

# ── 4. Xcode project signing (Debug / Profile configs) ───────────────────────
info "Xcode project signing"

if [[ ! -f "$TARGET_PBXPROJ" ]]; then
  warn "project.pbxproj not found — skipping: $TARGET_PBXPROJ"
else
  # Verify (and auto-fix) the Runner Release config: Manual signing + CI_PROFILE_NAME
  # placeholder (CI injects the real UUID). handle quoted/unquoted (flutter build can strip quotes).
  _RELEASE_OK=true
  grep -q 'CODE_SIGN_STYLE = Manual' "$TARGET_PBXPROJ"                                 || _RELEASE_OK=false
  grep -qE 'PROVISIONING_PROFILE_SPECIFIER = "?CI_PROFILE_NAME"?;' "$TARGET_PBXPROJ"  || _RELEASE_OK=false
  if $_RELEASE_OK; then
    echo "    ✓ Release config — Manual + CI_PROFILE_NAME placeholder"
  elif $DRY_RUN; then
    warn "Release config not Manual+CI_PROFILE_NAME (dry run — would auto-fix)"
  else
    warn "Release config not Manual+CI_PROFILE_NAME — auto-fixing..."
    # Extract the team already used elsewhere in the project (shared dev account).
    DEV_TEAM="$(grep -m1 -E 'DEVELOPMENT_TEAM = ' "$TARGET_PBXPROJ" | sed -E 's/.*= *//; s/;.*//' | tr -d '[:space:]')"
    python3 - "$TARGET_PBXPROJ" "$BUNDLE_ID" "$DEV_TEAM" << 'PYEOF'
import re, sys
pbxproj_path, bundle_id, dev_team = sys.argv[1:]
with open(pbxproj_path) as f:
    content = f.read()

WANT = ['CODE_SIGN_IDENTITY = "Apple Distribution";',
        'CODE_SIGN_STYLE = Manual;',
        'PROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";']
if dev_team:
    WANT.insert(2, f'DEVELOPMENT_TEAM = {dev_team};')

def fix_release(b):
    if f'PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};' not in b:
        return b  # only the Runner target (skip RunnerTests / project-level)
    # Drop the SDK-qualified Development identity the Flutter template ships with.
    b = re.sub(r'\n[ \t]*"CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]" = [^;]*;', '', b)
    has_style = 'CODE_SIGN_STYLE' in b
    if has_style:
        # Block already carries signing keys — rewrite the values in place.
        b = re.sub(r'(\n[ \t]*)CODE_SIGN_IDENTITY = [^;]*;', r'\1CODE_SIGN_IDENTITY = "Apple Distribution";', b, count=1)
        b = re.sub(r'CODE_SIGN_STYLE = \w+;', 'CODE_SIGN_STYLE = Manual;', b, count=1)
        if re.search(r'PROVISIONING_PROFILE_SPECIFIER = [^;]*;', b):
            b = re.sub(r'PROVISIONING_PROFILE_SPECIFIER = [^;]*;', 'PROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";', b, count=1)
        else:
            b = b.replace('\t\t\t\tCODE_SIGN_STYLE = Manual;',
                          '\t\t\t\tCODE_SIGN_STYLE = Manual;\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "CI_PROFILE_NAME";', 1)
        if 'CODE_SIGN_IDENTITY = "Apple Distribution";' not in b:
            b = b.replace('\t\t\t\tCODE_SIGN_STYLE = Manual;',
                          '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";\n\t\t\t\tCODE_SIGN_STYLE = Manual;', 1)
    else:
        # No signing keys at all — inject the missing ones after PRODUCT_BUNDLE_IDENTIFIER.
        # Skip any key already present in the block (e.g. DEVELOPMENT_TEAM) to avoid dupes.
        missing = [k for k in WANT if k.split(' = ', 1)[0] not in b]
        inject = ''.join('\t\t\t\t' + k + '\n' for k in missing)
        b = b.replace(f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle_id};\n',
                      f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle_id};\n' + inject, 1)
    return b

pattern = re.compile(r'(\t\t[A-Fa-f0-9]{24} /\* Release \*/ = \{.*?\t\t\tname = Release;\n\t\t\};)', re.DOTALL)
new_content = pattern.sub(lambda m: fix_release(m.group(0)), content)
if new_content != content:
    with open(pbxproj_path, 'w') as f:
        f.write(new_content)
    print('    ✅ Release config → Apple Distribution + Manual + CI_PROFILE_NAME')
else:
    print('    ⚠️  Could not auto-fix Release config — edit Runner Release manually')
PYEOF
  fi

  # Verify (and auto-fix) CODE_SIGN_IDENTITY = "Apple Distribution" in Release config.
  # Without this, Xcode 26 picks the Development cert and archive fails.
  if grep -q 'CODE_SIGN_IDENTITY = "Apple Distribution"' "$TARGET_PBXPROJ"; then
    echo "    ✓ Release config — CODE_SIGN_IDENTITY = Apple Distribution"
  else
    warn "Release config missing CODE_SIGN_IDENTITY = \"Apple Distribution\" — auto-fixing..."
    if ! $DRY_RUN; then
      python3 - "$TARGET_PBXPROJ" "$BUNDLE_ID" << 'PYEOF'
import re, sys

pbxproj_path, bundle_id = sys.argv[1:]

with open(pbxproj_path) as f:
    content = f.read()

def patch_release_block(match):
    block = match.group(0)
    if 'CODE_SIGN_IDENTITY = "Apple Distribution"' in block:
        return block  # Already present
    if f'PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};' not in block:
        return block  # Not Runner target (e.g. RunnerTests)
    # Insert CODE_SIGN_IDENTITY immediately before CODE_SIGN_STYLE = Manual
    if 'CODE_SIGN_STYLE = Manual;' in block:
        block = block.replace(
            '\t\t\t\tCODE_SIGN_STYLE = Manual;\n',
            '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";\n'
            '\t\t\t\tCODE_SIGN_STYLE = Manual;\n',
        )
    return block

pattern = re.compile(
    r'(\t\t[A-Fa-f0-9]{24} /\* Release \*/ = \{.*?\t\t\tname = Release;\n\t\t\};)',
    re.DOTALL,
)

new_content = pattern.sub(patch_release_block, content)

if new_content != content:
    with open(pbxproj_path, 'w') as f:
        f.write(new_content)
    print('    ✅ Added CODE_SIGN_IDENTITY = "Apple Distribution" to Release config')
else:
    print('    ⚠️  Could not auto-fix — add manually to Release config of Runner target:')
    print('       CODE_SIGN_IDENTITY = "Apple Distribution";')
PYEOF
    fi
  fi

  # Verify + optionally fix Debug/Profile configs
  if grep -q 'CODE_SIGN_STYLE = Automatic' "$TARGET_PBXPROJ" && \
     grep -q 'CODE_SIGN_IDENTITY = "Apple Development"' "$TARGET_PBXPROJ"; then
    echo "    ✓ Debug/Profile configs — Automatic + Apple Development"
  else
    warn "Debug/Profile configs missing explicit signing settings"
    if $DRY_RUN; then
      echo "    (dry run — would add CODE_SIGN_IDENTITY / CODE_SIGN_STYLE / PROVISIONING_PROFILE_SPECIFIER)"
    else
      python3 - "$TARGET_PBXPROJ" "$BUNDLE_ID" << 'PYEOF'
import re, sys

pbxproj_path, bundle_id = sys.argv[1:]

with open(pbxproj_path) as f:
    content = f.read()

changes = 0

def patch_block(match):
    global changes
    block = match.group(0)
    if 'CODE_SIGN_STYLE' in block:
        return block  # Already set, leave untouched
    if f'PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};' not in block:
        return block  # Not the Runner target (e.g. RunnerTests)
    original = block

    # Add CODE_SIGN_IDENTITY + CODE_SIGN_STYLE after CLANG_ENABLE_MODULES
    if 'CODE_SIGN_IDENTITY' not in block and 'CLANG_ENABLE_MODULES = YES;' in block:
        block = block.replace(
            '\t\t\t\tCLANG_ENABLE_MODULES = YES;\n',
            '\t\t\t\tCLANG_ENABLE_MODULES = YES;\n'
            '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";\n'
            '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n',
        )

    # Add PROVISIONING_PROFILE_SPECIFIER = ""; after PRODUCT_NAME
    if 'PROVISIONING_PROFILE_SPECIFIER' not in block and \
       'PRODUCT_NAME = "$(TARGET_NAME)";' in block:
        block = block.replace(
            '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n',
            '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
            '\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "";\n',
        )

    if block != original:
        changes += 1
    return block

# Match Debug/Profile XCBuildConfiguration blocks for the Runner target.
# Pattern anchored on tab-indented UUID lines and closed by `name = X;\n\t\t};`
pattern = re.compile(
    r'(\t\t[A-Fa-f0-9]{24} /\* (?:Debug|Profile) \*/ = \{.*?\t\t\tname = (?:Debug|Profile);\n\t\t\};)',
    re.DOTALL,
)

new_content = pattern.sub(patch_block, content)

if new_content != content:
    with open(pbxproj_path, 'w') as f:
        f.write(new_content)
    print(f'    ✅ Fixed {changes} Debug/Profile config(s) in project.pbxproj')
else:
    print('    ✓ project.pbxproj — no changes needed after inspection')
PYEOF
    fi
  fi
fi

# ── 5. Info.plist — export compliance ────────────────────────────────────────
info "Info.plist (export compliance)"
TARGET_INFO_PLIST="$TARGET_DIR/$APP_DIR/ios/Runner/Info.plist"
if [[ ! -f "$TARGET_INFO_PLIST" ]]; then
  warn "Info.plist not found — skipping: $TARGET_INFO_PLIST"
else
  _CUR=$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$TARGET_INFO_PLIST" 2>/dev/null || echo "")
  if [[ "$_CUR" == "false" ]]; then
    echo "    ✓ ITSAppUsesNonExemptEncryption — already false"
  elif $DRY_RUN; then
    echo "    ~ would set ITSAppUsesNonExemptEncryption = false (current: ${_CUR:-<missing>})"
  else
    # false = app uses no non-exempt encryption → skips the TestFlight export
    # compliance prompt on every build. Flip to true only if you add real crypto.
    /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$TARGET_INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :ITSAppUsesNonExemptEncryption false" "$TARGET_INFO_PLIST"
    ok "ITSAppUsesNonExemptEncryption = false"
    CHANGES=$((CHANGES + 1))
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $DRY_RUN; then
  info "Dry run complete. Re-run without --dry-run to apply changes."
elif [[ $CHANGES -eq 0 ]]; then
  ok "$APP_NAME is already fully aligned with the Kiran CI/CD flow."
else
  ok "$APP_NAME aligned ($CHANGES file(s) updated)."
  echo ""
  echo "  Next steps:"
  echo "    1. Review changes:  git -C '$TARGET_DIR' diff"
  echo "    2. Set GH secrets:  $SCRIPT_DIR/setup-gh-secrets.sh --repo $REPO --app $APP_NAME"
  echo "    3. Verify actions:  https://github.com/${REPO}/actions"
fi
