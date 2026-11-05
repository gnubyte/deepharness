import Foundation
import Observation

/// One open file. The buffer keeps the text the user is editing and the text
/// last seen on disk, which is what lets the editor tell "the agent changed
/// this underneath me" apart from "I have unsaved edits".
@MainActor
@Observable
public final class EditorBuffer: Identifiable {
    /// A guard against loading a 200 MB log into a text view.
    public nonisolated static let maxEditableBytes = 8 * 1024 * 1024

    public let url: URL
    public var text: String
    /// The contents as of the last load or save.
    public private(set) var savedText: String
    /// Set when the file changed on disk while the buffer had unsaved edits.
    public var diskConflict = false
    public let language: Language
    /// Bumped to force the text view to take `text` even when it thinks it is
    /// already current (used after a reload).
    public var reloadToken = 0

    public nonisolated var id: String { url.path }
    public nonisolated var name: String { url.lastPathComponent }
    public var isDirty: Bool { text != savedText }

    public init?(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= EditorBuffer.maxEditableBytes else { return nil }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.url = url
        self.text = contents
        self.savedText = contents
        self.language = Language.detect(for: url)
    }

    public func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        diskConflict = false
    }

    /// Take the on-disk contents, discarding unsaved edits.
    public func reloadFromDisk() {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = contents
        savedText = contents
        diskConflict = false
        reloadToken += 1
    }

    /// Called when the watcher reports this file changed.
    /// A clean buffer silently follows the file; a dirty one raises a conflict
    /// so unsaved work is never thrown away without asking.
    public func externalChangeDetected() {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard contents != text else {
            savedText = contents
            return
        }
        if isDirty {
            diskConflict = true
        } else {
            text = contents
            savedText = contents
            reloadToken += 1
        }
    }

    public func keepMine() {
        diskConflict = false
        // Re-baseline against disk so the buffer stays "dirty" against it.
        savedText = (try? String(contentsOf: url, encoding: .utf8)) ?? savedText
    }
}
