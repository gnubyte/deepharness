import SwiftUI
import AppKit
import DSHCore

/// The Automations mode: scheduled prompts that run unattended in their own
/// chat. A month calendar shows when each will fire; the list edits them;
/// OpenClaw's scheduled tasks import and export in both directions.
///
/// Structured as several small views (the Swift 6.0 type checker asserts on
/// very large @Observable-driven bodies).
@MainActor
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Automation?
    @State private var isAdding = false
    @State private var selectedID: String?
    @State private var importResult: String?
    @State private var month: Date = .now

    private var store: AutomationStore { model.automations.currentStore() }
    private var upcoming: [(date: Date, automation: Automation)] {
        model.automations.upcoming(now: .now, perAutomation: 10, total: 200)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                // Left: the calendar and the next runs.
                VStack(spacing: 0) {
                    CalendarHeaderView(month: $month)
                    AutomationCalendar(month: month, upcoming: upcoming, store: store)
                    Divider()
                    UpcomingList(upcoming: upcoming.prefix(8).map { $0 })
                }
                .frame(minWidth: 380, maxWidth: 560)
                // Right: the library.
                AutomationList(
                    store: store,
                    selectedID: $selectedID,
                    onAdd: { isAdding = true; editing = nil },
                    onEdit: { editing = $0; isAdding = false },
                    onToggle: { model.toggleAutomation(id: $0) },
                    onDelete: { model.deleteAutomation(id: $0) },
                    onRunNow: { model.runAutomationNow($0) },
                    onImport: { importOpenClaw() },
                    onExport: { exportOpenClaw() }
                )
                .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .background(.background)
        .sheet(isPresented: $isAdding) {
            AutomationEditor(existing: nil) { draft in
                model.saveAutomation(draft)
            }
        }
        .sheet(item: $editing) { automation in
            AutomationEditor(existing: automation) { draft in
                model.saveAutomation(draft)
            }
        }
        .alert("OpenClaw import", isPresented: Binding(
            get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResult ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automations").font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.transport.runningAutomations.isEmpty {
                ProgressView().controlSize(.small)
                Text("\(model.transport.runningAutomations.count) running")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let enabled = store.automations.filter(\.enabled).count
        let next = upcoming.first
        if let next {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "\(enabled) scheduled — next: “\(next.automation.name)” at \(f.string(from: next.date))"
        }
        return enabled == 0 ? "Nothing scheduled" : "\(enabled) scheduled"
    }

    private func importOpenClaw() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "OpenClaw's cron/jobs.json (or the folder that holds it)"
        if panel.runModal() == .OK, let url = panel.urls.first {
            // Accept either the jobs.json itself or a directory containing it.
            let target = url.hasDirectoryPath
                ? url.appendingPathComponent("jobs.json")
                : url
            let count = model.importOpenClawJobs(from: target)
            importResult = count == 0
                ? "No scheduled prompts were found in that file. Only jobs with a cron / every / one-off schedule and a prompt payload import."
                : "Imported \(count) automation\(count == 1 ? "" : "s") from OpenClaw."
        }
    }

    private func exportOpenClaw() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jobs.json"
        panel.message = "Export as an OpenClaw jobs.json (compatible with OpenClaw's cron)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OpenClawCompat.exportJSON(store.automations).write(to: url)
            importResult = "Exported \(store.automations.count) automations as OpenClaw jobs."
        } catch {
            importResult = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Calendar

@MainActor
private struct CalendarHeaderView: View {
    @Binding var month: Date

    var body: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Text(monthTitle).font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
            Button("Today") { month = .now }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM y")
        return f.string(from: month)
    }

    private func shift(_ months: Int) {
        var cal = Calendar.current
        cal.timeZone = .current
        month = cal.date(byAdding: .month, value: months, to: month) ?? month
    }
}

/// A month grid; days with scheduled runs show a dot (accent when several).
@MainActor
private struct AutomationCalendar: View {
    let month: Date
    let upcoming: [(date: Date, automation: Automation)]
    let store: AutomationStore

    private var counts: [String: Int] {
        var out: [String: Int] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        for entry in upcoming where Calendar.current.isDate(entry.date, equalTo: month, toGranularity: .month) {
            out[f.string(from: entry.date), default: 0] += 1
        }
        return out
    }

    private var dayCells: [DayCell] {
        var cal = Calendar.current
        cal.timeZone = .current
        let components = cal.dateComponents([.year, .month], from: month)
        guard let first = cal.date(from: components) else { return [] }
        let daysInMonth = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        // Weekday of the 1st (Mon-first grid), 0 = Monday.
        let leading = (cal.component(.weekday, from: first) + 5) % 7
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        let prefix = f.string(from: first)
        var cells: [DayCell] = (0..<leading).map { DayCell(id: $0, day: nil, key: "") }
        for day in 1...daysInMonth {
            cells.append(DayCell(id: leading + day - 1, day: day, key: String(format: "%@-%02d", prefix, day)))
        }
        return cells
    }

