import SwiftUI
import AppKit
import DSHCore

/// The task queue panel: an ordered, long-lived work list. Add, edit, delete,
/// reorder, then ▶ to have the harness run them one at a time as unattended
/// goals — or pull up the timestamped log of what it did.
///
/// Structured as several small views (rather than one big body): the Swift
/// 6.0 type checker asserts on very large @Observable-driven bodies.
@MainActor
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTaskID: String?
    @State private var editingTitle = ""
    @State private var editingDetails = ""
    @State private var isEditing = false
    @State private var showLog = false
    @State private var adding = false
    @State private var newTitle = ""
    @State private var newDetails = ""
    @State private var newAtFront = false

    private var transport: AppTransport { model.transport }
    private var queue: TaskQueue { transport.queue }
    private var queueTasksKey: [String] { queue.tasks.map(\.id) }
    private var selectedTask: QueueTask? {
        guard let id = selectedTaskID else { return nil }
        return queue.task(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            QueueHeaderView(running: transport.queueRunningNow,
                            subtitle: subtitle,
                            canStart: queue.nextTask != nil,
                            onAdd: {
                                adding = true
                                newTitle = ""; newDetails = ""
                                withAnimation { selectedTaskID = "new" }
                            },
                            onLog: { showLog = true },
                            onStart: { transport.startQueue() },
                            onStop: { transport.stopQueue() })
            Divider()
            if queue.tasks.isEmpty {
                QueueEmptyView(onAdd: {
                    adding = true
                    withAnimation { selectedTaskID = "new" }
                })
            } else {
                TaskListPane(
                    tasks: queue.tasks,
                    positions: positionMap,
                    selectedID: selectedTaskID,
                    adding: adding,
                    newTitle: $newTitle,
                    newDetails: $newDetails,
                    newAtFront: $newAtFront,
                    onSelect: { id in
                        selectedTaskID = id
                        isEditing = false
                    },
                    onMoveBefore: { dragged, target in
                        transport.queueMove(id: dragged, before: target)
                    },
                    onCancelAdd: { adding = false; selectedTaskID = nil },
                    onAdd: {
                        transport.queueAdd(newTitle, details: newDetails, atFront: newAtFront)
                        newTitle = ""; newDetails = ""; newAtFront = false
                        adding = false
                        selectedTaskID = transport.queue.nextTask?.id
                    })
                Divider()
                TaskDetailPane(
                    task: selectedTask,
                    isEditing: $isEditing,
                    title: $editingTitle,
                    details: $editingDetails,
                    onSave: { saveEdit() },
                    onOpenChat: { if let id = selectedTask?.sessionID { model.openSession(id) } },
                    onResume: { if let id = selectedTask?.id { transport.resumeTask(id) } },
                    onEdit: { if let t = selectedTask {
                        editingTitle = t.title; editingDetails = t.details; isEditing = true
                    } },
                    onDelete: { if let id = selectedTask?.id {
                        transport.queueRemove(id: id); selectedTaskID = nil
                    } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: queueTasksKey) { _, ids in
            if let current = selectedTaskID, !ids.contains(current) {
                selectedTaskID = nil
                isEditing = false
            }
        }
        .sheet(isPresented: $showLog) { QueueLogSheet() }
    }

    private var subtitle: String {
        let s = queue.stats()
        if transport.queueRunningNow {
            if let running = queue.runningTask {
                return "Working “\(running.title)” · \(s.queued) waiting"
            }
            return "Queue is running"
        }
        if s.blocked > 0 { return "\(s.blocked) need(s) you · \(s.queued) waiting" }
        if s.queued > 0 { return "\(s.queued) waiting · \(s.completed) done" }
        if s.total > 0 { return "\(s.total) finished" }
        return "Nothing queued"
    }

    private var positionMap: [String: Int] {
        var m: [String: Int] = [:]
        for t in queue.tasks where t.status == .queued {
            m[t.id] = queue.position(of: t.id)
        }
        return m
    }

    private func saveEdit() {
        guard let t = selectedTask else { return }
        transport.queueUpdate(id: t.id, title: editingTitle, details: editingDetails)
        isEditing = false
    }
}

// MARK: - Header

@MainActor
struct QueueHeaderView: View {
    let running: Bool
    let subtitle: String
    let canStart: Bool
    let onAdd: () -> Void
    let onLog: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if running { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Task Queue").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Add a task")
            Button(action: onLog) { Image(systemName: "text.bubble") }
                .help("View the queue log")
            if running {
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
                    .help("Stop the queue; the current task goes back in line")
            } else {
                Button(action: onStart) { Label("Start", systemImage: "play.fill") }
                    .disabled(!canStart)
                    .help("Work the queued tasks one at a time, top to bottom")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Empty

@MainActor
struct QueueEmptyView: View {
    let onAdd: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray.full").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No tasks yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("Queue up work — one per item. Press ▶ and the harness runs them autonomously, one after another, all week if it has to.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 18)
            Button("Add the first task", action: onAdd).controlSize(.small)
            Spacer()
        }
    }
}

// MARK: - List

@MainActor
struct TaskListPane: View {
    let tasks: [QueueTask]
    let positions: [String: Int]
    let selectedID: String?
    let adding: Bool
    @Binding var newTitle: String
    @Binding var newDetails: String
    @Binding var newAtFront: Bool
    let onSelect: (String) -> Void
    let onMoveBefore: (String, String) -> Void
    let onCancelAdd: () -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, position: positions[task.id], selected: selectedID == task.id) {
                            onSelect(task.id)
                        }
                        .id(task.id)
                        // Queued tasks can be dragged onto another queued task
                        // to reorder the queue.
                        .draggable(task.id) {
                            if task.status == .queued {
                                Text(task.title).lineLimit(1)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard task.status == .queued,
                                  let dragged = items.first,
                                  dragged != task.id,
                                  tasks.first(where: { $0.id == dragged })?.status == .queued
                            else { return false }
                            onMoveBefore(dragged, task.id)
                            return true
                        }
                    }
                    if adding {
                        NewTaskCard(title: $newTitle, details: $newDetails, atFront: $newAtFront,
                                    onCancel: onCancelAdd, onAdd: onAdd)
                            .id("new")
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedID) { _, value in
                if let value { withAnimation { proxy.scrollTo(value, anchor: .center) } }
            }
        }
    }
}

