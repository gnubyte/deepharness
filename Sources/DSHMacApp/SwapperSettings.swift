import SwiftUI
import AppKit
import SystemConfiguration
import DSHCore

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
                    }
                    Text(box.summary).font(.caption).foregroundStyle(.secondary)
                    Text(box.servingLine)
                        .font(.caption)
                        .foregroundStyle(box.lastError == nil ? Color.secondary : Theme.errorTint)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
        }
        .padding(12)
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
            Text("DSH forgets the box and its sign-in. Routes made for it stay in Settings ▸ AI Models. The box still lists this app's connection: revoke it on the Swapper's Connect tab if you won't use it again.")
        }
        .alert("Switch \(box.name) to \(pending?.title ?? "")?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Switch") {
                if let target = pending { Task { await spark.swap(box, to: target.key) } }
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

/// The address-and-login form, for a Swapper older than 2.0 (or no code to hand). On a Swapper 2.0 DSH makes an
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
            Text("The login you created on the Swapper's web page. On Swapper 2.0 DSH keeps an app token instead of your password; on an older Swapper the password is kept in your Keychain.")
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
                                                         password: pass, pinned: untrusted,
                                                         label: SwapperConnect.tokenLabel(computerName: ComputerName.current))
            switch outcome {
            case .needsTrust(let fingerprint):
                untrusted = fingerprint
            case .connected(let connection, let secret, _, _):
                let box = model.spark.add(connection, secret: secret)
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
