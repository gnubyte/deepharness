import SwiftUI
import AppKit
import DSHCore

@main
struct DSHMacApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }
    }
}

/// Keeps the app's lifetime tied to its window and stops agents on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model.newChat() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Project Folder…") { model.chooseProject() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("New Terminal") {
                model.mode = .code
                model.code.newTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.project == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.code.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.code.activeBuffer == nil)
            Button("Save All") { model.code.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.code.hasUnsavedChanges)
            Button("Close Editor") { model.code.closeActiveBuffer() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.code.activeBuffer == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Stop Turn") { model.stopSelected() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(model.selectedSession?.running ?? false))
            Button("Stop All Agents") { model.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!model.anythingRunning)
            Divider()
            Button("Memory & Skills…") { model.showMemoryAndSkills = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Reload Project Context") { model.transport.refreshProjectContext() }
                .disabled(model.project == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Chat Mode") { model.mode = .chat }
                .keyboardShortcut("1", modifiers: .command)
            Button("Code Mode") { model.mode = .code }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Toggle File Tree") { model.code.showTree.toggle() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Toggle Terminal") {
                model.mode = .code
                model.code.toggleTerminal()
            }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(model.project == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Run Setup Wizard…") { model.showWizard = true }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            detail
                .toolbar { toolbar }
        }
        .sheet(isPresented: $model.showWizard) {
            SetupWizard().environment(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environment(model)
        }
        .sheet(isPresented: $model.showMemoryAndSkills) {
            MemorySkillsView().environment(model)
        }
        .overlay(alignment: .top) { banner }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mode {
        case .chat:
            if let session = model.selectedSession {
                ChatView(session: session)
            } else {
                EmptyStateView(icon: "sparkles",
                               title: "DSH",
                               message: "A native coding agent. Open a project folder, then start a chat.") {
                    HStack {
                        Button("Open Folder…") { model.chooseProject() }
                        Button("New Chat") { model.newChat() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case .code:
            CodeModeView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Chat (⌘1) or Code (⌘2)")
        }

        ToolbarItem(placement: .principal) {
            Button {
                model.chooseProject()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(model.project?.lastPathComponent ?? "No project")
                        .lineLimit(1)
                }
            }
            .help(model.project?.path ?? "Open a project folder (⌘O)")
        }

        ToolbarItem {
            ModelMenu()
        }

        ToolbarItem {
            PresetMenu()
        }

        ToolbarItem {
            if let session = model.selectedSession, session.running {
                Button {
                    model.transport.stopSession(session.id)
                } label: {
                    Label(session.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .disabled(session.stopping)
                .help("Stop the agent (⌘.)")
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = model.transport.banner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                if !model.config.isConfigured {
                    Button("Set Up…") {
                        model.transport.banner = nil
                        model.showWizard = true
                    }
                    .controlSize(.small)
                }
                Button {
                    model.transport.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.errorTint.opacity(0.4)))
            .shadow(radius: 8, y: 2)
            .padding(12)
            .frame(maxWidth: 620)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Toolbar menus

private struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.config.providers, id: \.routeID) { provider in
                Button {
                    model.config.activeRoute = provider.routeID
                } label: {
                    if model.config.activeRoute == provider.routeID {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
            Divider()
            Button("Configure…") { model.showSettings = true }
            Button("Run Setup Wizard…") { model.showWizard = true }
        } label: {
            Label(model.config.activeProvider?.model ?? "No model", systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.config.activeProvider?.baseURL ?? "No model configured")
    }
}

private struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingFullAccess = false

    var body: some View {
        Menu {
            Section("New chats start with") {
                ForEach(PermissionPreset.allCases, id: \.self) { preset in
                    Button {
                        if preset == .fullAccess {
                            confirmingFullAccess = true
                        } else {
                            model.config.preset = preset.rawValue
                        }
                    } label: {
                        if model.config.asPreset == preset {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            }
            if let session = model.selectedSession {
                Divider()
                Text("This chat: \(session.preset.label)")
            }
        } label: {
            Label(current.label, systemImage: current.icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(current == .fullAccess ? .red : nil)
        .help(current.detail)
        .alert("Turn on full access?", isPresented: $confirmingFullAccess) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Full Access", role: .destructive) {
                model.config.preset = PermissionPreset.fullAccess.rawValue
            }
        } message: {
            Text("""
            New chats will write files and run shell commands without asking, anywhere your user \
            account can reach. Existing chats keep the preset they were created with.
            """)
        }
    }

    /// The open chat's preset when there is one — that is what is actually in
    /// force — otherwise the default for new chats.
    private var current: PermissionPreset {
        model.selectedSession?.preset ?? model.config.asPreset
    }
}
