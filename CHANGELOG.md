# Changelog

Notable changes to OpenZip, newest first. Versions follow [semantic versioning](https://semver.org).

## 1.0.1

- **Quiet in the Finder.** “Extract Here” and the other commands in the Finder’s menu no longer bring up the welcome window next to their work, and OpenZip leaves again when the work is done.
- **RAR keeps installing.** RARLAB has renamed its package for Apple silicon and taken the one for Intel Macs off its page. The download in the settings finds both: for an Intel Mac that is RAR 7.23, the last one made for it.
- **Windows that fit.** The New Archive window opens as tall as its form and stays on the screen when it grows, instead of slipping behind the Dock. Each pane of the settings has the height it needs, and the welcome window shows its recent archives without cutting off the last. None of them scrolls anymore.

## 1.0.0

The first release.

- **Archives open like folders.** A window shows what is in an archive, with a sidebar of its folders, columns to sort by, a search field and Quick Look, without extracting anything.
- **Archives are changed in place.** Add files by dropping them in, delete, rename, move, make folders. The archive is rewritten, not extracted and packed again.
- **Fifty formats to open.** ZIP, 7z, RAR, TAR, GZ, BZ2, XZ, Zstandard, ISO, DMG, CAB, WIM, CPIO, RPM, DEB and more, including archives split into volumes and encrypted ones.
- **Seven to create.** ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ and WIM, with compression levels, AES-256 passwords, hidden file names, split volumes and profiles to keep settings in. RAR too, where RARLAB’s RAR is installed: with recovery records, locking and repair.
- **At home in the Finder.** “Extract Here”, “Compress to ZIP” and the rest in the Finder’s context menu, drag files out of an archive and into it, and drop anything on the Dock icon.
- **Careful with what it extracts.** The quarantine of a downloaded archive is passed on to its content, resource forks are folded back into their files, and nothing is written to the destination before an extraction is complete.
- **Light.** A native app in Swift, with 7-Zip in a process of its own doing the reading and writing.
