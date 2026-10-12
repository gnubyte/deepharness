import Foundation
import DSHCore

/// A `BedrockGuideBackend` with sample data and no AWS: for previews, screenshots and demos of the guide.
/// Nothing here touches the network, the AWS CLI or the disk.
@MainActor
final class DemoBedrockBackend: BedrockGuideBackend {
    var cli: AWSCLIStatus = .ready(version: SemanticVersion(2, 37, 5), path: "/usr/local/bin/aws")
    var signedIn = true
    /// Per model: what the demo says about it.
    var states: [String: ModelAccess] = [:]

    static let sonnet = BedrockModel(modelID: "anthropic.claude-sonnet-4-5-20250929-v1:0", name: "Claude Sonnet 4.5", provider: "Anthropic",
                                     inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE",
                                     inferenceTypes: ["INFERENCE_PROFILE"], invokeID: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", recommended: true)
    static let opus = BedrockModel(modelID: "anthropic.claude-opus-4-1-20250805-v1:0", name: "Claude Opus 4.1", provider: "Anthropic",
                                   inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE",
                                   inferenceTypes: ["INFERENCE_PROFILE"], invokeID: "us.anthropic.claude-opus-4-1-20250805-v1:0", recommended: true)
    static let haiku = BedrockModel(modelID: "anthropic.claude-haiku-4-5-20251001-v1:0", name: "Claude Haiku 4.5", provider: "Anthropic",
                                    inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE",
                                    inferenceTypes: ["INFERENCE_PROFILE"], invokeID: "us.anthropic.claude-haiku-4-5-20251001-v1:0", recommended: true)
    static let nova = BedrockModel(modelID: "amazon.nova-pro-v1:0", name: "Nova Pro", provider: "Amazon",
                                   inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE",
                                   inferenceTypes: ["ON_DEMAND"], invokeID: "amazon.nova-pro-v1:0", recommended: true)
    static let llama = BedrockModel(modelID: "meta.llama4-maverick-17b-instruct-v1:0", name: "Llama 4 Maverick 17B Instruct", provider: "Meta",
                                    inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE",
                                    inferenceTypes: ["INFERENCE_PROFILE"], invokeID: "us.meta.llama4-maverick-17b-instruct-v1:0", recommended: true)
    static let mistral = BedrockModel(modelID: "mistral.mistral-large-2407-v1:0", name: "Mistral Large (24.07)", provider: "Mistral AI",
                                      inputModalities: ["TEXT"], streaming: true, lifecycle: "ACTIVE",
                                      inferenceTypes: ["ON_DEMAND"], invokeID: "mistral.mistral-large-2407-v1:0")
    static let deepseek = BedrockModel(modelID: "deepseek.r1-v1:0", name: "DeepSeek-R1", provider: "DeepSeek",
                                       inputModalities: ["TEXT"], streaming: true, lifecycle: "ACTIVE",
                                       inferenceTypes: ["INFERENCE_PROFILE"], invokeID: "us.deepseek.r1-v1:0")
    static let all = [sonnet, opus, haiku, nova, llama, mistral, deepseek]

    init() {
        states = [
            Self.sonnet.modelID: ModelAccess(state: .ready, modelID: Self.sonnet.modelID, message: "Your account can use this model."),
            Self.haiku.modelID: ModelAccess(state: .ready, modelID: Self.haiku.modelID, message: "Your account can use this model."),
            Self.opus.modelID: ModelAccess(state: .needsUseCaseForm, modelID: Self.opus.modelID, message: "Anthropic needs the one-time use-case form."),
            Self.llama.modelID: ModelAccess(state: .needsAgreement, modelID: Self.llama.modelID, message: "Accept the model's terms to use it.",
                                            offer: ModelOffer(offerToken: "offer-token", offerID: "offer-id",
                                                              legalTermsURL: "https://aws.amazon.com/marketplace/pp/example-eula",
                                                              prices: [ModelPrice(dimension: "Input tokens", price: "0.00024", unit: "1K tokens"),
                                                                       ModelPrice(dimension: "Output tokens", price: "0.00097", unit: "1K tokens")],
                                                              refundPolicy: "No refunds on usage already charged.", agreementDuration: "P1Y")),
            Self.nova.modelID: ModelAccess(state: .pending, modelID: Self.nova.modelID, message: "AWS is still setting up your subscription."),
            Self.deepseek.modelID: ModelAccess(state: .notInRegion, modelID: Self.deepseek.modelID, message: "DeepSeek-R1 isn't offered in US East (N. Virginia)."),
        ]
    }

    func checkCLI() async -> AWSCLIStatus { cli }
    var installProblem: String? { nil }
    var homebrewAvailable: Bool { true }
    /// How long the demo install takes (a screenshot of the progress page needs it to last).
    var installTime: TimeInterval = 0
    func installCLI(scope: CLIInstallScope, current: AWSCLIStatus?,
                    progress: @escaping @Sendable (CLIInstallProgress) -> Void) async -> CLIInstallOutcome {
        progress(CLIInstallProgress(stage: "Downloading the AWS CLI installer", fraction: 0.42, detail: nil))
        if installTime > 0 { try? await Task.sleep(nanoseconds: UInt64(installTime * 1_000_000_000)) }
        return CLIInstallOutcome(succeeded: true, message: "Installed.", status: .ready(version: SemanticVersion(2, 37, 5), path: "/Users/you/.local/bin/aws"))
    }
    func awsProfiles() -> [AWSProfile] {
        [AWSProfile(name: "corp-sso", kind: .sso, region: "us-west-2", settings: [:]),
         AWSProfile(name: "dev-keys", kind: .accessKeys, region: "us-east-1", settings: [:])]
    }
    func defaultRegion() -> String? { "us-east-1" }
    func verify(profile: String, region: String) async throws -> AWSCallerIdentity {
        guard signedIn else { throw AWSSignInRequiredError(profile: profile, message: "Not signed in.") }
        return AWSCallerIdentity(account: "123456789012", arn: "arn:aws:iam::123456789012:user/alice", userID: "AIDAEXAMPLE")
    }
    func login(profile: String, region: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        AWSSignInResult(outcome: .signedIn, message: "Signed in to AWS.")
    }
    func ssoLogin(profile: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        AWSSignInResult(outcome: .signedIn, message: "Signed in.")
    }
    func invalidateCredentials(profile: String) {}
    func listModels(profile: String, region: String) async throws -> [BedrockModel] { Self.all }
    func checkAccess(profile: String, region: String, model: BedrockModel) async throws -> ModelAccess {
        states[model.modelID] ?? ModelAccess(state: .ready, modelID: model.modelID, message: "Your account can use this model.")
    }
    func submitUseCase(profile: String, region: String, answers: UseCaseAnswers) async throws -> UseCaseOutcome { .submitted }
    func acceptAgreement(profile: String, region: String, modelID: String, offerToken: String) async throws {}
    func waitUntilReady(profile: String, region: String, model: BedrockModel,
                        progress: @escaping @Sendable (ModelAccess) -> Void) async throws -> ModelAccess {
        ModelAccess(state: .ready, modelID: model.modelID, message: "Ready.")
    }
    func sayHello(route: ProviderProfile) async throws -> String { "Hello! I'm running on Amazon Bedrock and ready to help you build something great." }
    func createAPIKey(profile: String, region: String) async throws -> String { "bedrock-api-key-DEMO" }
    func saveKeyToVault(_ key: String, region: String) throws {}
    func open(_ url: URL) {}
}
