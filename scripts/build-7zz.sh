#!/bin/bash
# Builds 7zz, the 7-Zip console program that does OpenZip's reading and writing, from the
# source that 7-Zip publishes, as a universal binary in Vendor/7zz.
#
#   scripts/build-7zz.sh           build it unless Vendor/7zz is already this version
#   scripts/build-7zz.sh --force   build it again
#
# The Xcode project runs this before the first build, so there is normally no reason to run
# it by hand. The source archive is pinned by its SHA-256: to move to a new 7-Zip, change
# VERSION and SHA256 below.
#
# Nothing of 7-Zip is kept in this repository. The archive comes from the releases of
# https://github.com/ip7z/7zip, 7-Zip's own repository.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=26.06
SHA256=a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4
# The oldest macOS the helper runs on: the same as the app's (Config/Base.xcconfig).
DEPLOYMENT_TARGET=26.0

NAME="7z${VERSION//./}-src"
URL="https://github.com/ip7z/7zip/releases/download/$VERSION/$NAME.tar.xz"
OUT=Vendor/7zz
WORK=build/7zz

fail() { echo "error: $*" >&2; exit 1; }

if [[ "${1:-}" != "--force" && -x "$OUT/7zz" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    exit 0
fi

echo "==> Building 7-Zip $VERSION (once; it takes about half a minute)"
mkdir -p "$WORK" "$OUT"
ARCHIVE="$WORK/$NAME.tar.xz"
if [[ ! -f "$ARCHIVE" ]] || ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - > /dev/null 2>&1; then
    curl --fail --location --silent --show-error --retry 3 -o "$ARCHIVE" "$URL" \
        || fail "could not download $URL"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - > /dev/null \
    || fail "$ARCHIVE does not have the expected SHA-256: it is not the source this script was written for"

rm -rf "$WORK/src" "$WORK/out"
mkdir -p "$WORK/src" "$WORK/out"
tar -xf "$ARCHIVE" -C "$WORK/src"

# The makefiles of 7-Zip read their settings from make variables, and make takes every
# environment variable for one. Inside an Xcode build the environment is full of build
# settings, so make gets a clean one.
CLEAN_ENV=(env -i "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$HOME")
[[ -n "${DEVELOPER_DIR:-}" ]] && CLEAN_ENV+=("DEVELOPER_DIR=$DEVELOPER_DIR")
JOBS=$(sysctl -n hw.ncpu)
ROOT=$PWD

build() {  # build MAKEFILE-NAME CLANG-ARCH
    local makefile=$1 arch=$2
    # 7-Zip's own makefiles build with -Werror and name an older macOS than the current
    # SDK supports. Both are set here instead, so that a new compiler does not break the build.
    (cd "$WORK/src/CPP/7zip/Bundles/Alone2" && "${CLEAN_ENV[@]}" make -j"$JOBS" -f "../../cmpl_mac_$makefile.mak" \
        MY_ARCH="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
        CFLAGS_WARN_WALL="-Wall" CFLAGS_WARN="" \
        O="$ROOT/$WORK/out/$arch" > "$ROOT/$WORK/build-$arch.log" 2>&1) \
        || { tail -30 "$WORK/build-$arch.log" >&2; fail "7-Zip did not build for $arch: see $WORK/build-$arch.log"; }
}
build arm64 arm64
build x64 x86_64

lipo -create "$WORK/out/arm64/7zz" "$WORK/out/x86_64/7zz" -output "$OUT/7zz.new"
chmod 755 "$OUT/7zz.new"
"$OUT/7zz.new" i > /dev/null || fail "the 7zz that was built does not run"
# Signed ad hoc with the hardened runtime. Xcode signs it again with the app's identity
# when it copies it into the bundle, and keeps this flag, which notarization asks for.
codesign --force --sign - --options runtime --identifier org.7-zip.7zz "$OUT/7zz.new"
mv -f "$OUT/7zz.new" "$OUT/7zz"

# The licenses travel with the binary and are shown in the app.
# Under names that say whose they are: they end up among the app's resources.
install -m 644 "$WORK/src/DOC/License.txt" "$OUT/7-Zip License.txt"
install -m 644 "$WORK/src/DOC/unRarLicense.txt" "$OUT/7-Zip unRAR License.txt"
install -m 644 "$WORK/src/DOC/copying.txt" "$OUT/7-Zip LGPL.txt"
printf '%s\n' "$VERSION" > "$OUT/VERSION"
rm -rf "$WORK/src" "$WORK/out"
echo "==> $OUT/7zz ($(lipo -archs "$OUT/7zz"))"
