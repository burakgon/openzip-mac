#!/bin/bash
# Takes the screenshots of the README and the website, into docs/images.
#
#   scripts/screenshots.sh
#
# The pictures are staged with the app's demo mode (see OpenZip/Support/Demo.swift) and
# an archive that is made up here, on the spot. Each window is photographed by itself:
# nothing else that is on the screen of the Mac that takes them can get in.
#
# Needs a built app (APP, by default the Release build in build/DerivedData) and the
# Screen Recording permission for the terminal it is run from.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version > /dev/null 2>&1 && [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP=${APP:-build/DerivedData/Build/Products/Release/OpenZip.app}
OUT=docs/images
[[ -x "$APP/Contents/MacOS/OpenZip" ]] || { echo "!! build the app first: $APP is missing" >&2; exit 1; }
# As a full path: the app is started and its helper used from other folders.
APP=$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")
BINARY="$APP/Contents/MacOS/OpenZip"
mkdir -p "$OUT"

# The copies of the app that were started from here, and no others: the OpenZip of
# whoever takes the pictures may well be open, with work in it, and is left alone.
ours() {
    local pid
    for pid in $(pgrep -x OpenZip); do
        [[ "$(ps -o comm= -p "$pid" 2> /dev/null)" == "$BINARY" ]] && echo "$pid"
    done
    return 0
}
stop() {
    local pids
    pids=$(ours)
    [[ -z "$pids" ]] || kill $pids 2> /dev/null || true
}

STAGE=$(mktemp -d)
trap 'stop; rm -rf "$STAGE"' EXIT

# --- The archive in the pictures ---------------------------------------------------

