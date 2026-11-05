import Foundation

// MARK: - AWS credentials: the contract between the Bedrock client and where credentials come from
//
// The app signs Bedrock requests itself (SigV4) with short-lived credentials. In the app they come
// from the AWS CLI (`aws configure export-credentials`) after `aws login` / `aws sso login`, so the
// CLI owns sign-in and refresh; tests hand in fixed ones.

/// A set of AWS credentials. `sessionToken` is set for temporary credentials
/// (every sign-in the app does produces those).
public struct AWSCredentials: Hashable, Sendable, CustomStringConvertible {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var expiration: Date?

    public init(accessKeyID: String, secretAccessKey: String,
                sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    /// True when the credentials expire within `margin` seconds (default 5 minutes).
    public func expiresWithin(_ margin: TimeInterval = 300, now: Date = Date()) -> Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSince(now) <= margin
    }

    /// Never print the secret.
    public var description: String {
        "AWSCredentials(accessKeyID: \(accessKeyID), expiration: \(expiration.map { "\($0)" } ?? "none"))"
    }
}

/// Where a Bedrock client gets credentials. Implementations cache and refresh
/// them; `forceRefresh` is passed after AWS rejected the current ones as expired.
public protocol AWSCredentialSource: Sendable {
    func credentials(forceRefresh: Bool) async throws -> AWSCredentials
}

/// Fixed credentials (tests, or keys the user typed in).
public struct StaticAWSCredentialSource: AWSCredentialSource {
    private let fixed: AWSCredentials
    public init(_ credentials: AWSCredentials) { fixed = credentials }
    public func credentials(forceRefresh: Bool) async throws -> AWSCredentials { fixed }
}

/// The AWS sign-in is missing or has run out (the CLI's refresh token expired,
/// or the profile was never signed in). Not retryable: the user has to sign in
/// again, which opens their browser.
public struct AWSSignInRequiredError: Error, LocalizedError, Sendable {
    /// The AWS CLI profile that needs signing in.
    public let profile: String
    public let message: String

    public init(profile: String, message: String) {
        self.profile = profile
        self.message = message
    }

    public var errorDescription: String? { message }
}
