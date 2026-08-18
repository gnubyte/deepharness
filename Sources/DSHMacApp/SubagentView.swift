import SwiftUI
import DSHKit

/// Inspector for a session's direct subagent children.
///
/// Reads are transcript-only and never activate an Agent. Prompting is
/// available for continuable children; one-shot children can be read and
/// interrupted but not continued.
struct SubagentInspector: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var selected: SubagentEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Subagents").font(.headline)
                Spacer()
                Button {
                    Task { await model.loadSubagents(session, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(12)

            Divider()

            if session.subagents.isEmpty {
                ContentUnavailableView(
                    "No subagents",
                    systemImage: "person.2",
                    description: Text("This chat hasn’t spawned any.")
                )
            } else {
                List(session.subagents, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = session.subagents.first { $0.id == id } }
                )) { entry in
                    SubagentRow(entry: entry).tag(entry.id)
                }
                .listStyle(.inset)
            }

            if let selected {
                Divider()
                SubagentDetail(session: session, entry: selected)
                    .frame(minHeight: 240)
            }
        }
        .task { await model.loadSubagents(session) }
    }
}

private struct SubagentRow: View {
    let entry: SubagentEntry

    var body: some View {
        HStack(spacing: 8) {
            if entry.running {
                ProgressView().controlSize(.small).frame(width: 14)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var icon: String {
        if case .diagnostic = entry.kind { return "exclamationmark.triangle.fill" }
        return entry.isContinuable ? "bubble.left.and.bubble.right" : "bolt.horizontal"
    }

    private var tint: Color {
        if case .diagnostic = entry.kind { return .red }
        return .secondary
    }

    private var subtitle: String {
        switch entry.kind {
        case .child(let mode, _, let running, let hasChildren):
            var parts = [mode]
            if running { parts.append("running") }
            if hasChildren { parts.append("has children") }
            return parts.joined(separator: " · ")
        case .diagnostic(let reason):
            return "diagnostic: \(reason)"
        }
    }
}

private struct SubagentDetail: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let entry: SubagentEntry

    @State private var transcript = TranscriptAssembler()
    @State private var loading = true
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if loading {
                    ProgressView().padding()
                } else if transcript.items.isEmpty {
                    Text("No transcript.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript.items) { item in
                            MessageView(item: item, session: session)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            HStack(spacing: 8) {
                if entry.isContinuable {
                    TextField("Continue this subagent…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Text("One-shot subagents can’t be continued.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if entry.running {
                    Button("Interrupt") {
                        Task { await model.interruptSubagent(parent: session, child: entry) }
                    }
                }
            }
            .padding(10)
        }
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        loading = true
        transcript = await model.subagentTranscript(parent: session, child: entry)
        loading = false
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            await model.promptSubagent(parent: session, child: entry, text: text)
            await load()
        }
    }
}
