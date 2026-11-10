# Contributing

Thank you for wanting to make OpenZip better.

## Reporting a problem

Open an [issue](https://github.com/burakgon/openzip-mac/issues/new/choose) and say what you did,
what you expected and what happened. The version of OpenZip (Settings → About) and of macOS, and
what kind of archive it was, usually decide how quickly it can be found: the format, roughly how
large, whether it has a password or is split into volumes, and which program made it.

An archive that shows the problem is worth more than any description. If yours is private, try to
make a small one that fails the same way.

## Building

You need Xcode 27 or later. Open `OpenZip.xcodeproj` and run, or:

```sh
xcodebuild -project OpenZip.xcodeproj -scheme OpenZip -derivedDataPath build/DerivedData build
swift test --package-path Packages/OpenZipKit
```

The first build downloads the source of 7-Zip from its
[own repository](https://github.com/ip7z/7zip) and compiles it into `Vendor/7zz`: that takes
about half a minute, once. [`scripts/build-7zz.sh`](scripts/build-7zz.sh) does it, and can be run
by hand before `swift test` on a fresh clone.

The app is signed ad hoc unless you create `Config/Local.xcconfig` with your own signing identity;
`Config/Base.xcconfig` explains how. macOS only loads the Finder extension from an app that is
signed with a real identity, so the entries in the Finder's context menu need that. Everything
else works without.

To write RAR archives the tests and the app need RARLAB's `rar`. The tests that need it are
skipped when it is not installed; `OPENZIP_RAR=/path/to/rar swift test …` points them to one.

## Trying things from a terminal

Start the app with `--demo` to drive it without clicking:

```sh
OpenZip.app/Contents/MacOS/OpenZip --demo --open ~/Downloads/some.zip \
    --do select:readme.txt --do rename:README.txt --do test --do quit
```

`OpenZip/Support/Demo.swift` lists the arguments. The screenshots of the README are staged the
same way, by [`scripts/screenshots.sh`](scripts/screenshots.sh).

## Where things are

- `Packages/OpenZipKit` is everything that is not user interface: running 7-Zip and reading what
  it prints, listing, extracting, creating and changing archives, and what a Mac expects around
  that (quarantine, resource forks, where extracted files end up). It has the tests, and they run
  the real 7-Zip on real archives.
- `OpenZip` is the app: the archive windows, the window that creates archives, the settings.
- `OpenZipFinder` is the Finder extension. It only tells the app what was chosen.

Logic that can be tested belongs in the kit, with a test.

## Changes

- Keep a change about one thing, and say in the commit message what it does and why.
- Match the code around you: plain Swift, no new dependencies without a very good reason, and
  comments that explain why something is the way it is rather than what the next line does.
- An archive tool handles other people's data. A change that touches extracting, deleting or
  rewriting archives needs a test that shows nothing is lost when it goes wrong halfway.
- The app has to stay light. If a change makes it use the processor while idle, or keep
  noticeably more memory, that needs a reason.
- Run `swift test --package-path Packages/OpenZipKit` before you open a pull request.
- Interface changes are easiest to review with a before and after screenshot.

## Releasing

For maintainers: set the version in `Config/Version.xcconfig`, add a section for it to
`CHANGELOG.md`, commit, push, and run `scripts/release.sh --publish`. The script's header
describes the credentials it uses. Pushing a `v1.2.3` tag instead lets the Release workflow do the
same on GitHub, once `scripts/add-release-secrets.sh` has stored its secrets.

A new version of 7-Zip is two lines in `scripts/build-7zz.sh`: its number and the SHA-256 of its
source archive.
