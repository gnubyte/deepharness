import SwiftUI
import AppKit
import SystemConfiguration
import VisionHarnessCore

/// Settings ▸ Model Servers: the boxes running a Spark Swapper — a DGX Spark, a Strix Halo — what each is serving,
/// and switching them. A box is added with the connection code from its Connect tab (the guide), or, for a Swapper
/// older than 2.0, with its address and login.
struct SwapperSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let spark = model.spark
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A box running Spark Swapper — a DGX Spark or a Strix Halo — switches which model it serves. Connect it here and every chat follows whatever it serves.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if spark.boxes.isEmpty {
                        Text("No boxes yet. Add one with the connection code from its Swapper's Connect tab.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                    }
                    ForEach(spark.boxes) { box in
                        SwapperBoxRow(box: box)
                    }
                    DisclosureGroup("Connect with an address and login instead") {
                        SwapperLoginForm()
                            .padding(.top, 8)
                    }
                    .font(.callout)
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.showSwapperGuide()
                } label: {
                    Label("Add with a Connection Code…", systemImage: "plus")
                }
                Button("Refresh") { Task { await spark.refreshAll() } }
                    .disabled(spark.boxes.isEmpty)
                Spacer()
            }
            .padding(10)
        }
        .task { await spark.refreshAll() }
    }
}

/// One box: what it is, whether it answers, what it serves, and its models.
struct SwapperBoxRow: View {
    @Environment(AppModel.self) private var model
    let box: SwapperBox
    @State private var renaming = false
    @State private var newName = ""
    @State private var removing = false
    @State private var showModels = false
    @State private var pending: SwapperStatus.Model?
    @State private var showActivity = false
    @State private var windowChange: WindowChange?

    /// A context window picked for a model, waiting for "Restart It" (or "Save" when the model isn't serving).
    struct WindowChange {
        let model: SwapperStatus.Model
        let choice: SwapperStatus.Model.ContextChoice
        /// The model is serving: the box restarts it.
        let restarts: Bool
    }

    private var windowChangeMessage: String {
        guard let change = windowChange else { return "" }
        var text = change.restarts
            ? "\(change.model.title) stops and loads again with a \(change.choice.name) window (\(change.model.switchDuration)). If it won't start, the box puts the old window back. Chats follow automatically."
            : "\(change.model.title) isn't serving, so nothing restarts: it uses a \(change.choice.name) window the next time \(box.name) switches to it."
        if let detail = change.choice.detail, !detail.isEmpty { text += " \(change.choice.name): \(detail)." }
        if change.choice.pictures == false, box.status?.pictures?.value?.isOn == true {
            text += " Pictures are switched off first — there's no room for them next to this window."
        }
        return text
    }

