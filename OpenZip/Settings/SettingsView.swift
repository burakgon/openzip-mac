import FinderSync
import OpenZipKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var pane = Demo.value("--pane") ?? "general"

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralPane() }
            Tab("Extracting", systemImage: "square.and.arrow.down", value: "extracting") { ExtractingPane() }
            Tab("Finder", systemImage: "macwindow.on.rectangle", value: "finder") { FinderPane() }
            Tab("RAR", systemImage: "books.vertical", value: "rar") { RarPane() }
            Tab("About", systemImage: "info.circle", value: "about") { AboutPane() }
        }
        .frame(width: 560)
    }
}

// MARK: General

private struct GeneralPane: View {
    @Bindable private var settings = AppModel.shared.settings

    var body: some View {
        Form {
            Section {
                Picker("Opening an archive from the Finder", selection: $settings.openAction) {
                    ForEach(OpenAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show the files macOS makes (.DS_Store, __MACOSX)", isOn: $settings.showsMacFiles)
                Toggle("Ask before deleting from an archive", isOn: $settings.confirmsDeleting)
            }
            Section("New archives") {
                Picker("When an archive has been created", selection: $settings.afterCompressing) {
                    ForEach(AfterCompressing.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Format and compression") {
                    Text("\(settings.lastOptions.format.displayName), \(settings.lastOptions.level.displayName.lowercased()) — as chosen last time")
                        .foregroundStyle(.secondary)
                }
                Button("Restore the Built-in Profiles") {
                    settings.profiles = AppSettings.builtInProfiles
                }
            }
            Section {
                Toggle("Notify when an operation ends while OpenZip is in the background", isOn: $settings.notifiesWhenDone)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Extracting

private struct ExtractingPane: View {
    @Bindable private var settings = AppModel.shared.settings

    var body: some View {
        Form {
            Section {
                Picker("Make a folder for the extracted items", selection: $settings.folderChoice) {
                    ForEach(FolderChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("If a file exists already", selection: $settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Show the result in the Finder", isOn: $settings.revealAfterExtracting)
                Toggle("Move the archive to the Trash after extracting it from the Finder", isOn: $settings.trashArchiveAfterExtracting)
            } footer: {
                Text("Extracting from the Finder’s menu never asks and never replaces anything: a file that exists is kept and the new one gets a number.")
            }
            Section {
                Toggle("Keep the quarantine of downloaded archives", isOn: $settings.keepQuarantine)
                Toggle("Restore resource forks and extended attributes", isOn: $settings.restoreMacMetadata)
            } header: {
                Text("macOS")
            } footer: {
                Text("With the quarantine kept, an app that comes out of a downloaded archive is checked by Gatekeeper before it runs, as if it had been downloaded itself. Turning this off is not recommended.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Finder

private struct FinderPane: View {
    @State private var isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var defaults: [String: String] = [:]
    @State private var failure: String?

    /// The kinds of archive, with the type that stands for each.
    private static let kinds: [(name: String, types: [String])] = [
        ("ZIP", ["public.zip-archive"]),
        ("7z", ["org.7-zip.7-zip-archive"]),
        ("RAR", ["com.rarlab.rar-archive"]),
        ("TAR, TAR.GZ, TAR.BZ2, TAR.XZ", ["public.tar-archive", "org.gnu.gnu-zip-tar-archive", "public.tar-bzip2-archive", "org.tukaani.tar-xz-archive"]),
        ("GZ, BZ2, XZ, Z, ZST", ["org.gnu.gnu-zip-archive", "public.bzip2-archive", "org.tukaani.xz-archive", "public.z-archive", "com.facebook.zstandard-archive"]),
        ("CAB, WIM, ARJ, LZH", ["com.microsoft.cab", "com.microsoft.wim-archive", "cx.c3.arj-archive", "org.lha.lzh-archive"]),
        ("ISO", ["public.iso-image"]),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if isExtensionEnabled {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Turn On in System Settings…") {
                            FIFinderSyncController.showExtensionManagementInterface()
                        }
                    }
                } label: {
                    Text("OpenZip in the Finder’s menu")
                    Text("Right-click files in the Finder for “Extract Here”, “Compress to ZIP” and the rest.")
                }
                if !isExtensionEnabled {
                    Text("macOS asks you to turn extensions on yourself. In the window that opens, switch on OpenZip. Until then the same commands are under Services at the bottom of the Finder’s menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(Self.kinds, id: \.name) { kind in
                    LabeledContent(kind.name) {
                        let current = defaults[kind.types[0]] ?? "—"
                        if current == "OpenZip" {
                            Label("OpenZip", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            HStack {
                                Text(current)
                                    .foregroundStyle(.secondary)
                                Button("Use OpenZip") { makeDefault(for: kind.types) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Button("Use OpenZip for All of Them") {
                    makeDefault(for: Self.kinds.flatMap(\.types))
                }
            } header: {
                Text("Opens with a double click")
            } footer: {
                Text(failure ?? "What a double click does once OpenZip opens an archive, showing or extracting it, is chosen under General.")
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        for kind in Self.kinds {
            guard let type = UTType(kind.types[0]), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
                defaults[kind.types[0]] = "—"
                continue
            }
            let isOwn = app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            defaults[kind.types[0]] = isOwn ? "OpenZip" : FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    private func makeDefault(for types: [String]) {
        failure = nil
        Task {
            for identifier in types {
                guard let type = UTType(identifier) else { continue }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                } catch {
                    failure = "macOS did not change the default for \(type.localizedDescription ?? identifier): \(error.localizedDescription)"
                }
            }
            refresh()
        }
    }
}

// MARK: RAR

private struct RarPane: View {
    @State private var version: String?
    @State private var isRegistered = false
    @State private var isInstalling = false
    @State private var failure: String?
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Opening and extracting RAR") {
                    Label("Built in", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("Creating and changing RAR") {
                    if let rar = app.tools.rar {
                        VStack(alignment: .trailing, spacing: 2) {
                            Label(version ?? "RAR", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(Formatting.folder(rar))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Needs RARLAB’s RAR")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("RAR is a proprietary format. Reading it is free for everyone, and OpenZip does it by itself. Writing it is something only RARLAB’s own program may do, so for creating RAR archives, adding a recovery record or repairing one, OpenZip uses that program if it is on your Mac.")
            }

            Section {
                if isInstalling {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading from rarlab.com…")
                    }
                } else {
                    Button(app.tools.rar == nil ? "Download RAR from rarlab.com" : "Download the Newest RAR", action: install)
                    Button("Choose a RAR I Already Have…", action: choose)
                    if FileManager.default.fileExists(atPath: Tools.managedRarFolder.path) {
                        Button("Remove the Downloaded RAR", role: .destructive) {
                            RarInstaller.remove()
                            app.refreshTools()
                            refresh()
                        }
                    }
                }
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("RAR is shareware by RARLAB: it is free to try for 40 days and asks for a license after that, which is bought at rarlab.com. It is downloaded from RARLAB as it is and is not a part of OpenZip. A RAR installed with Homebrew is found by itself."
                     + (app.tools.rar != nil ? (isRegistered ? " A license key was found." : " No license key was found: this is the trial.") : ""))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard let rar = app.tools.rar else {
            version = nil
            return
        }
        Task {
            version = await Task.detached { RarInstaller.version(of: rar) }.value
            isRegistered = RarInstaller.isRegistered(rar)
        }
    }

    private func install() {
        isInstalling = true
        failure = nil
        Task {
            do {
                _ = try await RarInstaller.install()
                app.settings.customRarPath = ""
                app.refreshTools()
            } catch {
                failure = error.localizedDescription
            }
            isInstalling = false
            refresh()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use"
        panel.message = "Choose the program named “rar”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard RarInstaller.version(of: url) != nil else {
            failure = "“\(url.lastPathComponent)” is not RARLAB’s rar."
            return
        }
        failure = nil
        app.settings.customRarPath = url.path
        app.refreshTools()
        refresh()
    }
}

// MARK: About

private struct AboutPane: View {
    @State private var checksAutomatically = false
    @State private var downloadsAutomatically = false
    private var updater: Updater { AppModel.shared.updater }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OpenZip")
                            .font(.title2.weight(.semibold))
                        Text("Version \(version)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Free and open source, under the MIT License.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Link("Website", destination: URL(string: "https://burakgon.github.io/openzip-mac/")!)
                    Text("·").foregroundStyle(.tertiary)
                    Link("Source Code", destination: URL(string: "https://github.com/burakgon/openzip-mac")!)
                    Text("·").foregroundStyle(.tertiary)
                    Link("Report a Problem", destination: URL(string: "https://github.com/burakgon/openzip-mac/issues/new/choose")!)
                }
                .font(.callout)
            }

            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksAutomatically)
                        .onChange(of: checksAutomatically) { _, value in updater.automaticallyChecksForUpdates = value }
                    Toggle("Download and install them automatically", isOn: $downloadsAutomatically)
                        .onChange(of: downloadsAutomatically) { _, value in updater.automaticallyDownloadsUpdates = value }
                        .disabled(!checksAutomatically)
                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates() }
                    } label: {
                        Text(updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                    }
                }
            }

            Section {
                acknowledgement("7-Zip \(sevenZipVersion)", "Reads and writes the archives. By Igor Pavlov, under the GNU LGPL, with the unRAR restriction for its RAR code.", license: "7-Zip License")
                acknowledgement("Sparkle", "Installs updates. By the Sparkle Project, under the MIT License.", license: nil)
            } header: {
                Text("Built with")
            } footer: {
                Text("OpenZip is not affiliated with RARLAB, win.rar GmbH or 7-Zip. WinRAR and RAR are trademarks of their owners.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checksAutomatically = updater.automaticallyChecksForUpdates
            downloadsAutomatically = updater.automaticallyDownloadsUpdates
        }
    }

    private func acknowledgement(_ name: String, _ text: String, license: String?) -> some View {
        LabeledContent {
            if let license, let url = Bundle.main.url(forResource: license, withExtension: "txt") {
                Button("License") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        } label: {
            Text(name)
            Text(text)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// The version of the 7-Zip in the bundle, from the name of its license's sibling file
    /// is not possible; it is asked for instead, once.
    private var sevenZipVersion: String {
        SevenZipVersion.value
    }
}

/// The version of the 7-Zip inside the app, as it reports it itself.
enum SevenZipVersion {
    static let value: String = {
        let process = Process()
        process.executableURL = AppModel.shared.tools.sevenZip
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // "7-Zip (z) 26.06 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-11-06"
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("7-Zip") }) else { return "" }
        let words = line.split(separator: " ")
        return words.count > 2 ? String(words[2]) : ""
    }()
}
