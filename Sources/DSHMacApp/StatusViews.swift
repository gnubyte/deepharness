import SwiftUI
import DSHKit

// MARK: - Context usage

/// A compact context-window gauge with a detail popover.
struct ContextMeter: View {
    let session: SessionVM
    @State private var showing = false

    var body: some View {
        if let pressure = session.contextPressure {
            Button { showing.toggle() } label: {
                HStack(spacing: 5) {
                    ContextGauge(pressure: pressure)
                    Text("\(Int(pressure.usedFraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint(pressure.level))
                }
            }
            .buttonStyle(.plain)
            .help("Context: \(formatTokens(pressure.pressureTokens)) of \(formatTokens(pressure.contextWindow)) tokens")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ContextDetail(session: session, pressure: pressure)
                    .frame(width: 300)
                    .padding(14)
            }
        }
    }

    private func tint(_ level: ContextPressure.Level) -> Color {
        switch level {
        case .comfortable: .secondary
        case .tight: .orange
        case .critical: .red
        }
    }
}

/// Ring showing committed usage, with projected usage as a faint outer arc.
struct ContextGauge: View {
    let pressure: ContextPressure

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            // Projected sits behind committed: mid-turn it runs ahead, and the
            // gap is the point — it is what will be added.
            Circle()
                .trim(from: 0, to: pressure.projectedFraction)
                .stroke(color.opacity(0.35), style: .init(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: pressure.usedFraction)
                .stroke(color, style: .init(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.easeOut(duration: 0.25), value: pressure.usedFraction)
    }

    private var color: Color {
        switch pressure.level {
        case .comfortable: .accentColor
        case .tight: .orange
        case .critical: .red
        }
    }
}

struct ContextDetail: View {
    let session: SessionVM
    let pressure: ContextPressure

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Context window").font(.headline)
                Spacer()
                Text("\(formatTokens(pressure.pressureTokens)) / \(formatTokens(pressure.contextWindow))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let breakdown = session.contextBreakdown, breakdown.total > 0 {
                StackedBar(breakdown: breakdown, window: pressure.contextWindow)
                VStack(spacing: 4) {
                    LegendRow(color: .blue, label: "System", tokens: breakdown.systemTokens)
                    LegendRow(color: .purple, label: "Tools", tokens: breakdown.toolsTokens)
                    LegendRow(color: .accentColor, label: "Messages", tokens: breakdown.messageTokens)
                }
            }

            Divider()

            StatRow(label: "Remaining", value: formatTokens(pressure.remainingTokens))
            if pressure.projectedTokens > pressure.pressureTokens {
                StatRow(label: "Projected this turn", value: formatTokens(pressure.projectedTokens))
            }

            if let usage = session.tokenUsage {
                Divider()
                Text("Session totals").font(.caption).bold().foregroundStyle(.secondary)
                StatRow(label: "Input (uncached)", value: formatTokens(usage.uncachedInputTokens))
                if usage.cacheReadTokens > 0 {
                    StatRow(label: "Cache reads", value: formatTokens(usage.cacheReadTokens))
                }
                if usage.cacheWriteTokens > 0 {
                    StatRow(label: "Cache writes", value: formatTokens(usage.cacheWriteTokens))
                }
                StatRow(label: "Output", value: formatTokens(usage.outputTokens))
            }

            if let stats = session.sessionStats, stats.turns > 0 {
                Divider()
                StatRow(label: "Turns", value: "\(stats.turns)")
                StatRow(label: "Steps", value: "\(stats.steps)")
                if let tps = stats.tokensPerSecond {
                    StatRow(label: "Decode speed", value: String(format: "%.1f tok/s", tps))
                }
                if stats.ttftMs > 0 {
                    StatRow(label: "Time to first token", value: String(format: "%.1fs", Double(stats.ttftMs) / 1000))
                }
            }

            if pressure.level != .comfortable {
                Divider()
                Label(
                    pressure.level == .critical
                        ? "Nearly full — the harness will compact older messages soon."
                        : "Filling up — compaction may start on longer turns.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(pressure.level == .critical ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StackedBar: View {
    let breakdown: ContextBreakdown
    let window: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                segment(breakdown.systemTokens, .blue, geo.size.width)
                segment(breakdown.toolsTokens, .purple, geo.size.width)
                segment(breakdown.messageTokens, .accentColor, geo.size.width)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 7)
        .background(Color.secondary.opacity(0.18), in: Capsule())
        .clipShape(Capsule())
    }

