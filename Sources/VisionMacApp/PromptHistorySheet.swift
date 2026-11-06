import SwiftUI
import VisionHarnessCore

/// The durable prompt history — every prompt the harness has taken, in every
/// mode: chat, code, agent and automation. Each row carries when it was sent,
/// how long its turn took, how it ended, and what it produced (attachments in,
/// files changed out). Searchable; a row opens the chat it ran in.
struct PromptHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var modeFilter: PromptHistoryRecord.Mode?
    @State private var expanded: String?
    /// Re-reads on change (records land as turns finish).
    @State private var revision = 0

    private var records: [PromptHistoryRecord] {
        _ = revision
        return model.transport.promptHistory.search(query: query, mode: modeFilter, limit: 400)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if records.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No prompts yet" : "No prompts match")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Every prompt sent in chat, code, agent and automations lands here, with how long it took and what it produced.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 60)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(records) { record in
                        row(record)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(model.transport.promptHistory.count) prompt\(model.transport.promptHistory.count == 1 ? "" : "s") on record")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 720, height: 640)
        .task {
            // Records land as turns finish; re-read gently while open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                revision += 1
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Prompt History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search prompts and chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            Picker("", selection: Binding(
                get: { modeFilter },
                set: { modeFilter = $0 })) {
                Text("All modes").tag(PromptHistoryRecord.Mode?.none)
                ForEach([PromptHistoryRecord.Mode.chat, .code, .agent, .automation], id: \.self) { m in
                    Text(m.label).tag(PromptHistoryRecord.Mode?.some(m))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 330)
        }
        .padding(10)
    }

    @ViewBuilder
    private func row(_ record: PromptHistoryRecord) -> some View {
        let isOpen = expanded == record.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded = isOpen ? nil : record.id }
            } label: {
                HStack(spacing: 8) {
                    modeChip(record.mode)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.text)
                            .font(.system(size: 12))
                            .lineLimit(isOpen ? nil : 2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            Text(record.chatTitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(record.at, style: .time).font(Theme.mono(9.5)).foregroundStyle(.tertiary)
                            if let duration = record.duration {
                                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(duration.formattedDuration).font(Theme.mono(9.5)).foregroundStyle(.tertiary)
                            }                        }
                    }
                    Spacer(minLength: 4)
                    outcomeChip(record.outcome)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.text)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    if !record.attachments.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(record.attachments.joined(separator: ", "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if !record.changedFiles.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "doc.badge.gearshape").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(record.changedFiles.joined(separator: ", "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.text, forType: .string)
                        }
                        if model.transport.sessions.contains(where: { $0.id == record.chatID }) {
                            Button("Open its chat") { model.openSession(record.chatID) }
                        }
                        Button("Reuse in composer") {
                            model.pendingComposerText = record.text
                            dismiss()
                        }
                        Spacer()
                    }
                    .font(Theme.metaFont)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .background(isOpen ? Theme.surface.opacity(0.5) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func modeChip(_ mode: PromptHistoryRecord.Mode) -> some View {
        let (icon, tint): (String, Color) = switch mode {
        case .chat: ("bubble.left", .secondary)
        case .code: ("chevron.left.forwardslash.chevron.right", .orange)
        case .agent: ("brain.head.profile", .accentColor)
        case .automation: ("clock.badge.checkmark", Theme.successTint)
        }
        return Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .frame(width: 16)
            .help(mode.label)
    }

    @ViewBuilder
    private func outcomeChip(_ outcome: PromptHistoryRecord.Outcome) -> some View {
        switch outcome {
        case .working:
            Label("working", systemImage: "hourglass")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        case .completed(let evidence):
            Label(evidence > 0 ? "done · \(evidence)" : "done", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5)).foregroundStyle(Theme.successTint)
        case .blocked:
            Label("needs you", systemImage: "pause.circle")
                .font(.system(size: 9.5)).foregroundStyle(Theme.noticeTint)
        case .failed:
            Label("failed", systemImage: "xmark.circle")
                .font(.system(size: 9.5)).foregroundStyle(Theme.errorTint)
        case .stopped:
            Label("stopped", systemImage: "stop.circle")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}
