import AppKit
import VisionHarnessCore

/// The first launch as Vision brings over what the app kept when it was called DSH: its data folder and its
/// settings (see `IdentityMigration.swift`; Keychain items follow one by one when first needed). This runs before
/// anything reads either, from `VisionLauncher.main`.
@MainActor
enum LaunchMigration {
    /// Why the data folder couldn't be settled this launch (the app then works in the old folder, and tries again
    /// next launch); nil when it is settled.
    static var failure: String?

    static func run() {
        // An isolated run (the screenshot mode) never touches what the user has, old or new.
        guard !IsolatedRun.isActive else { return }
        let carryOn = run(base: AppPaths.applicationSupport, defaults: .standard,
                          ownDomain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
                          legacyDomain: AppIdentity.Legacy.bundleIdentifier, legacyAppIsClosed: legacyAppIsClosed)
        if !carryOn { exit(0) }
    }

    /// The launch's moves, against `base` (`~/Library/Application Support`) and the settings file `ownDomain`
    /// that `defaults` writes. False: the old app is still open and the user chose to quit (nothing was touched).
    static func run(base: URL, defaults: UserDefaults, ownDomain: String, legacyDomain: String,
                    legacyAppIsClosed: () -> Bool) -> Bool {
        failure = nil
        let legacySettings = defaults.persistentDomain(forName: legacyDomain)
        let settingsPending = defaults.persistentDomain(forName: ownDomain)?[LegacySettingsImport.importedKey] == nil
            && !(legacySettings?.isEmpty ?? true)
        if DataFolderMigration.isPending(in: base) || settingsPending {
            guard legacyAppIsClosed() else { return false }
        }

        switch DataFolderMigration.run(in: base) {
        case .failed(let reason):
            failure = reason
            NSLog("%@: the data folder was not moved yet (%@); using the old one this time.", AppIdentity.name, reason)
        case .migrated:
            defaults.set(true, forKey: LegacySettingsImport.noticePendingKey)
        case .alreadySettled, .started:
            break
        }

        // Once, whatever became of the folder: the settings name the folder the app is working in either way.
        _ = LegacySettingsImport.run(legacy: legacySettings, into: defaults,
                                     existing: defaults.persistentDomain(forName: ownDomain))
        let current = DataFolderMigration.currentFolder(in: base)
        LegacySettingsImport.movePaths(in: defaults, existing: defaults.persistentDomain(forName: ownDomain),
                                       settled: DataFolderMigration.settledMarker(of: current), newFolder: current)
        return true
    }

    /// The old app must be closed while its data is copied, or what it writes meanwhile would be left behind. Asks
    /// the user to quit it (it saves its chats on the way out). False: it is still open, and Vision quits.
    private static func legacyAppIsClosed() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.Legacy.bundleIdentifier)
        guard !running.isEmpty else { return true }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let ask = NSAlert()
        ask.messageText = "\(AppIdentity.Legacy.name) is still open"
        ask.informativeText = "\(AppIdentity.Legacy.name) is now called \(AppIdentity.name). The first time it opens, "
            + "\(AppIdentity.name) brings over \(AppIdentity.Legacy.name)'s chats, settings and keys, so "
            + "\(AppIdentity.Legacy.name) has to be closed first — nothing it is still writing gets left behind."
        ask.addButton(withTitle: "Quit \(AppIdentity.Legacy.name) and Continue")
        ask.addButton(withTitle: "Quit \(AppIdentity.name)")
        guard ask.runModal() == .alertFirstButtonReturn else { return false }

        for old in running { old.terminate() }
        let deadline = Date().addingTimeInterval(20)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard running.contains(where: { !$0.isTerminated }) else { return true }

        let stuck = NSAlert()
        stuck.messageText = "\(AppIdentity.Legacy.name) didn't quit"
        stuck.informativeText = "Quit \(AppIdentity.Legacy.name) yourself (it may be asking something), then open \(AppIdentity.name) again."
        stuck.addButton(withTitle: "Quit \(AppIdentity.name)")
        stuck.runModal()
        return false
    }

    /// The one-time notice after the move, in the app's words.
    static let renameNotice = "\(AppIdentity.Legacy.name) is now \(AppIdentity.name) — your chats, settings and keys "
        + "came with you. macOS will ask again for Screen Recording, Accessibility and Automation the first time "
        + "\(AppIdentity.name) needs them, and may ask once to let \(AppIdentity.name) use each key saved in your Keychain."
}
