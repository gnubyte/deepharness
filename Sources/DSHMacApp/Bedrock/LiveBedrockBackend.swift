import Foundation
import AppKit
import DSHCore

/// The real `BedrockGuideBackend`: the AWS CLI on this Mac, AWS itself, and the app's vault and browser.
@MainActor
final class LiveBedrockBackend: BedrockGuideBackend {
    private let appModel: AppModel
    /// The CLI found by the last check (or installed since).
    private var cli: AWSCLI?
    private let installer = AWSCLIInstaller()

    init(appModel: AppModel) { self.appModel = appModel }

    private func requireCLI() throws -> AWSCLI {
        if let cli { return cli }
        // Installed since the last check?
        if let found = AWSAccounts.cli() {
            cli = found
            return found
        }
        throw AWSCLIException(AWSCLIError(kind: .notSupported, message: "The AWS CLI isn't installed yet."))
    }

    // MARK: The AWS CLI

    func checkCLI() async -> AWSCLIStatus {
        let status = await AWSCLI.check()
        cli = AWSCLI.from(ready: status)
        return status
    }

    var installProblem: String? { installer.platformProblem }
    var homebrewAvailable: Bool { installer.homebrewAvailable }

    func installCLI(scope: CLIInstallScope, current: AWSCLIStatus?,
                    progress: @escaping @Sendable (CLIInstallProgress) -> Void) async -> CLIInstallOutcome {
        let report: @Sendable (AWSCLIInstallProgress) -> Void = { step in
            progress(CLIInstallProgress(stage: step.stage, fraction: step.fraction, detail: step.detail))
        }
        do {
            let result: AWSCLIInstallResult
            switch scope {
            case .homebrew:
                result = try await installer.installWithHomebrew(current: current, progress: report)
            case .allUsers:
                result = try await installer.install(scope: .allUsers, progress: report)
            case .currentUser:
                switch current {
                case .tooOld?, .broken?: result = try await installer.upgrade(current!, progress: report)
                default: result = try await installer.install(scope: .currentUser, progress: report)
                }
            }
            if result.succeeded {
                let status: AWSCLIStatus
                if let known = result.cli { status = known } else { status = await AWSCLI.check() }
                cli = AWSCLI.from(ready: status)
            }
            return CLIInstallOutcome(succeeded: result.succeeded, cancelled: result.outcome == .cancelled,
                                     message: result.message, status: result.cli,
                                     canTryHomebrew: result.canTryHomebrew && installer.homebrewAvailable,
                                     logPath: result.logPath)
        } catch is CancellationError {
            return CLIInstallOutcome(succeeded: false, cancelled: true, message: "Stopped. Nothing was installed.")
        } catch {
            return CLIInstallOutcome(succeeded: false, message: error.localizedDescription,
                                     canTryHomebrew: installer.homebrewAvailable)
        }
    }

    // MARK: Profiles and sign-in

    func awsProfiles() -> [AWSProfile] { AWSProfiles.load().profiles }
    func defaultRegion() -> String? { AWSProfiles.load().defaultRegion }

    func verify(profile: String, region: String) async throws -> AWSCallerIdentity {
        try await AWSSignIn(cli: requireCLI()).verify(profile: profile, region: region)
    }

    private func options(remote: Bool, _ callbacks: SignInCallbacks) -> AWSSignInOptions {
        AWSSignInOptions(remote: remote,
                         onOutput: callbacks.onOutput,
                         onSignInLink: callbacks.onLink,
                         requestAuthorizationCode: { link in await callbacks.requestCode(link) })
    }

    func login(profile: String, region: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        try await AWSSignIn(cli: requireCLI()).login(profile: profile, region: region, options: options(remote: remote, callbacks))
    }

    func ssoLogin(profile: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        try await AWSSignIn(cli: requireCLI()).ssoLogin(profile: profile, options: options(remote: remote, callbacks))
    }

