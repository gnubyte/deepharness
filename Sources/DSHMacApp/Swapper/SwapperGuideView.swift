import SwiftUI
import AppKit
import DSHCore

/// The "Connect my Spark Swapper" guide as a sheet: where you are, the page, Back / Next.
struct SwapperGuideView: View {
    let appModel: AppModel
    @State private var guide: SwapperGuideModel
    @Environment(\.dismiss) private var dismiss

    init(request: SwapperGuideRequest, appModel: AppModel) {
        self.appModel = appModel
        _guide = State(initialValue: SwapperGuideModel(backend: LiveSwapperBackend(appModel: appModel), config: appModel.config))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                page
                    .padding(28)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .onAppear {
            guide.onSaved = { _ in appModel.transport.resetRouteCache() }
            guide.onFinish = {
                appModel.config.wizardCompleted = true
                appModel.mode = .chat
                if appModel.selectedSession == nil { appModel.newChat() }
                dismiss()
            }
            guide.onLeave = { dismiss() }
        }
        .onDisappear { guide.dispose() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(SwapperPage.allCases, id: \.rawValue) { entry in
                    Capsule()
                        .fill(entry.rawValue <= guide.page.rawValue ? Color.accentColor : Theme.hairline)
                        .frame(height: 3)
                }
            }
            HStack {
                Text(guide.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(guide.stepText).font(Theme.metaFont).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button(guide.page == .code ? "Cancel" : "Back") { guide.back() }
                .keyboardShortcut(.cancelAction)
                .disabled(guide.page == .done && guide.saving)
            Spacer()
            Button(guide.nextLabel) { guide.next() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!guide.canAdvance)
        }
        .padding(14)
    }

    @ViewBuilder
    private var page: some View {
        switch guide.page {
        case .code: SwapperCodePage(guide: guide)
        case .check: SwapperCheckPage(guide: guide)
        case .model: SwapperModelPage(guide: guide)
        case .use: SwapperUsePage(guide: guide)
        case .done: SwapperDonePage(guide: guide)
        }
    }
}

// MARK: - 1. The code

struct SwapperCodePage: View {
    @Bindable var guide: SwapperGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "server.rack")
            GuideHeading("Connect my Spark Swapper")
            GuideLead("Your DGX Spark or Strix Halo runs Spark Swapper, which switches the model it serves. One code from its web page sets up the model, switching, and the security certificate in one go.")
            if guide.usesLogin {
                GuideField(label: "Address", hint: "The Swapper's web page, like https://192.168.1.42:8999. A bare name or IP is fine.") {
                    TextField("https://192.168.1.42:8999", text: $guide.address)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(12))
                }
                GuideField(label: "Username") {
                    TextField("", text: $guide.username).textFieldStyle(.roundedBorder)
                }
                GuideField(label: "Password", hint: "The login you made on the Swapper's web page. On Swapper 2.0 DSH makes its own app token with it and keeps that instead of your password.") {
                    SecureField("", text: $guide.password).textFieldStyle(.roundedBorder)
                }
                GuideLink("Use a connection code instead") { guide.usesLogin = false }
            } else {
                GuideField(label: "Connection code") {
                    TextEditor(text: $guide.codeText)
                        .font(Theme.mono(11))
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                }
                if let problem = guide.codeProblem {
                    GuideNote(.warning, problem)
                } else if let code = guide.code {
                    GuideNote(.success, "A code for \(code.name).")
                }
                GuideParagraph("Where do I find it? Open your Swapper's web page (https://<box>:8999), choose **Connect**, then **Connect DSH**, and copy the code.", secondary: true)
                GuideLink("Use an address and login instead") { guide.usesLogin = true }
            }
            GuideAside("The code holds the box's addresses, its model API key, an app token just for DSH, and the fingerprint of its security certificate. The token and key go to your Keychain.")
        }
    }
}

// MARK: - 2. Check it

