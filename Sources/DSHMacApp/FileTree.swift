import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One entry in the project tree. Children load on first expansion, so opening
/// a large repository costs one directory read rather than a full walk.
@MainActor
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    /// nil until the directory has been read.
    var children: [FileNode]?
    var isExpanded = false

    nonisolated var id: String { url.path }
    nonisolated var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Read this directory, keeping the expansion state of children that
    /// survive the refresh.
    func load(force: Bool = false) {
        guard isDirectory, force || children == nil else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        let previous = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url.path, $0) })
        var loaded: [FileNode] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !FileFilter.isIgnored(entry, isDirectory: isDirectory) else { continue }
            if let existing = previous[entry.path], existing.isDirectory == isDirectory {
                if existing.isExpanded { existing.load(force: force) }
                loaded.append(existing)
            } else {
                loaded.append(FileNode(url: entry, isDirectory: isDirectory))
            }
        }
        // Folders first, then case-insensitive by name — the Finder ordering.
        loaded.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        children = loaded
    }

    /// Re-read every directory that is currently open.
    func refreshExpanded() {
        guard isDirectory, isExpanded else { return }
        load(force: true)
        children?.forEach { $0.refreshExpanded() }
    }

    /// Open every directory down to `target` so it can be revealed.
    @discardableResult
    func expand(toward target: URL) -> Bool {
        guard isDirectory else { return url == target }
        guard target.path.hasPrefix(url.path + "/") || target == url else { return false }
        if target == url { return true }
        load()
        isExpanded = true
        for child in children ?? [] where child.expand(toward: target) {
            return true
        }
        return false
    }

    /// SF Symbol for this entry, chosen from its extension.
    var icon: String {
        guard !isDirectory else { return isExpanded ? "folder.fill" : "folder" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "mdx", "txt", "rst": return "doc.text"
        case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "heic", "webp", "icns": return "photo"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "dmg": return "shippingbox"
        case "html", "htm", "css", "scss": return "chevron.left.forwardslash.chevron.right"
        case "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h", "cpp", "java":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    var iconTint: Color {
        if isDirectory { return .accentColor }
        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "md", "markdown", "txt": return .secondary
        case "json", "yaml", "yml", "toml": return .yellow
        case "png", "jpg", "jpeg", "gif", "svg", "heic": return .purple
        case "sh", "bash", "zsh": return .green
        default: return .secondary
        }
    }
}

// MARK: - View

/// The project navigator: a VS Code-style tree with a filter field.
struct FileTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var code: CodeWorkspace { model.code }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let root = code.tree {
                if filter.isEmpty {
                    List(selection: Binding(
                        get: { code.selection },
                        set: { if let url = $0 { code.selectFromTree(url) } }
                    )) {
                        ForEach(root.children ?? []) { node in
                            FileRow(node: node, depth: 0)
                        }
                    }
                    .listStyle(.sidebar)
                    .environment(\.defaultMinListRowHeight, 22)
                } else {
                    FilterResults(root: root.url, query: filter)
                }
            } else {
                EmptyStateView(icon: "folder.badge.questionmark",
                               title: "No project open",
                               message: "Open a folder to browse and edit its files.") {
                    Button("Open Folder…") { model.chooseProject() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter files", text: $filter)
                .textFieldStyle(.plain)
                .font(.caption)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button {
                code.refreshTree()
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One row plus, for an open directory, its children.
private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let depth: Int

    var body: some View {
        Group {
            row
            if node.isDirectory, node.isExpanded {
                ForEach(node.children ?? []) { child in
                    FileRow(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundStyle(node.iconTint)
                .frame(width: 14)
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if model.code.isDirty(node.url) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .tag(node.url)
        .onTapGesture { activate() }
        .contextMenu { FileMenu(url: node.url, isDirectory: node.isDirectory) }
    }

    private func activate() {
        if node.isDirectory {
            node.load()
            withAnimation(.easeOut(duration: 0.12)) { node.isExpanded.toggle() }
            model.code.selection = node.url
        } else {
            model.code.openFile(node.url)
        }
    }
}

/// Flat results while the filter field has text.
private struct FilterResults: View {
    @Environment(AppModel.self) private var model
    let root: URL
    let query: String
    @State private var matches: [URL] = []

    var body: some View {
        List(matches, id: \.self, selection: Binding(
            get: { model.code.selection },
            set: { if let url = $0 { model.code.selectFromTree(url) } }
        )) { url in
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(relative(url))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .contentShape(Rectangle())
            .tag(url)
            .onTapGesture { model.code.openFile(url) }
            .contextMenu { FileMenu(url: url, isDirectory: false) }
        }
        .listStyle(.sidebar)
        .task(id: query) { await search() }
        .overlay {
            if matches.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func relative(_ url: URL) -> String {
        String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
    }

    /// Walk the tree off the main actor — a big repo would otherwise stutter
    /// the field on every keystroke.
    private func search() async {
        let needle = query.lowercased()
        let rootPath = root
        let found: [URL] = await Task.detached(priority: .userInitiated) {
            var out: [URL] = []
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: rootPath,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
            while let url = walker.nextObject() as? URL {
                if out.count >= 200 { break }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if FileFilter.isIgnored(url, isDirectory: true) { walker.skipDescendants() }
                    continue
                }
                if url.lastPathComponent.lowercased().contains(needle) { out.append(url) }
            }
            return out
        }.value
        matches = found
    }
}

/// Shared context menu for a tree entry.
struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let isDirectory: Bool

    var body: some View {
        if !isDirectory {
            Button("Open") { model.code.openFile(url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string) }
        Button("Copy Relative Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.code.relativePath(url), forType: .string)
        }
        Divider()
        Button("Mention in Chat") { model.code.mentionInChat(url) }
        if isDirectory {
            Button("Open Terminal Here") { model.code.newTerminal(cwd: url) }
        }
        Divider()
        Button("New File…") { model.code.promptNewFile(in: isDirectory ? url : url.deletingLastPathComponent()) }
        Button("New Folder…") { model.code.promptNewFolder(in: isDirectory ? url : url.deletingLastPathComponent()) }
        Button("Rename…") { model.code.promptRename(url) }
        Divider()
        Button("Move to Trash") { model.code.trash(url) }
    }
}