    func invalidateCredentials(profile: String) { AWSAccounts.invalidate(profile) }

    // MARK: Bedrock

    private func setup(_ profile: String, _ region: String) throws -> BedrockSetup {
        // (BedrockSetup traps on a blank profile or Region: never hand it one.)
        BedrockSetup(cli: try requireCLI(),
                     profile: profile.trimmingCharacters(in: .whitespaces).isEmpty ? AWSSignIn.defaultProfile : profile,
                     region: region.trimmingCharacters(in: .whitespaces).isEmpty ? BedrockRegions.defaultRegion : region)
    }

    func listModels(profile: String, region: String) async throws -> [BedrockModel] {
        try await setup(profile, region).listModels()
    }

    func checkAccess(profile: String, region: String, model: BedrockModel) async throws -> ModelAccess {
        try await setup(profile, region).checkAccess(model)
    }

    func submitUseCase(profile: String, region: String, answers: UseCaseAnswers) async throws -> UseCaseOutcome {
        let audience: UseCaseAudience = switch answers.audience {
        case .company: .internal
        case .customers: .external
        case .both: .both
        }
        let form = UseCaseForm(companyName: answers.company.trimmingCharacters(in: .whitespaces),
                               companyWebsite: answers.website.trimmingCharacters(in: .whitespaces),
                               industry: answers.industry,
                               useCases: answers.useCases.trimmingCharacters(in: .whitespaces),
                               intendedUsers: audience,
                               otherIndustry: answers.industry == "Other" ? answers.otherIndustry.trimmingCharacters(in: .whitespaces) : "")
        return try await setup(profile, region).submitUseCase(form) == .alreadyOnFile ? .alreadyOnFile : .submitted
    }

    func acceptAgreement(profile: String, region: String, modelID: String, offerToken: String) async throws {
        try await setup(profile, region).acceptAgreement(modelID: modelID, offerToken: offerToken)
    }

    func waitUntilReady(profile: String, region: String, model: BedrockModel,
                        progress: @escaping @Sendable (ModelAccess) -> Void) async throws -> ModelAccess {
        try await setup(profile, region).waitUntilReady(model, progress: progress)
    }

    // MARK: Connecting

    func sayHello(route: ProviderProfile) async throws -> String {
        let client = ProviderClients.make(route)
        let request = LLMRequest(systemPrompt: "You are a helpful assistant.",
                                 messages: [.user("Say hello to someone who just connected their coding app to Amazon Bedrock, in one short, friendly sentence.")],
                                 tools: [], model: route.model, temperature: 0.3, maxTokens: 200, thinking: ThinkingLevel.off)
        return try await Self.withTimeout(seconds: 120) {
            var reply = ""
            for try await event in client.stream(request) {
                if case .text(let delta) = event { reply += delta }
            }
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "(The model answered with an empty reply.)" : text
        }
    }

    func createAPIKey(profile: String, region: String) async throws -> String {
        let route = ProviderProfile(kind: .bedrock, name: "", baseURL: "", model: "", awsProfile: profile, awsRegion: region)
        let credentials = try await AWSAccounts.credentials(for: route).credentials(forceRefresh: false)
        return try BedrockAPIKeys.create(credentials: credentials, region: region, now: Date())
    }

    func saveKeyToVault(_ key: String, region: String) throws {
        let vault = appModel.transport.vault
        let name = "AWS_BEARER_TOKEN_BEDROCK"
        let description = "Bedrock API key (\(BedrockRegions.name(of: region))), valid 12 hours"
        if var existing = vault.entry(named: name) {
            existing.description = description
            try vault.update(existing, value: key)
        } else {
            try vault.add(name: name, value: key, kind: .apiKey, description: description, tags: ["aws", "bedrock"])
        }
        appModel.transport.vaultDidChange()
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: Helpers

    /// Run `operation`, giving up with a plain error if it takes longer than `seconds`.
    private static func withTimeout<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LLMError.connection("no answer within \(Int(seconds)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