    /// Pictures next to the model: the switch, what the box says about it, and what's in the way.
    @ViewBuilder
    private func picturesRow(_ pictures: SwapperPictures) -> some View {
        let spark = model.spark
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { pictures.isOn },
                                 set: { on in Task { await spark.setPictures(box, enabled: on) } })) {
                Text("Pictures (Qwen-Image next to the model)").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(box.working != nil || box.isSwitching)
            if let summary = pictures.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pictures.isOn {
                ForEach(Array(pictures.problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.noticeTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What changed on the box lately, newest first.
    @ViewBuilder
    private var activityList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let problem = box.activityError {
                Text(problem).font(.caption).foregroundStyle(Theme.errorTint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if box.activity.isEmpty {
                Text("Nothing has changed lately.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(box.activity.prefix(30).enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.mono(10)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Refresh") { Task { await model.spark.loadActivity(box) } }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    var body: some View {
        let spark = model.spark
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor).frame(width: 7, height: 7)
                            .help(box.isOnline ? "Answering" : box.lastError ?? "Not checked yet")
                        Text(box.name).font(.callout.weight(.semibold))
                        if box.refreshing || box.working != nil {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel(box.working ?? "Checking \(box.name)")
                        }
                    }
                    Text(box.summary).font(.caption).foregroundStyle(.secondary)
                    Text(box.servingLine)
                        .font(.caption)
                        .foregroundStyle(box.lastError == nil ? Color.secondary : Theme.errorTint)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if box.lastError != nil, box.untrustedFingerprint == nil {
                        // Not answering: say since when, and offer the one thing that can help from here.
                        HStack(spacing: 8) {
                            if let since = box.lastAnsweredText() {
                                Text(since).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Try Again") { Task { await spark.refresh(box) } }
                                .controlSize(.small)
                                .disabled(box.refreshing)
                        }
                    } else if let memory = box.status?.memory?.value, let summary = memory.summary {
                        HStack(spacing: 8) {
                            if let used = memory.usedFraction {
                                ProgressView(value: used)
                                    .frame(width: 90)
                                    .tint(used > 0.92 ? Theme.errorTint : Color.accentColor)
                                    .accessibilityLabel("Memory in use")
                            }
                            Text("Memory: \(summary)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let working = box.working {
                        Text(working).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = box.actionError {
                        HStack(alignment: .top, spacing: 6) {
                            Text(error).font(.caption).foregroundStyle(Theme.errorTint)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Button { box.actionError = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Dismiss")
                                .accessibilityLabel("Dismiss this message")
                        }
                    }
                    if let line = box.progressLine {
                        Label(line, systemImage: "hourglass").font(.caption)
                    }
                    if let line = box.installProgressLine {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Label(box.installProgressLine ?? line, systemImage: "arrow.down.circle").font(.caption)
                        }
                        if let detail = box.installJob?.lastLogLine {
                            Text(detail).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if let error = box.installError {
                        Text(error).font(.caption).foregroundStyle(Theme.errorTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button("Open Its Web Page") { if let url = box.webPage { NSWorkspace.shared.open(url) } }
                        .controlSize(.small)
                    Button("Rename…") {
                        newName = box.name
                        renaming = true
                    }
                    .controlSize(.small)
                    Button(role: .destructive) { removing = true } label: { Image(systemName: "trash") }
                        .controlSize(.small)
                        .help("Remove this box")
                }
            }
            if let fp = box.untrustedFingerprint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Swapper uses a self-signed certificate. Trust it if this fingerprint matches the box's (`sudo openssl x509 -in /etc/spark-swapper/tls.crt -noout -fingerprint -sha256`):")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(fp).font(Theme.mono(10)).textSelection(.enabled)
                    Button("Trust This Certificate") { spark.trustPresentedCertificate(box) }
                        .controlSize(.small)
                }
                .padding(.leading, 42)
            } else if let pin = box.connection.pinnedFingerprint {
                HStack(spacing: 6) {
                    Text("Certificate trusted (SHA-256 \(CertificatePin.short(pin)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Forget") { spark.forgetCertificate(box) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
                .padding(.leading, 42)
            }
            if let status = box.status, !status.models.isEmpty {
                DisclosureGroup(isExpanded: $showModels) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.ordered) { m in modelRow(m, status: status) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Models (\(status.installedModels.count) of \(status.models.count) installed)").font(.caption)
                }
                .padding(.leading, 42)
            }
            if let pictures = box.status?.pictures?.value, pictures.isInstalled {
                picturesRow(pictures)
                    .padding(.leading, 42)
            }
            if box.status != nil,
               SwapperVersion.isAtLeast(box.status?.version ?? box.connection.version, SwapperVersion.addFromHuggingFace) {
                DisclosureGroup("Add a model from Hugging Face") {
                    SwapperAddModelForm(box: box)
                        .padding(.top, 6)
                }
                .font(.caption)
                .padding(.leading, 42)
            }
            if box.status != nil {
                if box.hasContextAndPictures {
                    DisclosureGroup(isExpanded: $showActivity) {
                        activityList
                    } label: {
                        Text("Recent activity").font(.caption)
                    }
                    .padding(.leading, 42)
                    .onChange(of: showActivity) { _, shown in
                        if shown { Task { await spark.loadActivity(box) } }
                    }
                } else {
                    Text("Update this box's Spark Swapper to \(SwapperVersion.contextAndPictures) or later (its web page ▸ Settings ▸ Update now) to choose the context window, switch pictures on or off, and see its activity from here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 42)
                }
            }
        }
        .padding(12)
        .alert("Serve \(windowChange?.model.title ?? "") with \(windowChange?.choice.name ?? "")?",
               isPresented: Binding(get: { windowChange != nil }, set: { if !$0 { windowChange = nil } })) {
            Button(windowChange?.restarts == true ? "Restart It" : "Save") {
                if let change = windowChange {
                    Task { await spark.setContext(box, model: change.model.key, tokens: change.choice.tokens) }
                }
                windowChange = nil
            }
            Button("Cancel", role: .cancel) { windowChange = nil }
        } message: {
            Text(windowChangeMessage)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        .alert("Rename \(box.name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { spark.rename(box, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(box.name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { spark.remove(box) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vision forgets the box and its sign-in. Routes made for it stay in Settings ▸ AI Models. The box still lists this app's connection: revoke it on the Swapper's Connect tab if you won't use it again.")
        }
        .alert("Switch \(box.name) to \(pending?.title ?? "")?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Switch") {
                if let target = pending { Task { await spark.swap(box, to: target.key) } }
                // (A failure shows on this row: the box's error line, or `actionError` when the box said no.)
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The current model stops and \(pending?.title ?? "the new one") loads (\(pending?.switchDuration ?? "a few minutes")). Chats follow automatically.")
        }
    }

    private var dotColor: Color {
        if box.isOnline { return Theme.successTint }
        if box.lastError != nil { return Theme.errorTint }
        return .secondary
    }

    @ViewBuilder
    private func modelRow(_ m: SwapperStatus.Model, status: SwapperStatus) -> some View {
        let spark = model.spark
        HStack(alignment: .top) {
            Image(systemName: m.key == status.active ? "checkmark.circle.fill" : m.isInstalled ? "circle" : "arrow.down.circle")
                .foregroundStyle(m.key == status.active ? Theme.successTint : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(m.title).font(.callout)
                    if !m.isInstalled {
                        Text("Not installed")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.surfaceStrong, in: Capsule())
                    }
                }
                Text(([m.served_id, "\(ModelSizes.short(m.window)) context", m.speedText(roomForEstimate: true)]
                      .compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !m.isInstalled, let install = m.install?.summary {
                    Text("Install: \(install)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.isInstalled, !m.contextChoices.isEmpty {
                    // The windows the box can serve it with (Swapper 2.2): picking one asks first.
                    Menu {
                        ForEach(m.contextChoices) { choice in
                            Button {
                                windowChange = WindowChange(model: m, choice: choice, restarts: m.key == status.active)
                            } label: {
                                Text(choice.detail.map { "\(choice.name) — \($0)" } ?? choice.name)
                            }
                            .disabled(choice.tokens == m.window)
                        }
                    } label: {
                        Text("Context window: \(ModelSizes.short(m.window))").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(status.isSwitching || box.working != nil)
                    .help("Serve this model with a different context window")
                }
            }
            Spacer()
            if m.key == status.active {
                Text("Serving now").font(.caption).foregroundStyle(.secondary)
            } else if m.isInstalled {
                Button(box.justInstalled.contains(m.key) ? "Switch to It" : "Switch") { pending = m }
                    .controlSize(.small)
                    .disabled(status.isSwitching)
            } else if box.installingKey == m.key {
                ProgressView().controlSize(.small)
            } else if m.install != nil {
                Button("Install on \(box.name)") { Task { await spark.install(m.key, on: box) } }
                    .controlSize(.small)
                    .disabled(box.installingKey != nil)
                    .help("Downloads and sets the model up on the box. One install runs at a time.")
            }
        }
    }
}

/// Add a model to a box from a Hugging Face link: check it first (what it is, how big, whether this box can run
/// it — nothing is downloaded), then add it, which starts its install. The box decides how to run it; extra
/// launch arguments and remote code stay with the Swapper's own page.
struct SwapperAddModelForm: View {
    @Environment(AppModel.self) private var model
    let box: SwapperBox
    @State private var link = ""
    @State private var working: String?
    @State private var found: SwapperHFInspection?
    /// The link `found` is about (the field may have been edited since).
    @State private var foundLink = ""
    @State private var problem: String?
    @State private var done: String?

    private var trimmed: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Link", text: $link, prompt: Text("https://huggingface.co/owner/model  or  owner/model"))
                    .font(Theme.mono(11))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await check() } }
                Button(working ?? "Check") { Task { await check() } }
                    .controlSize(.small)
                    .disabled(working != nil || trimmed.isEmpty)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Theme.errorTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let done {
                Text(done).font(.caption).foregroundStyle(Theme.successTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let found, foundLink == trimmed {
                Text(found.report())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if found.canRun, found.catalog_key?.value == nil {
                    Button("Add and Install on \(box.name)") { Task { await add() } }
                        .controlSize(.small)
                        .disabled(working != nil || box.installingKey != nil)
                        .help(box.installingKey != nil ? "Another install is running on this box. One runs at a time."
                                                       : "Downloads the model to the box and sets it up. This can take a while.")
                }
            }
            Text("Needs a connection made by an admin of the box. Gated models also need a Hugging Face token saved on the Swapper's Settings tab.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check() async {
        let asked = trimmed
        guard !asked.isEmpty, working == nil else { return }
        working = "Checking…"
        defer { working = nil }
        problem = nil
        done = nil
        found = nil
        let result = await model.spark.inspectHuggingFace(asked, on: box)
        found = result.found
        foundLink = asked
        problem = result.problem
    }

    private func add() async {
        let asked = trimmed
        guard !asked.isEmpty, working == nil else { return }
        working = "Adding…"
        defer { working = nil }
        problem = nil
        let result = await model.spark.addHuggingFace(asked, on: box)
        if let added = result.added {
            done = added.note ?? "Added as “\(found?.title ?? added.key)”. It is downloading now — the install shows above, and the chat is told when it is ready to switch to."
            found = nil
            link = ""
        } else {
            problem = result.problem
        }
    }
}

/// The address-and-login form, for a Swapper older than 2.0 (or no code to hand). On a Swapper 2.0 Vision makes an
/// app token with the login and keeps that instead of the password.
struct SwapperLoginForm: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var working = false
    @State private var untrusted: String?
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Address", text: $address, prompt: Text("https://192.168.1.42:8999"))
                .font(Theme.mono(11))
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $user).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $pass).textFieldStyle(.roundedBorder)
            if let fp = untrusted {
                Text("The Swapper uses a self-signed certificate. Trust it if this fingerprint matches the box's (`sudo openssl x509 -in /etc/spark-swapper/tls.crt -noout -fingerprint -sha256`):")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(fp).font(Theme.mono(10)).textSelection(.enabled)
            }
            HStack {
                Button(working ? "Connecting…" : untrusted == nil ? "Connect" : "Trust and Connect") {
                    Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || pass.isEmpty)
                if let message {
                    Text(message).font(.caption)
                        .foregroundStyle(failed ? Theme.errorTint : Theme.successTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("The login you created on the Swapper's web page. On Swapper 2.0 Vision keeps an app token instead of your password; on an older Swapper the password is kept in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        message = nil
        failed = false
        do {
            let outcome = try await SwapperConnect.login(address: address, username: user.trimmingCharacters(in: .whitespaces),
                                                         password: pass, pinned: untrusted)
            switch outcome {
            case .needsTrust(let fingerprint):
                untrusted = fingerprint
            case .connected(let connection, let password, _, _):
                // Connecting is keeping it: on a Swapper 2.0 that makes this app's token, kept instead of the password.
                let kept = try await SwapperConnect.keep(connection, password: password,
                                                         label: SwapperConnect.tokenLabel(computerName: ComputerName.current))
                let box = model.spark.add(kept.connection, secret: kept.secret)
                await model.spark.refresh(box)
                model.spark.startMonitoring()
                message = "Connected to \(box.name)."
                untrusted = nil
                pass = ""
            }
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

/// This Mac's name ("Pat's MacBook"), as the Sharing settings show it.
enum ComputerName {
    static var current: String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}