    private func segment(_ tokens: Int, _ color: Color, _ total: CGFloat) -> some View {
        color.frame(width: max(0, total * CGFloat(tokens) / CGFloat(max(window, 1))))
    }
}

private struct LegendRow: View {
    let color: Color
    let label: String
    let tokens: Int

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Spacer()
            Text(formatTokens(tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Permissions

/// Permission preset control for the live session.
///
/// Full access removes the sandbox and stops asking before each tool call, so
/// it is gated behind an explicit acknowledgement and stays visible while on.
struct PermissionControl: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var confirmingFullAccess = false

    var body: some View {
        if let permissions = session.permissions {
            Menu {
                Section("This chat") {
                    // A session pins its preset at creation and this deployment
                    // dispatches no slash commands, so the live value is shown
                    // but cannot be changed here.
                    Label(permissions.displayName, systemImage: "checkmark")
                }
                Section("New chats start with") {
                    ForEach(permissions.options) { option in
                        Button {
                            choose(option.value)
                        } label: {
                            if option.value == model.defaultPreset {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: icon(permissions)).font(.caption)
                    if permissions.isFullAccess {
                        Text("Full Access").font(.caption).bold()
                    }
                }
                .foregroundStyle(permissions.isFullAccess ? Color.red : .secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(helpText(permissions))
            .confirmationDialog(
                "Give the agent full access to this machine?",
                isPresented: $confirmingFullAccess,
                titleVisibility: .visible
            ) {
                Button("Grant and Start a New Chat", role: .destructive) {
                    Task { await model.setDefaultPreset(PermissionState.fullAccess, startChat: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                The agent will run shell commands and executables, and read and write files \
                anywhere your user account can reach — outside the project folder included — \
                without asking first.

                A chat locks in its permissions when it is created, so this applies to new \
                chats, not this one. A new chat opens in the same project folder.
                """)
            }
        }
    }

    private func choose(_ value: String) {
        guard value != model.defaultPreset else { return }
        if value == PermissionState.fullAccess {
            confirmingFullAccess = true
        } else {
            Task { await model.setDefaultPreset(value, startChat: false) }
        }
    }

    private func icon(_ p: PermissionState) -> String {
        switch p.currentValue {
        case "read-only": "lock.fill"
        case PermissionState.fullAccess: "exclamationmark.shield.fill"
        default: "shield.lefthalf.filled"
        }
    }

    private func helpText(_ p: PermissionState) -> String {
        switch p.currentValue {
        case "read-only":
            "Read-only: the agent can look but not change anything."
        case PermissionState.fullAccess:
            "Full access: the agent runs commands anywhere without asking. Click to change."
        default:
            "Workspace write: changes inside the project folder are allowed; anything outside asks first."
        }
    }
}

/// Persistent banner while full access is on, so it is never a surprise.
struct FullAccessBanner: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        if session.permissions?.isFullAccess == true {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                Text("Full access is on — the agent can run anything on this machine.")
                    .font(.caption)
                Spacer()
                Button("New chats: workspace only") {
                    Task { await model.setDefaultPreset("workspace-write", startChat: false) }
                }
                .font(.caption)
                .help("This chat keeps full access — permissions lock in at creation.")
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.10))
        }
    }
}

// MARK: - Produced files

/// Files a turn successfully created or modified.
struct ProducedFiles: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let paths: [String]

    var body: some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(paths.count == 1 ? "1 file" : "\(paths.count) files")
                    .font(.caption2).bold()
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(paths, id: \.self) { path in
                        FileChip(path: path, session: session)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

struct FileChip: View {
    @Environment(AppModel.self) private var model
    let path: String
    let session: SessionVM

    var body: some View {
        Menu {
            Button("Open") { Task { await model.openPath(resolved) } }
            Button("Reveal in Finder") { model.revealLocally(resolved) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resolved, forType: .string)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.caption2)
                Text((path as NSString).lastPathComponent).font(.caption)
            }
        } primaryAction: {
            Task { await model.openPath(resolved) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(resolved)
    }

    /// Tool paths may be relative to the session workspace.
    private var resolved: String {
        guard !path.hasPrefix("/"), let cwd = session.cwd else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