/usr/bin/python3 - "$STAGE" <<'PY'
import os, random, sys
random.seed(7)
root = os.path.join(sys.argv[1], "Aurora Brand Kit")
files = {
    "Read Me First.txt": 2_400, "Brand Guidelines.pdf": 4_812_000, "Colors.ase": 18_400, "Notes.md": 5_200,
    "Logos/Aurora Logo.svg": 14_200, "Logos/Aurora Logo.png": 482_000, "Logos/Aurora Logo Dark.png": 466_000,
    "Logos/Aurora Mark.pdf": 96_000, "Logos/Favicon.ico": 15_100,
    "Photos/Team Offsite 2026.jpg": 3_420_000, "Photos/Office Morning.jpg": 2_870_000,
    "Photos/Product Hero.heic": 1_960_000, "Photos/Launch Night.mov": 9_340_000,
    "Fonts/Inter Display.otf": 312_000, "Fonts/Inter Text.otf": 298_000, "Fonts/License.txt": 4_300,
    "Templates/Keynote Deck.key": 2_150_000, "Templates/Letterhead.docx": 86_000,
    "Templates/Business Card.sketch": 742_000, "Templates/Social/Instagram Post.psd": 1_840_000,
    "Templates/Social/Story.psd": 1_530_000,
    "Web/index.html": 8_600, "Web/styles.css": 21_300, "Web/app.js": 64_000, "Web/assets/hero@2x.webp": 388_000,
}
words = ("aurora brand kit guidelines logo color type spacing grid photo web " * 40).split()
for path, size in files.items():
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        if path.endswith((".txt", ".md", ".html", ".css", ".js", ".svg")):
            f.write(" ".join(random.choice(words) for _ in range(size // 6)).encode()[:size])
        else:
            # Half noise, half pattern: it packs to something believable.
            f.write(os.urandom(size // 2) + b"\x00\x11\x22\x33" * (size // 8))
os.makedirs(os.path.join(root, "Exports"), exist_ok=True)
PY
SEVENZIP="$APP/Contents/Helpers/7zz"
(cd "$STAGE" && "$SEVENZIP" a -tzip -mx=5 "Aurora Brand Kit.zip" "Aurora Brand Kit" -bso0 -bsp0 \
              && "$SEVENZIP" a -t7z -mx=7 "Aurora Brand Kit.7z" "Aurora Brand Kit" -bso0 -bsp0)
# Something in the way, for the picture of the question about it.
mkdir -p "$STAGE/Existing/Aurora Brand Kit" && echo "mine" > "$STAGE/Existing/Aurora Brand Kit/Notes.md"

# --- Taking them -------------------------------------------------------------------

# The windows that the copy of the app with the given process identifier has on screen:
# "id<TAB>width<TAB>title", front to back. Before listing them the app is brought to the
# front, so that its window is drawn the way a window in use is. That takes the
# Accessibility permission; without it the pictures are taken all the same, of a window
# that may look inactive.
windows() {
    OPENZIP_PID=$1 swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
let pid = pid_t(ProcessInfo.processInfo.environment["OPENZIP_PID"] ?? "") ?? 0
if let app = NSRunningApplication(processIdentifier: pid) {
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.8)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(window[kCGWindowNumber as String] as? Int ?? 0)\t\(bounds["Width"] as? Int ?? 0)\t\(window[kCGWindowName as String] as? String ?? "")")
}
SWIFT
}

# shot NAME SECONDS WHICH ARGUMENTS…: stages a scene with the demo's arguments, waits,
# and saves a window as docs/images/NAME.png, with its shadow on a transparent ground.
# WHICH is "front" for the frontmost window (a sheet counts as one) or "main" for the widest.
shot() {
    local name=$1 seconds=$2 which=$3
    shift 3
    stop
    sleep 0.4
    # The pictures are for everybody: numbers and dates as the United States writes them,
    # and scroll bars that show only while scrolling, as on a Mac with a trackpad,
    # whatever the Mac that takes them is set to or has plugged in.
    open -n -a "$APP" --args --demo --locale en_US -ApplePersistenceIgnoreState YES \
        -AppleShowScrollBars WhenScrolling "$@"
    sleep "$seconds"
    local pid id
    pid=$(ours | head -1)
    [[ -n "$pid" ]] || { echo "!! the app did not start for $name" >&2; return 1; }
    if [[ $which == main ]]; then
        id=$(windows "$pid" | sort -t$'\t' -k2 -n -r | head -1 | cut -f1)
    else
        id=$(windows "$pid" | head -1 | cut -f1)
    fi
    [[ -n "$id" ]] || { echo "!! no window for $name" >&2; return 1; }
    screencapture -x -l "$id" "$OUT/$name.png"
    echo "==> $OUT/$name.png"
}

ZIP="$STAGE/Aurora Brand Kit.zip"
SEVEN="$STAGE/Aurora Brand Kit.7z"
for look in light dark; do
    shot "hero-$look" 4 main --appearance $look --open "$ZIP" --size 1180x720 \
        --folder "Aurora Brand Kit" --select Logos --select Photos
done
shot info-dark 4 main --appearance dark --open "$SEVEN" --size 1280x740 \
    --folder "Aurora Brand Kit/Logos" --select "Aurora Logo.png" --inspector
shot new-archive-light 4 front --appearance light --compress "$STAGE/Aurora Brand Kit" --where "$HOME/Desktop"
shot extract-light 4 main --appearance light --open "$ZIP" --size 1180x720 --sheet extract --destination "$HOME/Downloads"
shot conflict-dark 5 main --appearance dark --open "$ZIP" --size 1180x720 --do "extractAsking:$STAGE/Existing"
shot welcome-dark 3 front --appearance dark --welcome \
    --recent "~/Downloads/Aurora Brand Kit.zip" --recent "~/Documents/Taxes 2025.7z" \
    --recent "~/Desktop/Lisbon Photos.rar" --recent "~/Downloads/node-v24.11.0.tar.gz"
shot settings-light 3 front --appearance light --settings --pane finder

# The icon in its everyday colors, whatever the Mac that takes the pictures is set to.
ICTOOL="${DEVELOPER_DIR:-$(xcode-select -p)}/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" OpenZip/AppIcon.icon --export-image --output-file "$OUT/icon.png" \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1 > /dev/null
echo "==> $OUT/icon.png"
