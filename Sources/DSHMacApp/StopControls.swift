import SwiftUI
import DSHKit

/// Always-visible notice that agents are working, with one-click stop.
///
/// A running agent used to be visible only as a spinner on its own sidebar
/// row, and stoppable only from the toolbar of the chat you happened to have
/// open. This sits above the sidebar list so a background agent cannot be
/// running unnoticed or unreachable.
struct RunningAgentsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.runningSessions
        if !running.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12)
                    // Clicking the label jumps to a running chat, so "something
                    // is running" always has a way to see what.
                    Button {
                        model.revealRunning()
                    } label: {
                        Text(label(running.count))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Show what’s running")
                    Spacer(minLength: 4)
                    Button(running.count == 1 ? "Stop" : "Stop All") {
                        Task { await model.stopAll() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(allStopping(running))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            .background(.orange.opacity(0.14))
        }
    }

    private func allStopping(_ running: [SessionVM]) -> Bool {
        running.allSatisfy { model.stopping.contains($0.id) }
    }

    private func label(_ count: Int) -> String {
        if allStopping(model.runningSessions) {
            return count == 1 ? "Stopping…" : "Stopping \(count) agents…"
        }
        return count == 1 ? "1 agent running" : "\(count) agents running"
    }
}

/// Stop control for one session, usable wherever that session is shown.
struct StopButton: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    var compact = false

    var body: some View {
        if session.running {
            Button {
                Task { await model.stop(session) }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(compact ? .caption : .body)
                    .foregroundStyle(isStopping ? Color.secondary : .red)
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .help(isStopping ? "Stopping…" : "Stop this agent")
        }
    }

    private var isStopping: Bool { model.stopping.contains(session.id) }
}

/// Recovery when the harness itself, not a single turn, is the problem.
///
/// Restarting is only possible for a harness this app started; one launched
/// elsewhere is another process's to manage, and saying so is more useful than
/// a button that quietly does nothing.
struct HarnessRecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Harness recovery", systemImage: "stethoscope")
                .font(.headline)

            Text("""
            Stopping a chat cancels its turn. If the harness process itself is \
            wedged — nothing responds, or a chat will not clear — restarting it \
            is the next step.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Endpoint") {
                Text(model.baseURL.absoluteString).font(.callout.monospaced())
            }
            LabeledContent("Agents running") {
                Text("\(model.runningSessions.count)")
            }
            LabeledContent("Process") {
                Text(processDescription).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task {
                        working = true
                        await model.stopAll()
                        working = false
                    }
                } label: {
                    Label("Stop All Agents", systemImage: "stop.circle")
                }
                .disabled(model.runningSessions.isEmpty || working)

                Button {
                    Task {
                        working = true
                        await model.connect()
                        working = false
                    }
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(working)

                if model.canRestartHarness {
                    Button(role: .destructive) {
                        Task {
                            working = true
                            await model.restartHarness()
                            working = false
                        }
                    } label: {
                        Label("Restart Harness Process", systemImage: "exclamationmark.arrow.circlepath")
                    }
                    .disabled(working)
                } else {
                    Text("""
                    This harness was started outside the app, so it cannot be \
                    restarted from here. Stop it where you launched it, then use \
                    Reconnect.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
            }
        }
        .padding(18)
        .frame(width: 440, height: 400)
    }

    private var processDescription: String {
        switch model.harness.state {
        case .running(let pid, _): "started by this app (pid \(pid))"
        case .starting: "starting…"
        case .exited(let code): "exited with code \(code)"
        case .idle: "started outside this app"
        }
    }
}
