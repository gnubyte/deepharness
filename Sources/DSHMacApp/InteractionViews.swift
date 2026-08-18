import SwiftUI
import DSHKit

/// The stack of things the agent is blocked on, pinned above the composer.
///
/// Approvals and questions are answerable server-requests: until one is
/// answered the turn cannot proceed, so they sit where the user is already
/// looking rather than in a modal that could be dismissed and lost.
struct BlockedBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        VStack(spacing: 8) {
            ForEach(session.approvals) { approval in
                ApprovalCard(approval: approval)
            }
            ForEach(session.questions) { pending in
                QuestionCard(pending: pending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

// MARK: - Approvals

struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Permission needed").bold()
                Spacer()
            }

            Text("Run **\(approval.toolName)**?")
                .fixedSize(horizontal: false, vertical: true)

            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Reject") {
                    Task { await model.answer(approval, allow: false) }
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Allow once") {
                    Task { await model.answer(approval, allow: true) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35))
        }
    }
}

// MARK: - Questions

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let pending: PendingQuestions

    /// Selections per question id. One `ask()` is answered as a whole batch,
    /// so every question's state lives here until the user submits.
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
                Text(pending.items.count == 1 ? "A question for you" : "\(pending.items.count) questions for you").bold()
                Spacer()
            }

            ForEach(pending.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = item.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.caption2).bold()
                            .foregroundStyle(.secondary)
                    }
                    Text(item.question)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(item.options) { option in
                        OptionRow(
                            option: option,
                            selected: selections[item.id]?.contains(option.label) == true,
                            multiSelect: item.multiSelect
                        ) {
                            toggle(item: item, label: option.label)
                        }
                    }

                    // "Other" is always available: a question may offer no
                    // options at all, and the contract allows custom text
                    // alongside selections.
                    TextField("Other…", text: Binding(
                        get: { custom[item.id] ?? "" },
                        set: { custom[item.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Submit") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.30))
        }
    }

    /// Every question needs either a selection or custom text before the batch
    /// can be answered — core takes one answer for the whole ask.
    private var canSubmit: Bool {
        pending.items.allSatisfy { item in
            !(selections[item.id]?.isEmpty ?? true)
                || !(custom[item.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func toggle(item: QuestionItem, label: String) {
        var current = selections[item.id] ?? []
        if item.multiSelect {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = current.contains(label) ? [] : [label]
        }
        selections[item.id] = current
    }

    private func submit() {
        let answers = pending.items.map { item in
            (
                id: item.id,
                selected: Array(selections[item.id] ?? []).sorted(),
                custom: custom[item.id]?.trimmingCharacters(in: .whitespaces)
            )
        }
        Task { await model.answer(pending, answers: answers) }
    }
}

private struct OptionRow: View {
    let option: QuestionOption
    let selected: Bool
    let multiSelect: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Queue dock

/// Pending inbox work that has not been claimed by the agent yet.
///
/// The host sends the complete snapshot on every change, so this renders
/// whatever the last frame said rather than tracking its own mutations.
struct QueueDock: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        let items = session.queuedItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").font(.caption)
                    Text("Queued (\(items.count))").font(.caption).bold()
                    Spacer()
                }
                .foregroundStyle(.secondary)

                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(item.text.isEmpty ? "(empty)" : item.text)
                            .lineLimit(2)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            draft = item.text
                            editing = item.id
                        } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help("Edit")

                        Button {
                            Task { await model.steerQueued(item) }
                        } label: { Image(systemName: "arrow.turn.up.right") }
                            .buttonStyle(.plain).help("Steer now — jump the queue")

                        Button {
                            Task { await model.removeQueued(item) }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Remove")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .alert("Edit queued message", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("Message", text: $draft)
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save") {
                    guard let id = editing,
                          let item = session.queuedItems.first(where: { $0.id == id }) else { return }
                    let text = draft
                    editing = nil
                    Task { await model.editQueued(item, text: text) }
                }
            }
        }
    }
}

/// Steering messages render at the conversation tail, not in the dock.
struct SteeringTail: View {
    let session: SessionVM

    var body: some View {
        ForEach(session.steeringItems) { item in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.right").font(.caption2)
                    Text("Steering").font(.caption).bold()
                }
                .foregroundStyle(.orange)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
