import SwiftUI
import VisionHarnessCore

/// The model button, shared by the toolbar and the composer. A popover rather
/// than a menu, because the list got too long for one: search as you type,
/// filter by where the model comes from.
struct ModelPickerButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ModelPickerPopover(dismiss: { showing = false })
                .environment(model)
        }
    }
}

private struct PickerEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let source: ModelSource
    let icon: String
    let isCurrent: Bool
    var isDisabled = false
    var person: GuardianPerson?
    let action: @MainActor () -> Void

    var searchFields: [String] { [title, subtitle ?? "", source.label] }
}

struct ModelPickerPopover: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    @State private var search = ""
    /// `search`, once typing pauses, so a long list doesn't refilter per key.
    @State private var query = ""
    @State private var source: ModelSource?
    @State private var showSubagents = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let entries = allEntries
        let sources = ModelSource.allCases.filter { candidate in entries.contains { $0.source == candidate } }
        let visible = entries.filter {
            (source == nil || $0.source == source) && ModelSearch.matches(query: query, fields: $0.searchFields)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = visible.first(where: { !$0.isDisabled }) { choose(first) } }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            if sources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        chip("All", selected: source == nil) { source = nil }
                        ForEach(sources) { candidate in
                            chip(candidate.label, selected: source == candidate) { source = candidate }
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if visible.isEmpty {
                        Text(entries.isEmpty ? "No models are configured yet." : "Nothing matches that.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(visible) { entry in
                        row(entry)
                    }
                }
            }
            .frame(height: 300)

            Divider()
            footer
        }
        .padding(10)
        .frame(width: 380)
        .onAppear {
            searchFocused = true
            model.refreshGuardianIfStale()
        }
        .task(id: search) {
            if search.isEmpty {
                query = ""
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled { query = search }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: PickerEntry) -> some View {
        Button {
            choose(entry)
        } label: {
            HStack(spacing: 8) {
                if let person = entry.person {
                    PersonAvatar(person: person, size: 20)
                } else {
                    Image(systemName: entry.icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let subtitle = entry.subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if entry.isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(entry.isCurrent ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.isDisabled)
        .opacity(entry.isDisabled ? 0.5 : 1)
    }

    private func choose(_ entry: PickerEntry) {
        entry.action()
        dismiss()
    }

    @ViewBuilder
    private var footer: some View {
        let config = model.config
        if config.providers.count > 1 {
            DisclosureGroup("Subagent servers", isExpanded: $showSubagents) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        // A chat-only route can't run the tools a subagent needs.
                        ForEach(config.providers.filter { $0.routeID != config.activeRoute && !$0.isGuardianChatOnly }, id: \.routeID) { provider in
                            Toggle(isOn: Binding(get: { provider.isSubagentWorker },
                                                 set: { config.setSubagentWorker(provider.routeID, $0) })) {
                                Text(provider.displayName).font(.system(size: 11)).lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            .font(.system(size: 11))
        }
        HStack(spacing: 10) {
            if !model.guardian.isSignedIn {
                footerButton("Sign in to Guardian…") {
                    model.settingsTab = .guardian
                    model.showSettings = true
                }
            }
            let bedrock = config.providers.filter { $0.kind == .bedrock }
            if bedrock.isEmpty {
                footerButton("Add Bedrock…") { model.showBedrockGuide() }
            } else {
                let target = config.mainRoute.flatMap { $0.kind == .bedrock ? $0 : nil } ?? bedrock[0]
                footerButton("Bedrock Models…") { model.showBedrockGuide(page: .model, route: target) }
            }
            if !model.spark.isConfigured {
                footerButton("Connect a Spark…") { model.showSwapperGuide() }
            }
            Spacer()
            footerButton("Configure…") { openModelsSettings() }
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            dismiss()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.tint)
    }

    private func openModelsSettings() {
        model.settingsTab = .models
        model.showSettings = true
    }

    // MARK: Entries

    private var allEntries: [PickerEntry] {
        peopleEntries + routeEntries + sparkEntries
    }

    /// People appear in Agent mode, where each is a thread of their own.
    private var peopleEntries: [PickerEntry] {
        guard model.mode == .agent else { return [] }
        let current = model.selectedSession?.person?.id
        return model.guardianPeople.map { person in
            PickerEntry(id: "person-\(person.id)", title: person.displayName, subtitle: person.title ?? "Guardian person",
                        source: .people, icon: "person.fill", isCurrent: person.id == current, person: person) {
                model.openThread(with: person)
            }
        }
    }

    private var routeEntries: [PickerEntry] {
        let config = model.config
        let inPersonThread = model.selectedSession?.person != nil
        return config.providers.filter(\.isEnabled).map { provider in
            PickerEntry(id: provider.routeID, title: provider.friendlyModel,
                        subtitle: subtitle(for: provider), source: source(of: provider),
                        icon: provider.isPrivateRoute ? "lock.fill" : "shield.lefthalf.filled",
                        isCurrent: provider.routeID == config.activeRoute && !inPersonThread) {
                if inPersonThread { model.openMainAgentThread() }
                guard provider.routeID != config.activeRoute else { return }
                config.makeMain(provider.routeID)
                model.transport.resetRouteCache()
            }
        }
    }

    private func subtitle(for provider: ProviderProfile) -> String {
        let config = model.config
        var parts = [provider.name]
        if provider.isGuardianChatOnly { parts.append("chat only, no tools here") }
        if provider.routeID != config.activeRoute {
            if model.transport.workerRoutes.contains(where: { $0.routeID == provider.routeID }) { parts.append("subagents") }
            if config.backupRoutes.contains(where: { $0.routeID == provider.routeID }) { parts.append("backup") }
        }
        parts.append(provider.isPrivateRoute ? "private" : "masked")
        return parts.joined(separator: " · ")
    }

    private func source(of provider: ProviderProfile) -> ModelSource {
        switch provider.kind {
        case .guardian: provider.isGuardianChatOnly ? .guardianLocal : .guardian
        case .bedrock: .bedrock
        default: provider.isSelfHosted ? .local : .hosted
        }
    }

    private var sparkEntries: [PickerEntry] {
        let spark = model.spark
        return spark.boxes.flatMap { box -> [PickerEntry] in
            guard let status = box.status else { return [] }
            return status.ordered.map { candidate in
                let active = candidate.key == status.active
                let state = active ? "serving" : !candidate.isInstalled ? "not installed" : candidate.running ? "loading" : "switch to this"
                return PickerEntry(id: "spark-\(box.id)-\(candidate.key)", title: candidate.title,
                                   subtitle: "\(box.name) · \(state)", source: .spark,
                                   icon: active ? "checkmark.circle.fill" : candidate.isInstalled ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                                   isCurrent: active, isDisabled: active || status.isSwitching || !candidate.isInstalled) {
                    spark.request(candidate, on: box)
                }
            }
        }
    }
}
