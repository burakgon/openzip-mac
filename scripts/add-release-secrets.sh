#!/bin/bash
# Stores what the Release workflow needs as secrets of the GitHub repository. Run it once.
#
#   scripts/add-release-secrets.sh AuthKey_ABC123DEFG.p8 ISSUER-ID   everything
#   scripts/add-release-secrets.sh                                   only the update key
#
# SPARKLE_PRIVATE_KEY is the key that signs updates. It is read from the login keychain,
# where Sparkle's generate_keys put it under the account "openzip".
#
# ASC_KEY_BASE64, ASC_KEY_ID and ASC_ISSUER_ID are an App Store Connect API key. With it
# the workflow signs with the team's Developer ID certificate in the cloud, and notarizes.
# Create one at appstoreconnect.apple.com → Users and Access → Integrations → Team Keys,
# with the Admin role (cloud-managed Developer ID certificates need it). The page shows the
# issuer ID; the key ID is in the name of the file you download.
set -euo pipefail
cd "$(dirname "$0")/.."

# On a Mac that has the command line tools selected instead of Xcode, use Xcode anyway.
if ! xcodebuild -version > /dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

REPO=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
SPARKLE=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
if [[ ! -x "$SPARKLE/generate_keys" ]]; then
    echo "==> Fetching Sparkle's tools"
    xcodebuild -resolvePackageDependencies -project OpenZip.xcodeproj -derivedDataPath build/DerivedData > /dev/null
fi

umask 077
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

echo "==> Setting the secrets of $REPO"
"$SPARKLE/generate_keys" --account openzip -x "$T/sparkle.key" > /dev/null
gh secret set SPARKLE_PRIVATE_KEY -R "$REPO" < "$T/sparkle.key"

if [[ $# -ge 2 ]]; then
    KEY=$1
    ISSUER=$2
    [[ -f "$KEY" ]] || { echo "!! $KEY does not exist" >&2; exit 1; }
    KEY_ID=$(basename "$KEY" .p8)
    KEY_ID=${KEY_ID#AuthKey_}
    base64 -i "$KEY" | gh secret set ASC_KEY_BASE64 -R "$REPO"
    printf '%s' "$KEY_ID" | gh secret set ASC_KEY_ID -R "$REPO"
    printf '%s' "$ISSUER" | gh secret set ASC_ISSUER_ID -R "$REPO"
    echo "==> Test run of the Release workflow: it builds and notarizes, and publishes nothing"
    gh workflow run release.yml -R "$REPO" --ref main
    echo "    https://github.com/$REPO/actions/workflows/release.yml"
else
    echo "    The App Store Connect API key is still missing: see the top of this script."
fi