@MainActor
private struct TaskRow: View {
    let task: QueueTask
    let position: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    subline
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var subline: some View {
        HStack(spacing: 4) {
            switch task.status {
            case .queued:
                if let position { Text("#\(position)") }
                Text("· added \(QueueLog.when(task.enteredAt))")
            case .running:
                Text("running")
                if task.rounds > 0 { Text("· \(task.rounds) rounds") }
                if task.totalTokens > 0 { Text("· \(task.totalTokens.formatted()) tok") }
            case .complete:
                Text("done · \(task.rounds) rounds")
                if let rate = task.avgTokensPerSecond {
                    Text("· \(Int(rate.rounded())) tok/s")
                }
            case .blocked:
                Text("waiting on you")
            case .failed:
                Text("failed")
            case .skipped:
                Text("skipped")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    private var icon: String {
        switch task.status {
        case .running: "play.fill"
        case .complete: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "arrow.forward.circle"
        case .queued: "circle"
        }
    }
    private var color: Color {
        switch task.status {
        case .running: .accentColor
        case .complete: .green
        case .blocked: .orange
        case .failed: .red
        case .skipped: .secondary
        case .queued: .secondary
        }
    }
}

@MainActor
private struct NewTaskCard: View {
    @Binding var title: String
    @Binding var details: String
    @Binding var atFront: Bool
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title (short)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { onAdd() }
            TextEditor(text: $details)
                .font(.system(size: 12))
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            Toggle("Add to the front of the queue", isOn: $atFront)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).controlSize(.small)
                Button("Add Task", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Details

@MainActor
struct TaskDetailPane: View {
    let task: QueueTask?
    @Binding var isEditing: Bool
    @Binding var title: String
    @Binding var details: String
    let onSave: () -> Void
    let onOpenChat: () -> Void
    let onResume: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let task {
                if isEditing {
                    TaskEditorForm(title: $title, details: $details,
                                   onSave: onSave, onCancel: { isEditing = false })
                } else {
                    TaskMetaHeader(task: task)
                    TaskActionBar(task: task, onOpenChat: onOpenChat, onResume: onResume,
                                  onEdit: onEdit, onDelete: onDelete)
                }
            } else {
                Text("Select a task to edit it or open its chat.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .padding(10)
        .frame(minHeight: 120)
    }
}

@MainActor
private struct TaskMetaHeader: View {
    let task: QueueTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(QueueLog.statusMark(task.status))
                Text(task.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            Text(metaLine).font(.system(size: 10)).foregroundStyle(.secondary)
            if !task.details.isEmpty {
                Text(task.details).font(.system(size: 11)).lineLimit(3).foregroundStyle(.secondary)
            }
        }
    }

    private var metaLine: String {
        switch task.status {
        case .queued:
            return "in the queue · added \(QueueLog.when(task.enteredAt))"
        case .running:
            var s = "running · \(task.rounds) round\(task.rounds == 1 ? "" : "s")"
            if task.totalTokens > 0 { s += " · \(task.totalTokens.formatted()) tokens" }
            return s
        case .complete:
            var s = "done · \(task.rounds) round\(task.rounds == 1 ? "" : "s") · \(task.totalTokens.formatted()) tokens"
            if let rate = task.avgTokensPerSecond { s += " · \(Int(rate.rounded())) tokens/s avg" }
            return s
        case .blocked: return "waiting on you — see its chat"
        case .failed: return "failed — see its chat"
        case .skipped: return "skipped"
        }
    }
}

@MainActor
private struct TaskActionBar: View {
    let task: QueueTask
    let onOpenChat: () -> Void
    let onResume: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if task.sessionID != nil {
                Button("Open chat", action: onOpenChat).controlSize(.small)
            }
            if task.status == .blocked || task.status == .failed {
                Button(action: onResume) { Label("Resume in chat", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit this task")
            Button(action: onDelete) { Image(systemName: "trash") }
                .foregroundStyle(.red)
                .help("Delete this task")
        }
    }
}

@MainActor
private struct TaskEditorForm: View {
    @Binding var title: String
    @Binding var details: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            TextEditor(text: $details)
                .font(.system(size: 12))
                .frame(minHeight: 90, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            HStack {
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel", action: onCancel).controlSize(.small)
                Spacer()
            }
        }
    }
}

// MARK: - Log sheet

@MainActor
struct QueueLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Text(text.isEmpty ? "Nothing to log yet." : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(width: 620, height: 460)
        .onAppear { text = QueueLog.report(model.transport.queue) }
    }

    private var header: some View {
        HStack {
            Text("Task Queue Log").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            Button("Done") { dismiss() }.controlSize(.small)
        }
        .padding(14)
    }
}
