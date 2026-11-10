#!/bin/bash
# Builds a release of OpenZip: a universal app, signed with Developer ID, notarized
# and stapled, packaged as a disk image for people and a zip for the updater, together
# with the appcast that announces it to the copies already installed.
#
# The app carries two more pieces of code, the 7-Zip helper and the Finder extension.
# Both are built for both architectures and signed like the app, and both are checked here.
#
#   scripts/release.sh             build, sign, notarize and package into build/release
#   scripts/release.sh --publish   ...and create the GitHub release vVERSION from it
#
# The version comes from Config/Version.xcconfig and the release notes from the section
# of CHANGELOG.md for that version. To release:
#
#   edit Config/Version.xcconfig and add a "## 1.1.0" section to CHANGELOG.md
#   git commit -am "OpenZip 1.1.0" && git push
#   scripts/release.sh --publish
#
# Signing, the first that applies:
#   CODESIGN_IDENTITY                           a Developer ID Application certificate in the
#                                               keychain, by name or SHA-1
#   a Developer ID Application certificate that is found in the keychain
#   ASC_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID   an App Store Connect API key: Xcode signs
#                                               with the team's certificate in the cloud (CI)
#   the account signed in to Xcode              likewise, on a developer's Mac
#
# Notarization, the first that is set:
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   an App Store Connect API key (CI)
#   NOTARY_APPLE_ID + NOTARY_PASSWORD                    an Apple ID, app-specific password
#   NOTARY_PROFILE (default macos-notary)                a notarytool keychain profile
#
# Update signing: SPARKLE_PRIVATE_KEY holds the private EdDSA key (CI). Without it the key
# is read from the login keychain, where `generate_keys --account openzip` keeps it.
#
# SKIP_NOTARIZATION=1 skips notarization, to try the build only. Such a build is never published.
set -euo pipefail
cd "$(dirname "$0")/.."

# On a Mac that has the command line tools selected instead of Xcode, use Xcode anyway.
if ! xcodebuild -version > /dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

TEAM_ID=${TEAM_ID:-QCB78CL77T}
REPO=${REPO:-burakgon/openzip-mac}
VERSION=$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)
TAG="v$VERSION"
OUT=build/release
DERIVED=build/DerivedData
ARCHIVE="$OUT/OpenZip.xcarchive"
APP="$OUT/export/OpenZip.app"
# Fixed names, so .../releases/latest/download/OpenZip.dmg always works.
DMG="$OUT/OpenZip.dmg"
ZIP="$OUT/OpenZip.zip"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

