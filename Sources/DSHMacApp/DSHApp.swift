import SwiftUI
import DSHKit

@main
struct DSHApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    // Stay in the project the user is already working in.
                    let workspaceId = model.activeProject?.id
                    Task { await model.newSession(workspaceId: workspaceId) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isConnected)

                Button("Open Project Folder…") {
                    ProjectPicker.open(into: model)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.isConnected)
            }
            CommandMenu("Session") {
                Button("Stop Turn") { Task { await model.cancel() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selected?.running != true)
                Button(stopAllTitle(model)) { Task { await model.stopAll() } }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(model.runningSessions.isEmpty)
                Button("Stop Subagents") {
                    guard let vm = model.selected else { return }
                    Task { await model.stopSubagents(vm) }
                }
                .disabled(model.selected == nil)
                Divider()
                Button("Memory & Skills…") { model.showMemorySkills = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!model.isConnected)
                Button("Harness Recovery…") { model.showRecovery = true }
                Button("Fork Chat") {
                    guard let vm = model.selected else { return }
                    Task { await model.fork(vm) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selected == nil)
                Divider()
                Button("Reconnect") { Task { await model.connect() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Prompt History") {
                    NotificationCenter.default.post(name: .showPromptHistory, object: nil)
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.selected == nil)
            }
        }

        Settings {
            ProvidersView()
                .environment(model)
                .frame(width: 660, height: 520)
        }
    }
}

/// Names the count so the menu says what it will actually do.
@MainActor
private func stopAllTitle(_ model: AppModel) -> String {
    let n = model.runningSessions.count
    return n > 1 ? "Stop All \(n) Agents" : "Stop All Agents"
}

extension AppModel {
    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }
}
