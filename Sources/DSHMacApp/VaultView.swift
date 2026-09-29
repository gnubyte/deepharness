import SwiftUI
import AppKit
import LocalAuthentication
import DSHCore

/// The credential vault: browse and search the API keys, tokens and
/// passwords the agent can use as `{{vault:NAME}}`; reveal a value (after
/// Touch ID / the login password), copy, edit, add and delete.
///
/// Values are shown as their SHA-256 fingerprint until revealed. Split into
/// small views: the Swift 6.0 type checker chokes on one large body.
@MainActor
struct VaultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: String?
    @State private var adding = false
    @State private var unlocked = false
    @State private var error: String?

    private var vault: CredentialVault { model.transport.vault }
    private var revision: Int { model.transport.vaultRevision }

    private var entries: [VaultEntry] {
        _ = revision
        return vault.search(query)
    }

    private var selected: VaultEntry? {
        _ = revision
        guard let selectedID else { return nil }
        return vault.all.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VaultHeader(count: vault.all.count, unlocked: unlocked, query: $query,
                        onAdd: { adding = true; selectedID = nil },
                        onLock: { unlocked = false })
            Divider()
            HStack(spacing: 0) {
                VaultList(entries: entries, selectedID: selectedID, query: query) { id in
                    adding = false
                    selectedID = id
                }
                .frame(width: 260)
                Divider()
                Group {
                    if adding {
                        VaultEditor(vault: vault, entry: nil, unlocked: $unlocked, error: $error,
                                    onSave: { entry, value in save(new: entry, value: value ?? "") },
                                    onCancel: { adding = false })
                    } else if let entry = selected {
                        VaultEditor(vault: vault, entry: entry, unlocked: $unlocked, error: $error,
                                    onSave: { edited, value in save(edited: edited, value: value) },
                                    onDelete: { delete(entry) })
                            .id(entry.id)
                    } else {
                        VaultEmptyDetail(isEmpty: vault.all.isEmpty) { adding = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Values are encrypted in your macOS Keychain. The agent writes {{vault:NAME}} and never sees them.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 560)
    }

    private func save(new entry: VaultEntry, value: String) {
        do {
            let added = try vault.add(name: entry.name, value: value, kind: entry.kind, description: entry.description,
                                      tags: entry.tags, username: entry.username, url: entry.url, access: entry.access)
            error = nil
            adding = false
            selectedID = added.id
            model.transport.vaultDidChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(edited entry: VaultEntry, value: String?) {
        do {
            try vault.update(entry, value: value)
            error = nil
            model.transport.vaultDidChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: VaultEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.name)?"
        alert.informativeText = "The value is removed from the Keychain. Anything that writes {{vault:\(entry.name)}} will stop working."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try vault.delete(id: entry.id)
            selectedID = nil
            error = nil
            model.transport.vaultDidChange()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Unlock

@MainActor
enum VaultUnlock {
    /// Touch ID or the login password before a value is shown or copied.
    /// A Mac with no way to authenticate the owner reveals directly.
    static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &failure) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - Header

@MainActor
private struct VaultHeader: View {
    let count: Int
    let unlocked: Bool
    @Binding var query: String
    let onAdd: () -> Void
    let onLock: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Credentials Vault", systemImage: "key.horizontal.fill").font(.headline)
            Text("\(count) credential\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Spacer()
            TextField("Search name, service, tag…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            if unlocked {
                Button(action: onLock) { Image(systemName: "lock.open") }
                    .help("Values are unlocked for this window — lock them again")
            }
            Button(action: onAdd) { Label("Add", systemImage: "plus") }
                .help("Add a credential")
        }
        .padding(12)
    }
}

// MARK: - List

@MainActor
private struct VaultList: View {
    let entries: [VaultEntry]
    let selectedID: String?
    let query: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    Text(query.isEmpty ? "No credentials yet." : "Nothing matches “\(query)”.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(10)
                }
                ForEach(entries) { entry in
                    Button { onSelect(entry.id) } label: { VaultRow(entry: entry, selected: entry.id == selectedID) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }
}

@MainActor
private struct VaultRow: View {
    let entry: VaultEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(Theme.mono(12)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if entry.access != .allowed {
                Image(systemName: entry.access == .never ? "hand.raised.fill" : "questionmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .help(entry.access.label)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private var subtitle: String {
        [entry.kind.label, entry.tags.isEmpty ? nil : entry.tags.joined(separator: ", "), entry.fingerprint]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var icon: String {
        switch entry.kind {
        case .apiKey: "key.fill"
        case .token: "ticket.fill"
        case .password: "lock.fill"
        case .other: "doc.text"
        }
    }
}

@MainActor
private struct VaultEmptyDetail: View {
    let isEmpty: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.horizontal").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(isEmpty ? "Keep API keys, tokens and passwords here." : "Select a credential.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("The agent finds them with vault_search and uses them as {{vault:NAME}} — in a shell command, a .env file, a request header — without ever seeing the value. Skills can refer to them the same way.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            if isEmpty { Button("Add a credential", action: onAdd).buttonStyle(.borderedProminent) }
        }
    }
}

// MARK: - Editor

@MainActor
private struct VaultEditor: View {
    let vault: CredentialVault
    let entry: VaultEntry?
    @Binding var unlocked: Bool
    @Binding var error: String?
    let onSave: (VaultEntry, String?) -> Void
    var onDelete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var name = ""
    @State private var kind: VaultEntry.Kind = .apiKey
    @State private var details = ""
    @State private var username = ""
    @State private var url = ""
    @State private var tags = ""
    @State private var access: VaultEntry.AgentAccess = .allowed
    /// The value field: empty = unchanged (when editing).
    @State private var newValue = ""
    @State private var revealed: String?
    @State private var showNewValue = false
    @State private var copied = false

    private var isNew: Bool { entry == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField("Name", text: $name, prompt: Text("OPENAI_API_KEY"))
                        .font(Theme.mono(12))
                    Picker("Kind", selection: $kind) {
                        ForEach(VaultEntry.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Description", text: $details, prompt: Text("What it's for"))
                    TextField("Username", text: $username, prompt: Text("optional"))
                    TextField("URL", text: $url, prompt: Text("https://… (optional)"))
                    TextField("Tags", text: $tags, prompt: Text("comma, separated"))
                    Picker("Agent access", selection: $access) {
                        ForEach(VaultEntry.AgentAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                valueSection
                if let entry { usage(entry) }
                buttons
            }
            .padding(16)
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var valueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Value").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let entry {
                HStack(spacing: 6) {
                    Text(revealed ?? entry.fingerprint)
                        .font(Theme.mono(12))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .foregroundStyle(revealed == nil ? .secondary : .primary)
                    Spacer()
                    Button { Task { await toggleReveal(entry) } } label: {
                        Image(systemName: revealed == nil ? "eye" : "eye.slash")
                    }
                    .help(revealed == nil ? "Show the value" : "Hide the value")
                    Button { Task { await copy(entry) } } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the value")
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 6) {
                Group {
                    if showNewValue {
                        TextField(isNew ? "Secret value" : "New value (leave empty to keep the current one)", text: $newValue)
                    } else {
                        SecureField(isNew ? "Secret value" : "New value (leave empty to keep the current one)", text: $newValue)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                Button { showNewValue.toggle() } label: { Image(systemName: showNewValue ? "eye.slash" : "eye") }
                    .help(showNewValue ? "Hide what you type" : "Show what you type")
            }
            if !newValue.isEmpty {
                Text("New fingerprint: \(CredentialVault.fingerprint(newValue))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func usage(_ entry: VaultEntry) -> some View {
        var parts = ["Placeholder \(entry.placeholder)", "used \(entry.useCount) time\(entry.useCount == 1 ? "" : "s")"]
        if let last = entry.lastUsedAt { parts.append("last \(QueueLog.when(last))") }
        parts.append("updated \(QueueLog.when(entry.updatedAt))")
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled)
    }

    private var buttons: some View {
        HStack {
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            }
            Spacer()
            if let onCancel { Button("Cancel", action: onCancel) }
            Button(isNew ? "Add Credential" : "Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (isNew && newValue.isEmpty))
        }
    }

    private func load() {
        guard let entry else { return }
        name = entry.name
        kind = entry.kind
        details = entry.description
        username = entry.username ?? ""
        url = entry.url ?? ""
        tags = entry.tags.joined(separator: ", ")
        access = entry.access
    }

    private func save() {
        var e = entry ?? VaultEntry(name: name, fingerprint: "")
        e.name = name
        e.kind = kind
        e.description = details.trimmingCharacters(in: .whitespacesAndNewlines)
        e.username = username
        e.url = url
        e.tags = tags.split(separator: ",").map(String.init)
        e.access = access
        onSave(e, newValue.isEmpty ? nil : newValue)
        newValue = ""
        revealed = nil
    }

    private func unlock() async -> Bool {
        if unlocked { return true }
        unlocked = await VaultUnlock.authenticate("show a credential from the DSH vault")
        return unlocked
    }

    private func value(_ entry: VaultEntry) -> String? {
        do {
            return try vaultValue(entry)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func vaultValue(_ entry: VaultEntry) throws -> String? {
        try vault.value(for: entry.id)
    }

    private func toggleReveal(_ entry: VaultEntry) async {
        if revealed != nil { revealed = nil; return }
        guard await unlock() else { return }
        revealed = value(entry)
    }

    private func copy(_ entry: VaultEntry) async {
        guard await unlock(), let v = value(entry) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }
}
