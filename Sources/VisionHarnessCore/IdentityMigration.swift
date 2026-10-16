import Foundation

// MARK: - Bringing an earlier build's data over
//
// Before it was called Vision the app kept its data in `~/Library/Application Support/DSHMac` and its settings
// under the bundle identifier `dev.local.dsh.mac` (`AppIdentity.Legacy`). On the first launch as Vision both come
// over, once, before anything else reads them:
//
// - The data folder is copied (APFS clones the files, so it costs no space), the copy is checked against the
//   original, the absolute paths the app stored inside it are pointed at the new folder, and only then is the copy
//   moved into place and marked settled — the marker is the last thing written, so a crash at any point leaves the
//   original untouched and the next launch starts over. Until the folder is settled the app keeps working in the
//   old one (`AppPaths.resolveSupport`). The old folder is left where it is, as a backup, with a note in it.
// - Every setting is copied into the new settings file (one the new file already has is kept), then marked done.
//   Paths in the settings are pointed at the new data folder in a separate step that runs once the folder is
//   settled, so settings never point at a folder the app isn't using.
//
// Keychain items come over one at a time when first needed (`LegacyFallbackSecretStore`). Nothing here logs a
// secret: the settings file holds none (keys live in the Keychain), and no value is logged at all.

/// Points paths that lead into the old data folder at the new one: a plain path ("/Users/…/DSHMac/skills/x") or a
/// file URL ("file:///Users/…/Application%20Support/DSHMac/…"). Anything else is left alone.
public struct DataFolderPathRewriter: Sendable, Equatable {
    public let from: String
    public let to: String
    private let fromURL: String
    private let toURL: String

    public init(from: URL, to: URL) {
        self.from = Self.trimmed(from.path)
        self.to = Self.trimmed(to.path)
        fromURL = URL(fileURLWithPath: self.from, isDirectory: true).absoluteString
        toURL = URL(fileURLWithPath: self.to, isDirectory: true).absoluteString
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The same place in the new folder, or nil when `text` doesn't point into the old one.
    public func rewrite(_ text: String) -> String? {
        if text == from { return to }
        if text.hasPrefix(from + "/") { return to + text.dropFirst(from.count) }
        if text + "/" == fromURL { return String(toURL.dropLast()) }
        if text.hasPrefix(fromURL) { return toURL + text.dropFirst(fromURL.count) }
        return nil
    }

    /// `text` with the old folder replaced wherever it appears as a whole path inside it ("code.state./Users/…").
    public func rewriteEmbedded(_ text: String) -> String? {
        if let whole = rewrite(text) { return whole }
        var out = ""
        var rest = text[...]
        var changed = false
        while let range = rest.range(of: from) {
            let after = rest[range.upperBound...]
            out += rest[..<range.lowerBound]
            if after.isEmpty || after.hasPrefix("/") {
                out += to
                changed = true
            } else {
                out += rest[range]
            }
            rest = after
        }
        return changed ? out + rest : nil
    }

    /// A settings value (a property list) with every path into the old folder moved: strings, the items of arrays,
    /// the keys and values of dictionaries, and JSON kept as data. Nil when nothing in it changes.
    public func rewrite(value: Any) -> Any? {
        switch value {
        case let text as String:
            return rewrite(text)
        case let list as [Any]:
            var changed = false
            let moved = list.map { item -> Any in
                guard let new = rewrite(value: item) else { return item }
                changed = true
                return new
            }
            return changed ? moved : nil
        case let dictionary as [String: Any]:
            var changed = false
            var moved: [String: Any] = [:]
            for (key, item) in dictionary {
                let newKey = rewriteEmbedded(key)
                let newItem = rewrite(value: item)
                if newKey != nil || newItem != nil { changed = true }
                moved[newKey ?? key] = newItem ?? item
            }
            return changed ? moved : nil
        case let data as Data:
            // Settings the app encodes as JSON (per-chat skill choices, for one) hold paths too. Data that isn't
            // JSON (an archived object) is left as it is.
            guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let moved = rewrite(value: json),
                  let encoded = try? JSONSerialization.data(withJSONObject: moved, options: [.fragmentsAllowed])
            else { return nil }
            return encoded
        default:
            return nil
        }
    }

    /// A JSON tree with the values of `keys` moved, wherever those keys appear (only those: the text of a chat is
    /// the user's, and a path someone wrote in it stays as written). Nil when nothing changes.
    public func rewrite(json: Any, keys: Set<String>) -> Any? {
        switch json {
        case let list as [Any]:
            var changed = false
            let moved = list.map { item -> Any in
                guard let new = rewrite(json: item, keys: keys) else { return item }
                changed = true
                return new
            }
            return changed ? moved : nil
        case let dictionary as [String: Any]:
            var changed = false
            var moved = dictionary
            for (key, item) in dictionary {
                if keys.contains(key), let text = item as? String, let new = rewrite(text) {
                    moved[key] = new
                    changed = true
                } else if let new = rewrite(json: item, keys: keys) {
                    moved[key] = new
                    changed = true
                }
            }
            return changed ? moved : nil
        default:
            return nil
        }
    }
}

// MARK: - The data folder

public enum DataFolderMigration {
    /// In the data folder: the folder is the app's own and settled. Written last.
    public static let markerName = ".vision-data-folder.json"
    /// In a copy made from the old folder until it is settled.
    static let stagedMarkerName = ".vision-migration-staged"
    /// Next to the data folder, while the old one is being copied.
    static let stagingName = ".Vision-migration-staging"
    /// Next to the data folder while a launch settles it.
    static let lockName = ".Vision-migration.lock"
    /// Left in the old folder once its copy is settled.
    public static let legacyNoteName = "Moved to \(AppIdentity.name).txt"