fail() { echo "!! $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ -n "$VERSION" ]] || fail "Config/Version.xcconfig has no MARKETING_VERSION"

# The release notes: this version's section of the changelog.
NOTES=$(awk -v v="$VERSION" '
    index($0, "## " v) == 1 || index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## / { exit }
    on { print }' CHANGELOG.md | sed -e '/./,$!d')
[[ -n "$NOTES" ]] || fail "CHANGELOG.md has no \"## $VERSION\" section"

if [[ $PUBLISH == 1 ]]; then
    command -v gh >/dev/null || fail "publishing needs the GitHub CLI (gh)"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then fail "$TAG is already published"; fi
    [[ -z "$(git status --porcelain)" ]] || fail "commit your changes first"
    [[ "${SKIP_NOTARIZATION:-}" != 1 ]] || fail "a build that is not notarized is never published"
fi

# --- Signing -----------------------------------------------------------------------

# The Developer ID Application identity in the keychain that expires last, or nothing.
# A team can have several of these certificates under one name, and codesign refuses a
# name that matches two, so the identity is passed on as a SHA-1.
developer_id() {
    local certs best="" best_end=-1 hash end
    certs=$(security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null) || return 0
    for hash in $(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: .*/\1/p'); do
        end=$(awk -v h="$hash" '$0 == "SHA-1 hash: " h { on = 1; next } on { print } on && /END CERTIFICATE/ { exit }' <<< "$certs" \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        end=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)
        if (( end > best_end )); then best=$hash; best_end=$end; fi
    done
    echo "$best"
}

IDENTITY=${CODESIGN_IDENTITY:-$(developer_id)}
XCODE_AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    XCODE_AUTH=(-authenticationKeyPath "$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
                -authenticationKeyID "${ASC_KEY_ID:?}" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi

rm -rf "$OUT"
mkdir -p "$OUT"

if [[ -n "$IDENTITY" ]]; then
    step "Signing with the Developer ID certificate $IDENTITY"
    ARCHIVE_SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID")
    EXPORT_SIGNING=()
    EXPORT_STYLE="<key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$IDENTITY</string>"
else
    step "No Developer ID certificate in the keychain: Xcode signs with the team's certificate in the cloud"
    ARCHIVE_SIGNING=(CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development" "DEVELOPMENT_TEAM=$TEAM_ID"
                     -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"})
    EXPORT_SIGNING=(-allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"})
    EXPORT_STYLE="<key>signingStyle</key><string>automatic</string>"
fi

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    $EXPORT_STYLE
</dict>
</plist>
EOF

# --- Build -------------------------------------------------------------------------

step "Building OpenZip $VERSION"
xcodebuild archive -project OpenZip.xcodeproj -scheme OpenZip -configuration Release \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
    "${ARCHIVE_SIGNING[@]}" > "$OUT/archive.log" 2>&1 \
    || { tail -40 "$OUT/archive.log" >&2; fail "the build failed: see $OUT/archive.log"; }

step "Exporting with Developer ID"
# The export signs every piece of code in the bundle again, including the helpers inside
# Sparkle, which is what notarization requires.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" ${EXPORT_SIGNING[@]+"${EXPORT_SIGNING[@]}"} > "$OUT/export.log" 2>&1 \
    || { tail -40 "$OUT/export.log" >&2; fail "the export failed: see $OUT/export.log"; }

codesign --verify --deep --strict "$APP" || fail "the signature does not verify"
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
SIGNED_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ "$AUTHORITY" == "Developer ID Application:"* && "$SIGNED_TEAM" == "$TEAM_ID" ]] \
    || fail "signed by '$AUTHORITY' (team '$SIGNED_TEAM'), not by the Developer ID of $TEAM_ID"
ARCHS=$(lipo -archs "$APP/Contents/MacOS/OpenZip")
# Everything that runs has to be universal, hardened and signed by the same team:
# notarization refuses the app otherwise, and an Intel Mac would refuse to start a helper
# that was only built for Apple silicon.
for code in "$APP/Contents/MacOS/OpenZip" "$APP/Contents/Helpers/7zz" \
            "$APP/Contents/PlugIns/OpenZipFinder.appex/Contents/MacOS/OpenZipFinder"; do
    [[ -f "$code" ]] || fail "$code is missing from the app"
    archs=$(lipo -archs "$code")
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "not a universal build: $code ($archs)"
    info=$(codesign -dvv "$code" 2>&1)
    grep -q "^Authority=Developer ID Application:" <<< "$info" || fail "$code is not signed with Developer ID"
    grep -q "^TeamIdentifier=$TEAM_ID\$" <<< "$info" || fail "$code is signed by another team"
    grep -q "flags=.*runtime" <<< "$info" || fail "$code does not have the hardened runtime"
done
codesign -d --entitlements - "$APP/Contents/PlugIns/OpenZipFinder.appex" 2> /dev/null | grep -q "com.apple.security.app-sandbox" \
    || fail "the Finder extension lost its sandbox entitlement: macOS would not load it"
echo "    $AUTHORITY, $ARCHS"

# --- Notarization ------------------------------------------------------------------

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "${NOTARY_PASSWORD:?}" --team-id "$TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:-macos-notary}")
fi

# Sends a file to Apple's notary service and waits for the verdict.
notarize() {
    local file=$1 report="$OUT/notary.json" status id
    xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --timeout 45m --output-format json > "$report" || true
    status=$(/usr/bin/plutil -extract status raw -o - "$report" 2>/dev/null || true)
    id=$(/usr/bin/plutil -extract id raw -o - "$report" 2>/dev/null || true)
    if [[ "$status" != Accepted ]]; then
        cat "$report" >&2 || true
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
        fail "notarization of $(basename "$file") failed"
    fi
    rm -f "$report"
}

if [[ "${SKIP_NOTARIZATION:-}" == 1 ]]; then
    step "Not notarizing (SKIP_NOTARIZATION=1)"
else
    step "Notarizing the app (a few minutes)"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    notarize "$OUT/notarize.zip"
    rm "$OUT/notarize.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

# --- Packaging ---------------------------------------------------------------------

step "Packaging"
# The zip is what the updater downloads. It is made after stapling, so that the ticket
# travels with the app and an update installs without asking Apple again.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# diskutil makes disk images on current systems; hdiutil is what older ones have.
diskutil image create from --format ULFO --volumeName "OpenZip" "$STAGE" "$DMG" > /dev/null 2>&1 \
    || hdiutil create -volname "OpenZip" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" > /dev/null
rm -rf "$STAGE"
if [[ -n "$IDENTITY" ]]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    if [[ "${SKIP_NOTARIZATION:-}" != 1 ]]; then
        step "Notarizing the disk image"
        notarize "$DMG"
        xcrun stapler staple "$DMG"
    fi
fi

# --- Appcast -----------------------------------------------------------------------

step "Signing the update"
SPARKLE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE/generate_appcast" ]] || fail "Sparkle's tools are missing from $SPARKLE"
FEED="$OUT/feed"
mkdir -p "$FEED"
cp "$ZIP" "$FEED/OpenZip.zip"
# Notes with the same name as the archive become the release notes shown before updating.
printf '%s\n' "$NOTES" > "$FEED/OpenZip.md"
APPCAST_OPTIONS=(--download-url-prefix "https://github.com/$REPO/releases/download/$TAG/"
                 --link "https://github.com/$REPO" --embed-release-notes -o "$OUT/appcast.xml")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE/generate_appcast" --ed-key-file - "${APPCAST_OPTIONS[@]}" "$FEED"
else
    "$SPARKLE/generate_appcast" --account openzip "${APPCAST_OPTIONS[@]}" "$FEED"
fi
rm -rf "$FEED"
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || fail "the appcast has no signature: is the update key available?"

printf '%s\n' "$NOTES" > "$OUT/notes.md"
(cd "$OUT" && shasum -a 256 OpenZip.dmg OpenZip.zip > checksums.txt)
rm -rf "$ARCHIVE" "$OUT/export.log" "$OUT/archive.log" "$OUT/ExportOptions.plist"
step "$DMG ($(du -h "$DMG" | cut -f1)), $ZIP ($(du -h "$ZIP" | cut -f1)), $OUT/appcast.xml"

# --- Publishing --------------------------------------------------------------------

if [[ $PUBLISH == 1 ]]; then
    step "Publishing $TAG"
    gh release create "$TAG" "$DMG" "$ZIP" "$OUT/appcast.xml" "$OUT/checksums.txt" -R "$REPO" \
        --title "OpenZip $VERSION" --notes-file "$OUT/notes.md" --target "$(git rev-parse HEAD)"
fi
