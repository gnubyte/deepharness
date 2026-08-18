import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DSHKit

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var showSubagents = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            FullAccessBanner(session: session)
            TranscriptScroll(session: session)
            if session.isBlocked {
                Divider()
                ScrollView { BlockedBar(session: session) }
                    .frame(maxHeight: 340)
            }
            if !session.queuedItems.isEmpty {
                Divider()
                QueueDock(session: session)
            }
            Divider()
            ComposerView(session: session)
        }
        .navigationTitle(session.displayTitle)
        .navigationSubtitle(routeLabel)
        .sheet(isPresented: $showHistory) {
            PromptHistoryView().environment(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPromptHistory)) { _ in
            showHistory = true
        }
        .inspector(isPresented: $showSubagents) {
            SubagentInspector(session: session)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar {
            // The working directory is the single most consequential thing
            // about a coding session, so it is always on screen.
            ToolbarItem(placement: .navigation) {
                if let cwd = session.cwd {
                    Menu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cwd, forType: .string)
                        }
                        Divider()
                        Button("Open Another Project…") { ProjectPicker.open(into: model) }
                    } label: {
                        ProjectBadge(path: cwd, projectTitle: model.activeProject?.title)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            ToolbarItem(placement: .principal) { ModelPicker() }
            ToolbarItem { ContextMeter(session: session) }
            ToolbarItem { PermissionControl(session: session) }
            ToolbarItem {
                Button { model.showMemorySkills = true } label: {
                    Label("Memory & Skills", systemImage: "brain")
                }
                .help("Memory & skills (⇧⌘M)")
            }
            ToolbarItem {
                Button { showHistory = true } label: {
                    Label("Prompt History", systemImage: "clock.arrow.circlepath")
                }
                .help("Prompt history (⌘Y)")
            }
            ToolbarItem {
                if session.running {
                    let stopping = model.stopping.contains(session.id)
                    Button {
                        Task { await model.stop(session) }
                    } label: {
                        Label(stopping ? "Stopping…" : "Stop", systemImage: "stop.circle.fill")
                            .foregroundStyle(stopping ? Color.secondary : .red)
                    }
                    .disabled(stopping)
                    .help(stopping ? "Waiting for the turn to settle" : "Stop this agent (⌘.)")
                }
            }
            ToolbarItem {
                Button {
                    showSubagents.toggle()
                } label: {
                    Label("Subagents", systemImage: "person.2")
                }
                .help("Show subagents")
            }
        }
    }

    private var routeLabel: String {
        guard let provider = session.provider, let m = session.model else { return "" }
        let usage = session.transcript.usage
        let tokens = usage.outputTokens > 0 ? " · \(usage.inputTokens)↓ \(usage.outputTokens)↑" : ""
        return "\(provider)/\(m)\(tokens)"
    }
}

// MARK: - Transcript

struct TranscriptScroll: View {
    let session: SessionVM

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.transcript.items) { item in
                        MessageView(item: item, session: session).id(item.id)
                    }
                    SteeringTail(session: session)
                    // Anchor for auto-scroll; keeps the newest content in view
                    // while deltas land.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if session.transcript.items.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "text.bubble",
                        description: Text("Send a message to start this chat.")
                    )
                }
            }
            .onChange(of: session.transcript.items.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.transcript.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let session: SessionVM
    @State private var images: [NSImage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2).foregroundStyle(tint)
                Text(label).font(.caption).bold().foregroundStyle(tint)
                if item.streaming {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }

            if !item.text.isEmpty {
                MarkdownView(source: item.text, monospaced: isCode)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background, in: RoundedRectangle(cornerRadius: 8))
            }

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            // Files this turn produced, shown once on the turn's closing item.
            if closesTurn {
                ProducedFiles(session: session, paths: session.transcript.producedFiles(turn: item.turn))
            }
        }
        .task(id: item.id) { await loadAttachments() }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Button("Fork from here") {
                Task { await model.fork(session, atSeq: item.seq) }
            }
            .help("Start a new chat branching at this point")
        }
    }

    /// Fetch durable images this message references, lazily.
    private func loadAttachments() async {
        guard images.isEmpty, !item.attachmentIds.isEmpty else { return }
        var loaded: [NSImage] = []
        for id in item.attachmentIds {
            guard let value = try? await model.api.attachment(session.id, attachmentId: id),
                  let b64 = value["data"]?.stringValue,
                  let data = Data(base64Encoded: b64),
                  let image = NSImage(data: data) else { continue }
            loaded.append(image)
        }
        images = loaded
    }

    private var isCode: Bool {
        if case .toolCall = item.kind { return true }
        if case .toolResult = item.kind { return true }
        return false
    }

    /// Whether this is the last item of its turn, which is where the produced
    /// files row belongs — attaching it to every item would repeat it.
    private var closesTurn: Bool {
        guard !session.transcript.producedFiles(turn: item.turn).isEmpty else { return false }
        return session.transcript.items.last { $0.turn == item.turn }?.id == item.id
    }

    private var label: String {
        switch item.kind {
        case .user: "You"
        case .assistant: "Assistant"
        case .reasoning: "Reasoning"
        case .toolCall(let name): name
        case .toolResult(let name): "\(name) result"
        case .notice: "Notice"
        }
    }

    private var icon: String {
        switch item.kind {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .reasoning: "brain"
        case .toolCall: "wrench.and.screwdriver.fill"
        case .toolResult: "arrow.turn.down.right"
        case .notice: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .user: .accentColor
        case .assistant: .primary
        case .reasoning: .purple
        case .toolCall, .toolResult: .orange
        case .notice: .red
        }
    }

    private var background: Color {
        switch item.kind {
        case .user: Color.accentColor.opacity(0.10)
        case .notice: Color.red.opacity(0.10)
        case .reasoning: Color.purple.opacity(0.07)
        case .toolCall, .toolResult: Color.secondary.opacity(0.10)
        case .assistant: Color.secondary.opacity(0.07)
        }
    }
}