    /// What the marker records.
    public struct Marker: Codable, Equatable, Sendable {
        public var version = 1
        /// The old folder the data was copied from (nil: there was none).
        public var migratedFrom: String?
        public var at: Date
        /// Files and folders copied, and app files whose stored paths were moved.
        public var items: Int?
        public var rewrittenFiles: Int?
        /// A folder already at the new name, not made by the app, moved aside first (its new name).
        public var setAside: String?
    }

    public struct Report: Equatable, Sendable {
        public var items: Int
        public var rewrittenFiles: Int
        public var setAside: String?
    }

    public enum Outcome: Equatable, Sendable {
        /// Settled by an earlier launch.
        case alreadySettled
        /// No old folder: a new start, now settled.
        case started
        /// The old folder's data was copied over and is settled.
        case migrated(Report)
        /// Not settled (the reason, for the user and the log); the app keeps using the old folder.
        case failed(String)
    }

    /// The steps after which a test can stop the migration, as a crash would.
    enum Step: CaseIterable { case copied, rewritten, staged, moved, marked }

    /// `<base>/Vision`.
    public static func currentFolder(in base: URL) -> URL {
        base.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
    }

    /// `<base>/DSHMac`, the folder an earlier build used.
    public static func legacyFolder(in base: URL) -> URL {
        base.appendingPathComponent(AppIdentity.Legacy.supportFolderName, isDirectory: true)
    }

    public static func isSettled(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: folder.appendingPathComponent(markerName).path)
    }

    /// Whether `run` has work to do: the new folder isn't settled and an old one exists.
    public static func isPending(in base: URL, fileManager: FileManager = .default) -> Bool {
        !isSettled(currentFolder(in: base), fileManager: fileManager) && isDirectory(legacyFolder(in: base), fileManager)
    }

    /// Settle the data folder under `base` (`~/Library/Application Support`). Safe to run every launch, and to
    /// run again after a crash at any point.
    public static func run(in base: URL, fileManager fm: FileManager = .default, now: Date = .now) -> Outcome {
        if isSettled(currentFolder(in: base), fileManager: fm) {
            return run(in: base, fileManager: fm, now: now, stopAfter: nil)
        }
        // Two copies of the app opening at once (`open -n`) take turns: the second finds the folder settled.
        let lockFile = base.appendingPathComponent(lockName)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let lock = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        let outcome = run(in: base, fileManager: fm, now: now, stopAfter: nil)
        if lock >= 0 {
            // Settled, nobody needs the lock again (whoever waits on it checks again once it has it).
            if case .failed = outcome {} else { try? fm.removeItem(at: lockFile) }
            flock(lock, LOCK_UN)
            close(lock)
        }
        return outcome
    }

