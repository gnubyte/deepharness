import SwiftUI
import AppKit
import DSHCore

/// The Amazon Bedrock guide as a sheet: a header that says where you are, the current page, and Back /
/// Next. The pages are rebuilt from `BedrockGuideModel`'s state.
struct BedrockGuideView: View {
    let appModel: AppModel
    @State private var guide: BedrockGuideModel
    @Environment(\.dismiss) private var dismiss

    init(request: BedrockGuideRequest, appModel: AppModel) {
        self.appModel = appModel
        _guide = State(initialValue: BedrockGuideModel(backend: LiveBedrockBackend(appModel: appModel), config: appModel.config,
                                                       start: request.page, route: request.route))
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
        .frame(width: 780, height: 640)
        .onAppear {
            guide.onSaved = { _ in appModel.transport.resetRouteCache() }
            guide.onFinish = {
                appModel.mode = .chat
                if appModel.selectedSession == nil { appModel.newChat() }
                dismiss()
            }
            guide.onLeave = { dismiss() }
            guide.activate()
        }
        .onDisappear { guide.dispose() }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(BedrockPage.allCases, id: \.rawValue) { entry in
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
            Button(guide.page == .welcome ? "Cancel" : "Back") { guide.back() }
                .keyboardShortcut(.cancelAction)
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
        case .welcome: WelcomePage()
        case .cli: CLIPage(guide: guide)
        case .signIn: SignInPage(guide: guide)
        case .model: ModelPage(guide: guide)
        case .access: AccessPage(guide: guide)
        case .connect: ConnectPage(guide: guide)
        case .done: DonePage(guide: guide)
        }
    }
}

// MARK: - Welcome

struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GuideIcon(systemName: "cloud.bolt")
            GuideHeading("Use models from Amazon Bedrock")
            GuideLead("Amazon Bedrock runs models like Claude, Amazon Nova, Llama and Mistral in your own AWS account. You pay AWS for what you use — there's no subscription to DSH or anyone else.")
            GuideSubheading("What you need")
            GuideBullets(items: [
                ("cloud", "An **AWS account** you can sign in to on the AWS website. No account yet? Create one at aws.amazon.com — it needs a payment card."),
                ("stopwatch", "About **5 minutes**. A model sold through AWS Marketplace can take up to 15 more the first time."),
                ("laptopcomputer", "This Mac. DSH installs the one tool it needs, the **AWS CLI**, if it isn't here yet."),
            ])
            GuideSubheading("What DSH does for you")
            GuideSteps(items: [
                "Installs Amazon's **AWS CLI** — or updates it — if needed.",
                "Opens your **browser to sign in** to AWS. DSH never sees your password.",
                "Shows the **models** in your Region and what each one needs before first use.",
                "Fills in or accepts what's needed — **with you**: Anthropic's one-time form for Claude, or a model's **terms and price**.",
                "Saves the connection and says **hello** through Bedrock.",
            ])
            GuideAside("DSH talks to Bedrock directly from this Mac with short-lived credentials from your sign-in, which the AWS CLI refreshes by itself. Nothing is stored in DSH's settings but the name of the sign-in (an AWS CLI \"profile\") and the Region.")
            GuideStuck("Your company manages AWS for you? You can still use this guide: sign in the way your company told you to (often \"IAM Identity Center\" — the guide handles that too). If a step says you're not allowed, it shows exactly what to ask your administrator for.")
        }
    }
}

// MARK: - The AWS CLI

