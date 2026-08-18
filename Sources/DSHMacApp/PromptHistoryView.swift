import SwiftUI
import DSHKit

/// Browser over the local prompt database.
///
/// Scoped to the current chat by default, because "what have I asked in here"
/// is the common question; the scope switch widens it to everything ever typed.
struct PromptHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case thisChat = "This chat"
        case everything = "All chats"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .thisChat
    @State private var query = ""
    @State private var records: [PromptRecord] = []
    @State private var total = 0
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: reloadKey) { await reload() }
    }

    private var reloadKey: String {
        "\(scope.rawValue)|\(query)|\(model.selectedID ?? "")"
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Prompt History").font(.headline)
                Spacer()
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.selectedID == nil && scope == .thisChat)
            }
            TextField("Search your prompts…", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView(
                "History unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(failure)
            )
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if records.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "Nothing recorded yet" : "No matches",
                systemImage: "clock.arrow.circlepath",
                description: Text(query.isEmpty
                    ? "Prompts you send are recorded here automatically."
                    : "No prompt contains “\(query)”.")
            )
        } else {
            List(records) { record in
                PromptRow(record: record, showsChat: scope == .everything)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.text, forType: .string)
                        }
                        Button("Use Again") { reuse(record) }
                        if scope == .everything, record.sessionId != model.selectedID {
                            Button("Go to Chat") {
                                model.selectedID = record.sessionId
                                dismiss()
                            }
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(total) prompt\(total == 1 ? "" : "s") recorded")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let store = model.promptStore {
                Button("Show Database in Finder") {
                    Task { model.revealLocally(await store.url.path) }
                }
                .font(.caption)
            }
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private func reload() async {
        guard let store = model.promptStore else {
            failure = model.promptStoreError ?? "The prompt database isn’t available."
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            var rows: [PromptRecord]
            switch (scope, trimmed.isEmpty) {
            case (.thisChat, _):
                guard let id = model.selectedID else { records = []; total = try await store.count(); return }
                rows = try await store.prompts(sessionId: id)
                if !trimmed.isEmpty {
                    rows = rows.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
                }
            case (.everything, true):
                rows = try await store.recent()
            case (.everything, false):
                rows = try await store.search(trimmed)
            }
            records = rows
            total = try await store.count()
            failure = nil
        } catch {
            failure = AppModel.describe(error)
        }
    }

    /// Drop a past prompt back into the composer of the current chat.
    private func reuse(_ record: PromptRecord) {
        NotificationCenter.default.post(name: .reusePrompt, object: record.text)
        dismiss()
    }
}

private struct PromptRow: View {
    let record: PromptRecord
    let showsChat: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if record.isSteer {
                    Label("steered", systemImage: "arrow.turn.up.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                if record.attachmentCount > 0 {
                    Label("\(record.attachmentCount)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showsChat, let title = record.sessionTitle, !title.isEmpty {
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(record.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if showsChat, let cwd = record.cwd {
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

extension Notification.Name {
    /// Carries a past prompt's text back to the composer.
    static let reusePrompt = Notification.Name("dsh.reusePrompt")
    /// Menu request to open the history browser.
    static let showPromptHistory = Notification.Name("dsh.showPromptHistory")
    /// Menu request to open the harness recovery sheet.
    static let showHarnessRecovery = Notification.Name("dsh.showHarnessRecovery")
}
