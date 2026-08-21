import SwiftUI
import AppKit
import DSHCore

/// The conversation: transcript, permission prompts, and the composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    @State private var draft = ""
    /// Grows with the draft, between one line and a sensible ceiling.
    @State private var composerHeight: CGFloat = 32

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            gates
            composer
        }
        .background(.background)
        .onChange(of: model.code.pendingMention) { _, mention in
            guard let mention else { return }
            insertMention(mention)
            model.code.pendingMention = nil
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    if session.entries.isEmpty {
                        ChatStarterView(session: session) { text in
                            model.send(text, in: session)
                        }
                        .padding(.top, 40)
                    }
                    ForEach(session.entries) { entry in
                        EntryRow(entry: entry, session: session)
                            .id(entry.id)
                    }
                    if session.running, session.entries.last?.tool?.isFinished ?? true {
                        ThinkingRow(session: session)
                    }
                    if !session.changedFiles.isEmpty {
                        ProducedFilesRow(session: session)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.maxTranscriptWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.entries.count) { _, _ in scroll(proxy) }
            .onChange(of: lastEntryLength) { _, _ in scroll(proxy) }
            .onChange(of: session.id) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                // The first pass runs before the transcript has laid out, so
                // repeat once the run loop has caught up.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let bottomAnchor = "transcript-bottom"

    /// Streaming text changes the last entry without changing the count.
    private var lastEntryLength: Int {
        session.entries.last?.message?.text.count ?? 0
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Gates

    @ViewBuilder
    private var gates: some View {
        if let gate = session.pendingGates.last {
            GateCard(gate: gate, session: session)
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 10)
                .frame(maxWidth: Theme.maxTranscriptWidth)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let tool = session.runningTool {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(Theme.toolLabel(tool.name).lowercased()) \(tool.preview)")
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(text: $draft, height: $composerHeight,
                              isEnabled: !session.running, onSubmit: send)
                    .frame(height: composerHeight)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )

                if session.running {
                    Button {
                        transport.stopSession(session.id)
                    } label: {
                        Image(systemName: session.stopping ? "hourglass" : "stop.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(session.stopping)
                    .help(session.stopping ? "Stopping…" : "Stop the agent (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (↩)")
                }
            }

            HStack(spacing: 10) {
                Label(session.preset.label, systemImage: session.preset.icon)
                    .foregroundStyle(session.preset == .fullAccess ? Theme.errorTint : .secondary)
                if let name = session.projectName {
                    Label(name, systemImage: "folder")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let usage = session.lastUsage {
                    Text("\(usage.promptTokens.formatted()) in · \(usage.completionTokens.formatted()) out")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(Theme.metaFont)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: Theme.maxTranscriptWidth)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.running else { return }
        draft = ""
        model.send(text, in: session)
    }

    private func insertMention(_ path: String) {
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(path) "
    }
}

// MARK: - Composer field

/// Multi-line field where Return sends and Shift-Return inserts a newline.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var onSubmit: () -> Void

    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text { textView.string = text }
        textView.isEditable = isEnabled
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        context.coordinator.reportHeight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: NSTextView?

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(textView)
        }

        /// An NSViewRepresentable has no intrinsic size in SwiftUI, so without
        /// this the field expands to swallow the whole pane.
        func reportHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let target = min(max(ComposerField.minHeight,
                                 (used + textView.textContainerInset.height * 2).rounded(.up)),
                             ComposerField.maxHeight)
            guard abs(target - parent.height) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = target }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Shift-Return (and Option-Return) insert a line break instead.
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}

// MARK: - Rows

/// One transcript row, dispatched on its kind.
private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: ChatEntry
    let session: SessionVM

    var body: some View {
        switch entry.kind {
        case .message(let body):
            MessageRow(body: body, at: entry.at)
        case .tool(let activity):
            ToolCard(activity: activity, session: session)
        case .todos(let items):
            TodoCard(items: items)
        }
    }
}

private struct MessageRow: View {
    let body_: MessageBody
    let at: Date

    init(body: MessageBody, at: Date) {
        self.body_ = body
        self.at = at
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 4) {
                if body_.role == .user {
                    Text(body_.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownView(source: body_.text)
                }
            }
            .padding(.vertical, body_.role == .user ? 8 : 0)
            .padding(.horizontal, body_.role == .user ? 12 : 0)
            .background(background)
            .foregroundStyle(foreground)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch body_.role {
        case .user:
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(Theme.userTint)
                .frame(width: 18)
                .padding(.top, 8)
        case .assistant:
            Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
        case .notice:
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.noticeTint)
                .frame(width: 18)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorTint)
                .frame(width: 18)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch body_.role {
        case .user:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface)
        case .notice:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.noticeTint.opacity(0.10))
        case .error:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.errorTint.opacity(0.10))
        case .assistant:
            Color.clear
        }
    }

    private var foreground: Color {
        switch body_.role {
        case .notice: .primary
        case .error: Theme.errorTint
        default: .primary
        }
    }
}