struct CLIPage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "terminal")
            GuideHeading("One tool first: the AWS CLI")
            GuideLead("The AWS CLI is Amazon's official command-line tool. DSH uses it for two things only: signing you in, and setting up your account for Bedrock.")
            content
            GuideAside("\"CLI\" means command-line interface: a program you'd normally type commands into. You won't have to — DSH runs it for you in the background. It stays installed, and running this guide again updates it.")
            GuideStuck("Your Mac won't allow installers? Ask your IT team to install \"AWS CLI version 2\", then press Check again. Already installed it somewhere unusual? DSH looks in the usual places and on your PATH.")
            if !guide.installing && !guide.checkingCLI && guide.cliStatus?.isReady != true {
                GuideLink("Check again") { guide.recheckCLI() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if guide.checkingCLI {
            GuideBusy("Looking for the AWS CLI on this Mac…")
        } else if guide.installing {
            installing
        } else {
            switch guide.cliStatus {
            case .ready(_, _)?:
                GuideNote(.success, guide.installOutcome?.succeeded == true ? "Installed. \(guide.cliStatus?.summary ?? "")" : (guide.cliStatus?.summary ?? ""))
            case .tooOld?:
                GuideNote(.warning, guide.cliStatus?.summary ?? "")
                installButtons("Update the AWS CLI")
            case .broken?:
                GuideNote(.warning, guide.cliStatus?.summary ?? "")
                installButtons("Reinstall the AWS CLI")
            default:
                GuideNote(.info, "The AWS CLI isn't installed on this Mac yet. DSH can install it now: it downloads Amazon's official installer, checks it's signed by Amazon, and installs it just for you — no administrator needed.")
                installButtons("Install the AWS CLI")
            }
            if let failed = guide.installOutcome, !failed.succeeded {
                GuideNote(failed.cancelled ? .info : .error, failed.message, title: failed.cancelled ? nil : "The install didn't finish") {
                    if failed.canTryHomebrew && guide.backend.homebrewAvailable {
                        Button("Try installing with Homebrew") { guide.installCLI(scope: .homebrew) }.controlSize(.small)
                    }
                }
                if let log = failed.logPath { GuideCopyable(text: log, caption: "Installer log") }
            }
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 8) {
            let progress = guide.installProgress
            GuideBusy(progress?.stage ?? "Working…")
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail = progress?.detail, !detail.isEmpty { GuideParagraph(detail, secondary: true) }
            GuideNote(.info, "macOS may ask whether to allow the installer. Choose Allow.")
            Button("Stop") { guide.stopInstalling() }
        }
    }

    @ViewBuilder
    private func installButtons(_ label: String) -> some View {
        if let problem = guide.backend.installProblem {
            GuideNote(.error, problem)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button(label) { guide.installCLI() }.buttonStyle(.borderedProminent)
                GuideLink("Install for everyone on this Mac instead (asks for your password)") { guide.installCLI(scope: .allUsers) }
                if guide.backend.homebrewAvailable {
                    GuideLink("Install with Homebrew instead") { guide.installCLI(scope: .homebrew) }
                }
            }
        }
    }
}

// MARK: - Signing in