    static func run(in base: URL, fileManager fm: FileManager, now: Date, stopAfter: Step?) -> Outcome {
        let current = currentFolder(in: base)
        let legacy = legacyFolder(in: base)
        let staging = base.appendingPathComponent(stagingName, isDirectory: true)
        if isSettled(current, fileManager: fm) {
            // A crash between writing the marker and tidying up leaves the staged marker: harmless, but tidy.
            try? fm.removeItem(at: current.appendingPathComponent(stagedMarkerName))
            return .alreadySettled
        }
        do {
            guard isDirectory(legacy, fm) else {
                // Nothing to bring over: a new start. (A finished copy whose original has since gone counts as ours.)
                let staged = fm.fileExists(atPath: current.appendingPathComponent(stagedMarkerName).path)
                try fm.createDirectory(at: current, withIntermediateDirectories: true)
                try writeMarker(Marker(migratedFrom: staged ? legacy.path : nil, at: now), in: current)
                try? fm.removeItem(at: current.appendingPathComponent(stagedMarkerName))
                return .started
            }

            // A copy an interrupted run left behind is only ever a partial copy of the old folder: start it again.
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }

            var setAside: String?
            if fm.fileExists(atPath: current.path) {
                if fm.fileExists(atPath: current.appendingPathComponent(stagedMarkerName).path) {
                    // A finished copy that was never marked settled. The app never used it (it kept working in the
                    // old folder, which may have changed since), so it is copied again.
                    try fm.removeItem(at: current)
                } else if isEffectivelyEmpty(current, fm) {
                    try fm.removeItem(at: current)
                } else {
                    // Something else made a folder with the new name: keep it, out of the way.
                    let aside = asideName(in: base, now: now, fileManager: fm)
                    try fm.moveItem(at: current, to: base.appendingPathComponent(aside, isDirectory: true))
                    setAside = aside
                }
            }

            // 1. Copy (on APFS each file is a clone of the original).
            let source = legacy.resolvingSymlinksInPath()
            try fm.copyItem(at: source, to: staging)
            guard let original = inventory(source, fm), let copy = inventory(staging, fm) else {
                try? fm.removeItem(at: staging)
                return .failed("the folder couldn't be listed")
            }
            guard original == copy else {
                try? fm.removeItem(at: staging)
                let missing = Set(original.keys).symmetricDifference(copy.keys).count
                let differ = original.keys.filter { copy[$0] != nil && copy[$0] != original[$0] }.count
                return .failed("the copy didn't match the original (\(missing) missing, \(differ) different)")
            }
            if stopAfter == .copied { return .failed("stopped after copying") }

            // 2. Point the paths the app stored at the new folder.
            let rewriter = DataFolderPathRewriter(from: legacy, to: current)
            let rewritten = try rewriteStoredPaths(in: staging, rewriter: rewriter, fileManager: fm)
            if stopAfter == .rewritten { return .failed("stopped after moving paths") }

            // 3. Mark the copy finished, then move it into place (a rename: all at once).
            try Data().write(to: staging.appendingPathComponent(stagedMarkerName), options: .atomic)
            if stopAfter == .staged { return .failed("stopped after staging") }
            try fm.moveItem(at: staging, to: current)
            if stopAfter == .moved { return .failed("stopped after moving into place") }

            // 4. Settled: the marker is written last.
            try writeMarker(Marker(migratedFrom: legacy.path, at: now, items: original.count,
                                   rewrittenFiles: rewritten, setAside: setAside), in: current)
            if stopAfter == .marked { return .failed("stopped after marking") }
            try? fm.removeItem(at: current.appendingPathComponent(stagedMarkerName))
            leaveNote(in: legacy, newFolder: current, now: now)
            return .migrated(Report(items: original.count, rewrittenFiles: rewritten, setAside: setAside))
        } catch {
            try? fm.removeItem(at: staging)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Stored paths

    /// The app's own files that store absolute paths into the data folder, and the keys that hold them.
    /// (`Chats/<id>` scratch folders and user skills hold the user's files, which are never rewritten.)
    static func storedPathFiles(in folder: URL, fileManager fm: FileManager) -> [(URL, Set<String>)] {
        var files: [(URL, Set<String>)] = [(folder.appendingPathComponent("task-queue.json"), ["cwd", "workFolder"])]
        let conversations = folder.appendingPathComponent("conversations", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "json" {
            files.append((url, ["cwd", "scratch"]))
        }
        let drafts = folder.appendingPathComponent("skill-drafts", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)) ?? [] {
            files.append((url.appendingPathComponent("draft.json"), ["projectPath"]))
        }
        return files
    }

    /// Rewrite the stored paths in the app's files under `folder`; returns how many files changed. A file that
    /// isn't readable JSON is left exactly as it is (it keeps pointing at the old folder, which stays in place).
    static func rewriteStoredPaths(in folder: URL, rewriter: DataFolderPathRewriter, fileManager fm: FileManager) throws -> Int {
        var count = 0
        for (url, keys) in storedPathFiles(in: folder, fileManager: fm) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let moved = rewriter.rewrite(json: json, keys: keys),
                  let encoded = try? JSONSerialization.data(withJSONObject: moved) else { continue }
            try encoded.write(to: url, options: .atomic)
            count += 1
        }
        return count
    }

    // MARK: Helpers

    struct Entry: Equatable {
        var type: FileAttributeType?
        var size: UInt64
        var link: String?
    }

