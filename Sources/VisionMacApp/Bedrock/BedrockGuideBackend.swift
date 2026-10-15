import Foundation
import VisionHarnessCore

// MARK: - What the Bedrock guide needs from the outside world
//
// The guide is a state machine (which page, what is selected, what is being waited for). Everything it
// does to AWS, the machine or the network goes through this protocol, so the whole flow — sign-in
// expiring half-way, a model that needs a form, a Marketplace subscription that takes ten minutes — is
// testable with a scripted backend and no AWS account. `LiveBedrockBackend` is the real one.

/// How the AWS CLI gets installed.
enum CLIInstallScope: Sendable {
    /// Just for this user: no administrator prompt.
    case currentUser
    /// For everyone on this Mac (macOS asks for a password).
    case allUsers
    /// With Homebrew.
    case homebrew
}

struct CLIInstallProgress: Sendable, Equatable {
    var stage: String
    /// 0…1 when the size is known.
    var fraction: Double?
    var detail: String?
}

struct CLIInstallOutcome: Sendable, Equatable {
    var succeeded: Bool
    var cancelled = false
    var message: String
    /// The CLI's status after a successful install.
    var status: AWSCLIStatus?
    /// A failure another route (Homebrew) may get past.
    var canTryHomebrew = false
    var logPath: String?
}

/// The answers to Anthropic's one-time "first time use" questions.
struct UseCaseAnswers: Sendable, Equatable {
    enum Audience: String, Sendable, CaseIterable {
        case company, customers, both

        var label: String {
            switch self {
            case .company: "Me or people in my company"
            case .customers: "My customers"
            case .both: "Both"
            }
        }
    }

    var company = ""
    var website = ""
    var industry = "Technology"
    var otherIndustry = ""
    var useCases = "Coding help: an AI coding agent (DSH) that reads, writes and tests code in my projects on my own Mac."
    var audience: Audience = .company

    /// What is missing or wrong, in a sentence — nil when it can be sent.
    var problem: String? {
        if company.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your company, or your own name." }
        if website.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a website — a personal site or profile page works too." }
        if industry == "Other", otherIndustry.trimmingCharacters(in: .whitespaces).isEmpty { return "Say what your industry is." }
        if useCases.trimmingCharacters(in: .whitespaces).isEmpty { return "Say what you will use it for." }
        return nil
    }
}

enum UseCaseOutcome: Sendable, Equatable {
    case submitted
    /// This account already has a form on file (AWS doesn't allow changing it), so nothing was sent.
    case alreadyOnFile
}

/// The hooks the sign-in reports through, on whatever thread they happen.
struct SignInCallbacks: Sendable {
    var onOutput: @Sendable (String) -> Void
    var onLink: @Sendable (AWSSignInLink) -> Void
    /// The CLI's "remote" mode asks for the code AWS shows after signing in elsewhere; nil = the user gave up.
    var requestCode: @Sendable (AWSSignInLink) async -> String?
}

/// Everything the guide does to AWS and the machine.
@MainActor
protocol BedrockGuideBackend: AnyObject, Sendable {
    // MARK: The AWS CLI
    func checkCLI() async -> AWSCLIStatus
    /// A reason this Mac cannot install the CLI itself (nil = it can).
    var installProblem: String? { get }
    var homebrewAvailable: Bool { get }
    func installCLI(scope: CLIInstallScope, current: AWSCLIStatus?,
                    progress: @escaping @Sendable (CLIInstallProgress) -> Void) async -> CLIInstallOutcome

    // MARK: Profiles and sign-in
    func awsProfiles() -> [AWSProfile]
    func defaultRegion() -> String?
    /// Who the profile is signed in as; throws when it isn't (`AWSSignInRequiredError`) or can't be asked.
    func verify(profile: String, region: String) async throws -> AWSCallerIdentity
    func login(profile: String, region: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult
    func ssoLogin(profile: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult
    /// Forget cached credentials for a profile (after a new sign-in).
    func invalidateCredentials(profile: String)

    // MARK: Bedrock
    func listModels(profile: String, region: String) async throws -> [BedrockModel]
    func checkAccess(profile: String, region: String, model: BedrockModel) async throws -> ModelAccess
    func submitUseCase(profile: String, region: String, answers: UseCaseAnswers) async throws -> UseCaseOutcome
    func acceptAgreement(profile: String, region: String, modelID: String, offerToken: String) async throws
    func waitUntilReady(profile: String, region: String, model: BedrockModel,
                        progress: @escaping @Sendable (ModelAccess) -> Void) async throws -> ModelAccess

    // MARK: Connecting
    /// Send one short message through the route and return the reply.
    func sayHello(route: ProviderProfile) async throws -> String
    func createAPIKey(profile: String, region: String) async throws -> String
    /// Save a Bedrock API key in the credentials vault; throws with a sentence when that fails.
    func saveKeyToVault(_ key: String, region: String) throws

    /// Open a web page in the user's browser.
    func open(_ url: URL)
}