struct SignInPage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        let profiles = guide.backend.awsProfiles()
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "person.badge.key")
            GuideHeading("Sign in to AWS")
            GuideLead("DSH asks the AWS CLI to open your browser at AWS's own sign-in page — the same one as the AWS website. Sign in there and come back; DSH never sees your password.")

            GuideField(label: "AWS Region",
                       hint: "Where your requests run. Models differ by Region — US East (N. Virginia) and US West (Oregon) have the most. Pick one near you if you're unsure.") {
                RegionPicker(guide: guide).disabled(guide.signingIn)
            }

            GuideSubheading("How do you sign in to AWS?")
            GuideChoice(systemImage: "globe", title: "With my AWS account in the browser (recommended)",
                        detail: "Your AWS email or IAM user and password, exactly as on the AWS website. DSH keeps this sign-in under the name \"\(AWSSignIn.defaultProfile)\".",
                        selected: !guide.useExisting) { guide.setUseExisting(false) }
            GuideChoice(systemImage: "person.2", title: "My company's sign-in, or an AWS CLI profile I already have",
                        detail: profiles.isEmpty
                            ? "No AWS CLI profiles on this Mac yet. If your company uses IAM Identity Center (SSO), ask it for the setup steps, or use the browser option."
                            : "IAM Identity Center (SSO), access keys or a role that's already set up in the AWS CLI on this Mac.",
                        selected: guide.useExisting, enabled: !profiles.isEmpty) { guide.setUseExisting(true) }
            if guide.useExisting, !profiles.isEmpty {
                GuideField(label: "Profile") {
                    Picker("", selection: Binding(get: { guide.existingProfile ?? profiles[0].name },
                                                  set: { guide.setExistingProfile($0) })) {
                        ForEach(profiles, id: \.name) { profile in
                            Text("\(profile.name) — \(profile.kindDescription)\(profile.region.map { ", \($0)" } ?? "")").tag(profile.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .disabled(guide.signingIn)
                }
            }

            state(profiles: profiles)

            if let error = guide.signInError, !guide.signingIn {
                GuideNote(.error, error, title: "Not signed in") {
                    if let details = guide.signInDetails, !details.isEmpty { GuideParagraph(details, secondary: true) }
                }
            }
            if !guide.signInLog.isEmpty {
                DisclosureGroup("What the AWS CLI said") {
                    Text(guide.signInLog)
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            GuideAside("The AWS CLI signs you in with \"aws login\": after you sign in in the browser, it keeps a session on this Mac and swaps it for fresh, short-lived keys whenever DSH needs them. When the session ends (like signing out of the AWS website), DSH asks you to sign in again — one click.")
            GuideStuck("The browser didn't open? Use the link above. It says you're not allowed? Your AWS administrator needs to give your user the \"\(BedrockPermissions.signInManagedPolicy)\" permission (an AWS managed policy). Using the account's root email works, but AWS recommends an everyday IAM user or IAM Identity Center.")
        }
    }

    @ViewBuilder
    private func state(profiles: [AWSProfile]) -> some View {
        if let identity = guide.identity, !guide.signingIn {
            GuideNote(.success, identity.description, title: "Signed in")
            GuideLink("Sign in as someone else") { guide.signIn() }
        } else if guide.verifying {
            GuideBusy("Checking whether you're already signed in…")
        } else if guide.signingIn {
            GuideBusy(guide.remote
                      ? "Open the link below on a device with a browser, sign in, then paste the code AWS shows you."
                      : "Your browser opened the AWS sign-in page. Sign in there, then come back here — this page updates by itself.")
            if let link = guide.signInLink {
                GuideLink("Didn't see it? Open the sign-in page again") { guide.backend.open(link.url) }
                if let code = link.userCode, !code.isEmpty { GuideCopyable(text: code, caption: "Code to confirm in the browser") }
                if guide.remote { GuideCopyable(text: link.url.absoluteString, caption: "Sign-in link") }
            }
            if guide.awaitingCode {
                GuideField(label: "Authorization code") {
                    HStack {
                        TextField("Paste the authorization code here", text: $guide.authorizationCode)
                            .font(Theme.mono(12))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { guide.submitCode() }
                        Button("Continue") { guide.submitCode() }
                            .buttonStyle(.borderedProminent)
                            .disabled(guide.authorizationCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            Button("Stop") { guide.stopSignIn() }
        } else {
            let selfSigned = guide.useExisting && [.accessKeys, .assumeRole, .credentialProcess, .webIdentity]
                .contains(profiles.first { $0.name == guide.profileName }?.kind)
            Button(selfSigned ? "Check this profile" : "Sign in with AWS") { guide.signIn() }
                .buttonStyle(.borderedProminent)
            if !guide.useExisting {
                Toggle("My browser is on another computer (show a link and a code instead)", isOn: $guide.remote)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
    }
}

/// The AWS Region popup, shared by the sign-in and model pages.
struct RegionPicker: View {
    @Bindable var guide: BedrockGuideModel
    var body: some View {
        Picker("AWS Region", selection: Binding(get: { guide.region }, set: { guide.setRegion($0) })) {
            ForEach(BedrockRegions.common) { choice in Text(choice.display).tag(choice.code) }
            if !BedrockRegions.common.contains(where: { $0.code == guide.region }) {
                Text(guide.region).tag(guide.region)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
    }
}