    /// Every item under `root` (relative path → type, size of a file, target of a link). Links are listed, not
    /// followed. Nil when something can't be read.
    static func inventory(_ root: URL, _ fm: FileManager) -> [String: Entry]? {
        guard let walker = fm.enumerator(atPath: root.path) else { return nil }
        var out: [String: Entry] = [:]
        while let relative = walker.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { return nil }
            let type = attributes[.type] as? FileAttributeType
            let size = type == .typeRegular ? (attributes[.size] as? NSNumber)?.uint64Value ?? 0 : 0
            let link = type == .typeSymbolicLink ? try? fm.destinationOfSymbolicLink(atPath: path) : nil
            out[relative] = Entry(type: type, size: size, link: link)
        }
        return out
    }

    static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    static func isEffectivelyEmpty(_ folder: URL, _ fm: FileManager) -> Bool {
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    static func asideName(in base: URL, now: Date, fileManager fm: FileManager) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "\(AppIdentity.supportFolderName) (set aside \(formatter.string(from: now)))"
        var name = stem
        var counter = 2
        while fm.fileExists(atPath: base.appendingPathComponent(name).path) {
            name = "\(stem) \(counter)"
            counter += 1
        }
        return name
    }

    static func writeMarker(_ marker: Marker, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: folder.appendingPathComponent(markerName), options: .atomic)
    }

    static func decodeMarker(_ data: Data) -> Marker? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    /// A note in the old folder saying where everything went. Best effort: the old folder is only a backup now.
    static func leaveNote(in legacy: URL, newFolder: URL, now: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let note = """
        \(AppIdentity.Legacy.name) is now called \(AppIdentity.name).

        On \(formatter.string(from: now)) \(AppIdentity.name) copied everything in this folder to
        \(newFolder.path)
        and works there from now on. This folder was left exactly as it was, as a backup.
        Once \(AppIdentity.name) has your chats and settings, you can delete it.

        """
        try? Data(note.utf8).write(to: legacy.appendingPathComponent(legacyNoteName), options: .atomic)
    }
}

extension DataFolderMigration {
    /// The marker of a settled folder (nil: not settled, or unreadable). Dates are ISO 8601.
    public static func settledMarker(of folder: URL) -> Marker? {
        (try? Data(contentsOf: folder.appendingPathComponent(markerName))).flatMap(decodeMarker)
    }
}

// MARK: - Settings

public enum LegacySettingsImport {
    /// In the new settings: the old settings were copied (or there were none).
    public static let importedKey = "vision.legacySettingsImported.v1"
    /// In the new settings: the paths in them follow the data folder's move.
    public static let pathsMovedKey = "vision.legacySettingsPathsMoved.v1"
    /// In the new settings: the "now called Vision" notice hasn't been seen yet.
    public static let noticePendingKey = "vision.renameNoticePending.v1"

    public enum Outcome: Equatable, Sendable {
        case alreadyDone
        case nothingToImport
        /// Settings copied, and settings the new file already had (kept as they were).
        case imported(copied: Int, kept: Int)
    }

    /// Copy every setting in `legacy` (the old settings file's contents) into `target`, once. `existing` is what the
    /// target's own file holds now (not the global or registered defaults): a setting it already has is kept. The
    /// old settings file itself is left as it is.
    public static func run(legacy: [String: Any]?, into target: UserDefaults, existing: [String: Any]?,
                           now: Date = .now) -> Outcome {
        let existing = existing ?? [:]
        if existing[importedKey] != nil { return .alreadyDone }
        guard let legacy, !legacy.isEmpty else {
            target.set(now, forKey: importedKey)
            return .nothingToImport
        }
        var copied = 0
        var kept = 0
        for key in legacy.keys.sorted() {
            if existing[key] != nil {
                kept += 1
                continue
            }
            target.set(legacy[key], forKey: key)
            copied += 1
        }
        target.set(true, forKey: noticePendingKey)
        // Last: a crash before this copies again next launch (and what was copied is kept, being the same).
        target.set(now, forKey: importedKey)
        return .imported(copied: copied, kept: kept)
    }

    /// Point the paths in the settings at the data folder's new place, once the folder is settled: `settled` is its
    /// marker. Until then the settings keep the old paths, which is where the app is still working.
    /// Returns how many settings changed.
    @discardableResult
    public static func movePaths(in target: UserDefaults, existing: [String: Any]?,
                                 settled: DataFolderMigration.Marker?, newFolder: URL, now: Date = .now) -> Int {
        let existing = existing ?? [:]
        guard existing[pathsMovedKey] == nil, let settled else { return 0 }
        var changed = 0
        if let from = settled.migratedFrom {
            let rewriter = DataFolderPathRewriter(from: URL(fileURLWithPath: from, isDirectory: true), to: newFolder)
            for key in existing.keys.sorted() {
                let value = existing[key]!
                let newKey = rewriter.rewriteEmbedded(key)
                let newValue = rewriter.rewrite(value: value)
                guard newKey != nil || newValue != nil else { continue }
                // A setting already under the new key is the newer one: the old one is left as it is.
                if let newKey, existing[newKey] != nil { continue }
                target.set(newValue ?? value, forKey: newKey ?? key)
                if newKey != nil { target.removeObject(forKey: key) }
                changed += 1
            }
        }
        target.set(now, forKey: pathsMovedKey)
        return changed
    }
}
