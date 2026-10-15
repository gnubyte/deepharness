import Foundation
import VisionHarnessCore

/// Where Bedrock routes get AWS credentials in the app: the AWS CLI's sign-in for the route's profile
/// (`aws login` / `aws sso login`), exported on demand and cached until shortly before they expire. One
/// source per profile, shared by every chat and every subagent, so a refresh happens once.
enum AWSAccounts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [String: AWSCLICredentialSource] = [:]

    /// Hook the Bedrock client up to the AWS CLI. Called once at startup.
    static func install() {
        ProviderClients.awsCredentials = { credentials(for: $0) }
    }

    /// The AWS CLI as installed now (it may have been installed while the app was running, so this looks
    /// again every time), or nil.
    static func cli() -> AWSCLI? {
        AWSCLI.locate().map { AWSCLI.forPath($0) }
    }

    static func credentials(for route: ProviderProfile) -> any AWSCredentialSource {
        let name = route.awsProfile ?? AWSSignIn.defaultProfile
        lock.lock(); defer { lock.unlock() }
        if let existing = sources[name] { return existing }
        // A missing CLI isn't cached: installing it later should just work.
        guard let cli = cli() else { return MissingCLI(profile: name) }
        let source = AWSCLICredentialSource(cli: cli, profile: name)
        sources[name] = source
        return source
    }

    /// Forget cached credentials after a new sign-in (or a changed profile).
    static func invalidate(_ profile: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let profile {
            sources.removeValue(forKey: profile)?.invalidate()
        } else {
            for source in sources.values { source.invalidate() }
            sources.removeAll()
        }
    }

    /// Sign `profile` in again after its session ran out: the browser sign-in (`aws login`), or IAM
    /// Identity Center's for an SSO profile. Opens the user's browser.
    static func signInAgain(profile: String, region: String?) async -> AWSSignInResult {
        guard let cli = cli() else {
            return AWSSignInResult(outcome: .failed,
                                   message: "The AWS CLI isn't installed on this Mac any more. Run the Amazon Bedrock setup again (Settings › Models) — it reinstalls it.")
        }
        let signIn = AWSSignIn(cli: cli)
        do {
            var result = try await signIn.login(profile: profile, region: region ?? AWSSignIn.defaultRegion)
            if result.outcome == .useSSOLogin { result = try await signIn.ssoLogin(profile: profile) }
            if result.succeeded { invalidate(profile) }
            return result
        } catch {
            return AWSSignInResult(outcome: .failed, message: "Signing in to AWS failed: \(error.localizedDescription)")
        }
    }

    /// Stands in when the AWS CLI can't be found: every request asks for the setup again.
    private struct MissingCLI: AWSCredentialSource {
        let profile: String
        func credentials(forceRefresh: Bool) async throws -> AWSCredentials {
            throw AWSSignInRequiredError(
                profile: profile,
                message: "The AWS CLI isn't installed on this Mac any more, so DSH can't sign in to AWS. Run the Amazon Bedrock setup again (Settings › Models) — it reinstalls it.")
        }
    }
}