/// A tool call: one compact line, expandable to the full result.
private struct ToolCard: View {
    @Environment(AppModel.self) private var model
    let activity: ToolActivity
    let session: SessionVM
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard activity.output?.isEmpty == false else { return }
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if expanded, let output = activity.output, !output.isEmpty {
                Divider().padding(.vertical, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output)
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(.bottom, 2)
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(activity.isOk == false ? Theme.errorTint.opacity(0.4) : Theme.hairline, lineWidth: 1)
        )
        .padding(.leading, Theme.gutter)
        .contextMenu {
            if let output = activity.output {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
            }
            if isFilePath, let url = resolvedURL {
                Button("Open in Editor") {
                    model.mode = .code
                    model.code.reveal(url)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: Theme.toolIcon(activity.name))
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(Theme.toolLabel(activity.name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(activity.preview)
                .font(Theme.mono(11))
                .lineLimit(1)
                // Head-truncate: the tail of a path or command is the part
                // that identifies it.
                .truncationMode(.head)
            Spacer(minLength: 4)
            if activity.isFinished {
                if let summary = activity.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                if activity.output?.isEmpty == false {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .contentShape(Rectangle())
    }

    private var tint: Color {
        guard let ok = activity.isOk else { return .secondary }
        return ok ? Theme.successTint : Theme.errorTint
    }

    private var isFilePath: Bool {
        ["read_file", "write_file", "edit"].contains(activity.name)
    }

    private var resolvedURL: URL? {
        guard isFilePath, !activity.preview.isEmpty else { return nil }
        if activity.preview.hasPrefix("/") { return URL(fileURLWithPath: activity.preview) }
        guard let root = session.workspaceURL else { return nil }
        return root.appendingPathComponent(activity.preview)
    }
}

/// The agent's task list.
private struct TodoCard: View {
    let items: [TodoItem]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 11))
                    Text("Plan")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(items.filter { $0.status == .completed }.count)/\(items.count)")
                        .font(Theme.metaFont)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)

                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.status.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(item.status.tint)
                        Text(item.content)
                            .font(.callout)
                            .strikethrough(item.status == .completed, color: .secondary)
                            .foregroundStyle(item.status == .completed ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.leading, Theme.gutter)
    }
}

/// Files this session's tools touched.
private struct ProducedFilesRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files changed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(session.changedFiles, id: \.url) { change in
                    Button {
                        model.mode = .code
                        model.code.reveal(change.url)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(change.kind.tint).frame(width: 6, height: 6)
                            Text(name(change.url))
                                .font(Theme.mono(11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(change.url.path) — \(change.kind.label)")
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([change.url])
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(change.url.path, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.leading, Theme.gutter)
    }

    private func name(_ url: URL) -> String {
        guard let root = session.workspaceURL, url.path.hasPrefix(root.path) else {
            return url.lastPathComponent
        }
        return String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
    }
}

/// Shown between "you sent" and "the first token arrived".
private struct ThinkingRow: View {
    let session: SessionVM
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .opacity(0.4 + 0.6 * abs(sin(phase)))
            Text(session.stopping ? "Stopping…" : "Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                phase += 0.2
            }
        }
    }
}

/// The permission question, answered inline above the composer.
private struct GateCard: View {
    @Environment(AppModel.self) private var model
    let gate: GateVM
    let session: SessionVM

    var body: some View {
        Card(fill: Theme.noticeTint.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 8) {
                Label("The agent needs permission", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.noticeTint)
                Text(gate.detail)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Theme.toolLabel(gate.name))
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Deny") {
                        model.transport.answerGate(sessionID: session.id, gateID: gate.id, allow: false)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button("Allow Once") {
                        model.transport.answerGate(sessionID: session.id, gateID: gate.id, allow: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }
}

/// First-run content for an empty chat: what this is, and a few openers.
private struct ChatStarterView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let send: (String) -> Void

    private var suggestions: [(String, String)] {
        if session.cwd == nil {
            return [
                ("folder.badge.plus", "Open a project folder so I can read and edit its files"),
                ("questionmark.circle", "What can you do?"),
            ]
        }
        return [
            ("map", "Give me a tour of this codebase — the entry points and how it fits together"),
            ("ant", "Find and fix any bugs you can verify with the tests"),
            ("doc.text", "Write a README section describing how to build and run this"),
            ("checklist", "What would you improve first in this project, and why?"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName ?? "No project open")
                        .font(.title3.weight(.semibold))
                    Text(model.config.activeProvider.map { "Running on \($0.displayName)" }
                         ?? "No model configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ForEach(suggestions, id: \.1) { icon, text in
                Button {
                    if session.cwd == nil, icon == "folder.badge.plus" {
                        model.chooseProject()
                    } else {
                        send(text)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(text)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