struct SwapperCheckPage: View {
    @Bindable var guide: SwapperGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "checkmark.shield")
            GuideHeading("Check it")
            GuideLead("DSH reaches the box over HTTPS, makes sure it shows the certificate the code names, and asks what it is serving.")
            if guide.checking {
                GuideBusy("Connecting…")
            } else if let fingerprint = guide.untrustedFingerprint {
                GuideNote(.info, "The Swapper uses its own (self-signed) certificate. Trust it only if this fingerprint matches the one on its web page, or the box's own (`sudo openssl x509 -in /etc/spark-swapper/tls.crt -noout -fingerprint -sha256`).", title: "Is this your box?") {
                    Text(fingerprint).font(Theme.mono(10)).textSelection(.enabled)
                    Button("Trust This Certificate and Sign In") { guide.trustCertificate() }
                        .buttonStyle(.borderedProminent)
                }
            } else if let error = guide.checkError {
                GuideNote(.error, error, title: "Not connected") {
                    Button("Try Again") { guide.runCheck() }
                }
            } else if let line = guide.connectedLine {
                GuideNote(.success, line)
            }
            GuideStuck("It can't reach the box? Check the box is switched on and this Mac is on the same network (or the same Tailscale). It says the certificate is different? If you reinstalled the Swapper, copy a fresh code.")
        }
    }
}

// MARK: - 3. The model

struct SwapperModelPage: View {
    @Bindable var guide: SwapperGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "cpu")
            GuideHeading("Pick the model")
            GuideLead("These are the models installed on \(guide.boxName). The one serving now is picked; choose another to switch the box to it.")
            if let status = guide.status {
                ForEach(status.installedModels) { m in
                    GuideChoice(systemImage: m.key == status.active ? "bolt.fill" : "cpu",
                                title: m.title + (m.key == status.active ? " — Serving now" : ""),
                                detail: detail(m),
                                selected: guide.selectedKey == m.key,
                                enabled: !guide.switching && guide.installing == nil) { guide.choose(m.key) }
                }
                let missing = status.ordered.filter { !$0.isInstalled }
                if !missing.isEmpty {
                    GuideSubheading("Not installed yet")
                    ForEach(missing) { m in notInstalled(m) }
                }
            }
            if let progress = guide.installProgress() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        GuideBusy(guide.installProgress(at: context.date) ?? progress)
                        if let line = guide.installLine {
                            Text(line).font(Theme.mono(10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            if let error = guide.installError {
                GuideNote(.error, error)
            }
            if guide.switching {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    GuideBusy("Switching \(guide.boxName) to \(guide.selectedModel?.title ?? "the model") · \(guide.switchStep ?? "Working") · \(guide.switchElapsed(at: context.date))")
                }
            } else if guide.needsSwitch, let target = guide.selectedModel, guide.installing == nil {
                VStack(alignment: .leading, spacing: 8) {
                    if guide.installed.contains(target.key) {
                        GuideNote(.success, "\(target.title) is installed on \(guide.boxName).")
                        Button("Switch to It (takes \(target.switchDuration))") { guide.switchNow() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Switch \(guide.boxName) to \(target.title) now (takes \(target.switchDuration))") { guide.switchNow() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let current = guide.servingModel {
                        GuideLink("Keep \(current.title)") { guide.keepCurrent() }
                    }
                }
            }
            if let error = guide.switchError {
                GuideNote(.error, error)
            }
            GuideAside("You can switch any time later: the model menu under the composer lists what each box can serve, and /swap does it from the chat.")
        }
    }

    private func detail(_ m: SwapperStatus.Model) -> String {
        ([m.tagline.flatMap { $0.isEmpty ? nil : $0 }, "\(ModelSizes.short(m.window)) context", m.speedText(roomForEstimate: true)]
            .compactMap { $0 }).joined(separator: " · ")
    }

    /// A model the box doesn't have yet: what it is, what installing it takes, and a button to do it.
    private func notInstalled(_ m: SwapperStatus.Model) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.title).font(.callout.weight(.medium))
                    Text("Not installed")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surfaceStrong, in: Capsule())
                }
                Text(detail(m)).font(.caption).foregroundStyle(.secondary)
                if let install = m.install?.summary {
                    Text("Install: \(install)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if m.install != nil {
                Button("Install on \(guide.boxName)") { guide.install(m.key) }
                    .controlSize(.small)
                    .disabled(guide.installing != nil || guide.switching)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}

// MARK: - 4. How DSH uses it

struct SwapperUsePage: View {
    @Bindable var guide: SwapperGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "person.3")
            GuideHeading("How should DSH use it?")
            ForEach(ModelRole.allCases) { role in
                GuideChoice(systemImage: role.icon, title: role.title, detail: role.detail,
                            selected: guide.role == role) { guide.role = role }
            }
            GuideSubheading("Privacy")
            Toggle(isOn: $guide.isPrivate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private — your own hardware").font(.callout.weight(.medium))
                    Text("It may see everything in your chats, sensitive details included. Models that aren't private get those details masked.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            GuideAside("You can change all of this later in Settings ▸ AI Models.")
        }
    }
}