// MARK: - Model picker

struct ModelPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(grouped, id: \.0) { providerName, entries in
                Section(providerName) {
                    ForEach(entries) { m in
                        Button {
                            Task { await model.selectModel(m) }
                        } label: {
                            if isCurrent(m) { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                        }
                    }
                }
            }
            if model.models.isEmpty {
                Text("No models — add a provider in Settings")
            }
        } label: {
            Label(currentLabel, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.selected == nil)
    }

    private var grouped: [(String, [ModelVM])] {
        Dictionary(grouping: model.models, by: \.providerName)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }

    private func isCurrent(_ m: ModelVM) -> Bool {
        guard let s = model.selected else { return false }
        return s.provider == m.provider && s.model == m.modelId
    }

    private var currentLabel: String {
        model.selected?.model ?? "Model"
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            AttachmentChip(attachment: a) {
                                attachments.removeAll { $0.id == a.id }
                            }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "paperclip")
                }
                .help("Attach an image (PNG, JPEG, WebP, GIF)")

                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(session.running ? "Queue a message… (⌘⏎ to steer)" : "Send a message…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2)
                    }
                    .focused($focused)
                    // A TextEditor consumes Return as a newline, so send has to
                    // be claimed explicitly. Shift+Return stays a newline, and
                    // Command+Return steers past the queue.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send(steer: press.modifiers.contains(.command))
                        return .handled
                    }

                if session.running {
                    Button { send(steer: true) } label: {
                        Image(systemName: "arrow.turn.up.right").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Steer now, interrupting the running turn (⌘⏎)")
                }

                Button { send(steer: false) } label: {
                    Image(systemName: session.running ? "tray.and.arrow.down.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(session.running
                      ? "Queue behind the running turn (⏎)"
                      : "Send (⏎) · Shift⏎ for a new line")
            }
        }
        .padding(12)
        .background(.bar)
        .onDrop(of: Attachment.supportedContentTypes, isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear { focused = true }
        // "Use Again" from the history browser drops the old prompt here
        // rather than re-sending it, so it can be edited first.
        .onReceive(NotificationCenter.default.publisher(for: .reusePrompt)) { note in
            guard let text = note.object as? String else { return }
            self.text = text
            focused = true
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Grow with the draft instead of reserving a tall block up front.
    private var editorHeight: CGFloat {
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return min(max(CGFloat(lines) * 18 + 16, 34), 150)
    }

    /// Queue by default; steering is the deliberate interrupt.
    private func send(steer: Bool) {
        guard canSend else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        text = ""
        attachments = []
        Task { await model.send(body, attachments: files, steer: steer) }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Attachment.supportedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in addFile(url) }
            }
        }
        return true
    }

    private func addFile(_ url: URL) {
        do {
            attachments.append(try Attachment.load(from: url))
        } catch {
            model.note(AppModel.describe(error))
        }
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo").frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name).font(.caption).lineLimit(1)
                Text(attachment.displaySize).font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