    struct DayCell: Identifiable {
        let id: Int
        let day: Int?
        let key: String
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(dayCells) { cell in
                    if let day = cell.day {
                        let count = counts[cell.key] ?? 0
                        let isToday = Calendar.current.isDateInToday(
                            Calendar.current.date(bySetting: .day, value: day, of: month) ?? month)
                        VStack(spacing: 2) {
                            Text("\(day)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                            Circle()
                                .fill(count > 0 ? Color.accentColor : .clear)
                                .frame(width: count > 2 ? 7 : 5, height: count > 2 ? 7 : 5)
                                .opacity(count > 0 ? 1 : 0)
                        }
                        .frame(minHeight: 30)
                        .frame(maxWidth: .infinity)
                        .background(isToday ? Color.accentColor.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .help(count > 0 ? "\(count) scheduled run\(count == 1 ? "" : "s")" : "")
                    } else {
                        Color.clear.frame(minHeight: 30)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

@MainActor
private struct UpcomingList: View {
    let upcoming: [(date: Date, automation: Automation)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next runs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                if upcoming.isEmpty {
                    Text("Nothing scheduled. Add an automation or import OpenClaw's jobs.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                }
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Automation.when(entry.date))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(entry.automation.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 180)
    }
}

// MARK: - The library list

@MainActor
private struct AutomationList: View {
    let store: AutomationStore
    @Binding var selectedID: String?
    let onAdd: () -> Void
    let onEdit: (Automation) -> Void
    let onToggle: (String) -> Void
    let onDelete: (String) -> Void
    let onRunNow: (String) -> Void
    let onImport: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu {
                    Button("Import OpenClaw jobs.json…") { onImport() }
                    Button("Export as OpenClaw jobs.json…") { onExport() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Import/export OpenClaw scheduled tasks")
                Button { onAdd() } label: { Image(systemName: "plus") }
                    .help("New automation")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.automations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No automations yet")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("Schedule a prompt — “run the ticket sync every weekday at 8:30” — and it runs in its own chat, unattended. OpenClaw's scheduled tasks import as-is.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                    Button("New Automation") { onAdd() }.controlSize(.small)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.automations) { automation in
                            AutomationRow(automation: automation, selected: selectedID == automation.id)
                                .onTapGesture { selectedID = automation.id }
                                .contextMenu {
                                    Button("Edit…") { onEdit(automation) }
                                    Button("Run now") { onRunNow(automation.id) }
                                    Button(automation.enabled ? "Disable" : "Enable") { onToggle(automation.id) }
                                    Divider()
                                    Button("Delete", role: .destructive) { onDelete(automation.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if let id = selectedID, let automation = store.automation(id: id) {
                    Divider()
                    AutomationDetail(automation: automation, onEdit: { onEdit(automation) },
                                     onToggle: { onToggle(automation.id) },
                                     onRunNow: { onRunNow(automation.id) },
                                     onDelete: { onDelete(automation.id) })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private struct AutomationRow: View {
    let automation: Automation
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: automation.enabled ? "clock.badge.checkmark" : "clock.badge.xmark")
                .font(.system(size: 11))
                .foregroundStyle(automation.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(automation.name).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(automation.schedule.label)
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    if automation.runCount > 0 {
                        Text("· ran \(automation.runCount)×").font(.system(size: 9)).foregroundStyle(.tertiary)
                        if let status = automation.lastStatus {
                            let tint: Color = status == "complete" ? .green : (status == "failed" ? .red : .secondary)
                            Text("· \(status)").font(.system(size: 9)).foregroundStyle(tint)
                        }
                    }
                }
            }
            Spacer()
            if automation.lastRunAt != nil && !automation.enabled && automation.isOnceDone {
                Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

@MainActor
private struct AutomationDetail: View {
    let automation: Automation
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onDelete: () -> Void
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(automation.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Edit", action: onEdit).controlSize(.small)
                Button(automation.enabled ? "Disable" : "Enable", action: onToggle).controlSize(.small)
                Button("Run now", action: onRunNow).controlSize(.small)
                Button { onDelete() } label: { Image(systemName: "trash") }
                    .controlSize(.small).foregroundStyle(.red)
            }
            Text(automation.schedule.label).font(.system(size: 10)).foregroundStyle(.secondary)
            if let project = automation.projectPath {
                Label(URL(fileURLWithPath: project).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !automation.prompt.isEmpty {
                Text(automation.prompt).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !automation.history.isEmpty {
                Button(showHistory ? "Hide history" : "History (\(automation.history.count))") {
                    showHistory.toggle()
                }
                .controlSize(.small).buttonStyle(.plain).foregroundStyle(.tint)
                if showHistory {
                    ForEach(Array(automation.history.suffix(8).enumerated().reversed()), id: \.offset) { _, run in
                        HStack(spacing: 6) {
                            Text(Automation.when(run.at)).font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary).frame(width: 100, alignment: .leading)
                            let tint: Color = run.status == "complete" ? .green : (run.status == "failed" ? .red : .secondary)
                            Text(run.status).font(.system(size: 9)).foregroundStyle(tint)
                            if let d = run.duration { Text("· \(d.formattedDuration)").font(.system(size: 9)).foregroundStyle(.tertiary) }
                            if let detail = run.detail { Text("· \(detail)").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                    }
                }
            }
        }
        .padding(10)
    }
}

// MARK: - Editor

@MainActor
struct AutomationEditor: View {
    let existing: Automation?
    let onSave: (Automation) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var prompt = ""
    @State private var kindIndex = 0
    @State private var cronExpr = "30 8 * * 1-5"
    @State private var intervalMinutes = 30
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var enabled = true
    @State private var projectPath: String?
    @State private var attachments: [MessageAttachment] = []
    @State private var showingError: String?

    private let kinds = ["On a schedule (cron)", "Every N minutes", "Once"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(existing == nil ? "New Automation" : "Edit Automation")
                .font(.system(size: 14, weight: .semibold))

            TextField("Name (short)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("Runs", selection: $kindIndex) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { i, label in
                        Text(label).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch kindIndex {
            case 0:
                HStack {
                    TextField("30 8 * * 1-5", text: $cronExpr)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text(CronParser.describe(cronExpr))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("minute · hour · day-of-month · month · day-of-week  —  e.g. “30 8 * * 1-5” = weekdays at 08:30")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            case 1:
                Stepper(value: $intervalMinutes, in: 1...10_080) {
                    Text("Every \(intervalMinutes) minute\(intervalMinutes == 1 ? "" : "s")")
                        .font(.system(size: 12))
                }
            default:
                DatePicker("When", selection: $onceDate)
                    .font(.system(size: 12))
            }

            HStack {
                Picker("Project", selection: $projectPath) {
                    Text("Current project").tag(String?.none)
                    if let current = model.project?.path {
                        Text(model.project?.lastPathComponent ?? "Project").tag(String?.some(current))
                    }
                }
                .font(.system(size: 11))
                Spacer()
                Button {
                    attach()
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .controlSize(.small)
            }

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 140, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .help("The prompt the automation sends, unattended. Long prompts are fine — the run gets its own chat and its own context window.")

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments, id: \.self) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                                    .font(.caption2)
                                Text(attachment.name).font(.system(size: 10)).lineLimit(1)
                                Button { attachments.removeAll { $0 == attachment } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption2)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.4), in: Capsule())
                        }
                    }
                }
            }

            if let showingError {
                Text(showingError).font(.system(size: 10)).foregroundStyle(.red)
            }

            HStack {
                Toggle("Enabled", isOn: $enabled).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add Automation" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { hydrate() }
    }

    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !prompt.isEmpty else { return false }
        switch kindIndex {
        case 0: return CronParser.isValid(cronExpr)
        default: return true
        }
    }

    private func hydrate() {
        guard let existing else { return }
        name = existing.name
        prompt = existing.prompt
        enabled = existing.enabled
        projectPath = existing.projectPath
        attachments = existing.attachments ?? []
        switch existing.schedule {
        case .cron(let expr, _):
            kindIndex = 0; cronExpr = expr
        case .interval(let seconds, _):
            kindIndex = 1; intervalMinutes = max(1, seconds / 60)
        case .once(let at):
            kindIndex = 2; onceDate = at
        }
    }

    private func schedule() -> AutomationSchedule {
        switch kindIndex {
        case 0: return .cron(expr: cronExpr.trimmingCharacters(in: .whitespaces), timeZone: TimeZone.current.identifier)
        case 1: return .interval(seconds: intervalMinutes * 60, anchor: nil)
        default: return .once(at: onceDate)
        }
    }

    private func save() {
        var automation = existing ?? Automation(name: name.trimmingCharacters(in: .whitespaces), prompt: prompt, schedule: schedule())
        automation.name = name.trimmingCharacters(in: .whitespaces)
        automation.prompt = prompt
        automation.schedule = schedule()
        automation.enabled = enabled
        automation.projectPath = projectPath
        automation.attachments = attachments.isEmpty ? nil : attachments
        onSave(automation)
        dismiss()
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let kind: MessageAttachment.Kind = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff"]
                .contains(url.pathExtension.lowercased()) ? .image : .file
            attachments.append(MessageAttachment(kind: kind, name: url.lastPathComponent, data: data))
        }
    }
}

// MARK: - Helpers

extension Automation {
    /// "Wed 14:32" (this week) / "Nov 12 14:32".
    static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: .now.addingTimeInterval(86400 * 6), toGranularity: .weekOfYear)
            ? "EEE HH:mm" : "MMM d HH:mm"
        return f.string(from: date)
    }

    /// A `.once` automation whose moment has passed.
    var isOnceDone: Bool {
        if case .once(let at) = schedule { return at <= .now }
        return false
    }
}