// MARK: - 5. Save and say hello

struct SwapperDonePage: View {
    @Bindable var guide: SwapperGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "checkmark.circle")
            GuideHeading("Save and say hello")
            if let route = guide.saved {
                GuideNote(.success, "Saved \(route.name) — \(route.model) at \(route.baseURL), with its key in your Keychain and its certificate trusted.")
            }
            if guide.saving {
                GuideBusy("Sending a first message…")
            } else if let hello = guide.hello {
                GuideNote(.success, hello, title: "\(guide.boxName) answered")
            } else if let error = guide.helloError {
                GuideNote(.error, error, title: "The first message didn't go through") {
                    Button("Try Again") { guide.sayHello() }
                }
            }
            GuideBullets(items: [
                ("arrow.triangle.swap", "**Switch models** from the model menu under the composer, or with `/swap`."),
                ("server.rack", "**Settings ▸ Model Servers** lists your boxes; **Settings ▸ AI Models** decides who answers, who helps, and who is private."),
            ])
        }
    }
}

// MARK: - The live backend

/// The real `SwapperGuideBackend`: the network, the app's settings and its Swapper boxes.
@MainActor
final class LiveSwapperBackend: SwapperGuideBackend {
    private let appModel: AppModel

    init(appModel: AppModel) { self.appModel = appModel }

    func check(_ code: SwapperConnectionCode) async throws -> SwapperStatus {
        try await SwapperConnect.check(code)
    }

    func login(address: String, username: String, password: String, pinned: String?) async throws -> SwapperConnect.LoginOutcome {
        try await SwapperConnect.login(address: address, username: username, password: password, pinned: pinned,
                                       label: SwapperConnect.tokenLabel(computerName: ComputerName.current))
    }

    func status(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus {
        try await client(connection, secret).status()
    }

    func swap(_ connection: SwapperConnection, secret: String, to key: String) async throws {
        try await client(connection, secret).swap(to: key)
    }

    func install(_ connection: SwapperConnection, secret: String, key: String) async throws -> SwapperStatus.Job? {
        try await client(connection, secret).installModel(key)
    }

    func installJob(of connection: SwapperConnection, secret: String) async throws -> SwapperStatus.Job? {
        try await client(connection, secret).provisioningJob()
    }

    private func client(_ connection: SwapperConnection, _ secret: String) throws -> SparkSwapperClient {
        guard let url = URL(string: connection.url) else { throw SwapperError.notConfigured }
        let auth: SwapperAuth
        switch connection.auth {
        case .token: auth = .token(secret)
        case .login(let user): auth = .login(username: user, password: secret)
        }
        return SparkSwapperClient(baseURL: url, auth: auth, pinnedFingerprint: connection.pinnedFingerprint)
    }

    func sayHello(route: ProviderProfile) async throws -> String {
        try await GuideHello.say(through: route,
                                 prompt: "Say hello to someone who just connected their coding app to their own model server, in one short, friendly sentence.")
    }

    func register(_ connection: SwapperConnection, secret: String, route: ProviderProfile) {
        let box = appModel.spark.add(connection, secret: secret)
        appModel.spark.link(route, to: box)
        appModel.spark.startMonitoring()
        Task { await appModel.spark.refresh(box) }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// "Say hello" through a route: one short reply, or a plain error after two minutes.
enum GuideHello {
    static func say(through route: ProviderProfile, prompt: String) async throws -> String {
        let client = ProviderClients.make(route)
        // Thinking off (a model that always thinks gets its lightest setting), and room for a reasoning model's
        // thoughts before the sentence.
        let request = LLMRequest(systemPrompt: "You are a helpful assistant.", messages: [.user(prompt)],
                                 tools: [], model: route.model, temperature: 0.3, maxTokens: 1_000, thinking: .off)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var reply = ""
                for try await event in client.stream(request) {
                    if case .text(let delta) = event { reply += delta }
                }
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "(The model answered with an empty reply.)" : text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                throw LLMError.connection("no answer within 120 s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
