import Foundation

// MARK: - Provider clients
//
// Every configured route is served by one of two clients: Bedrock routes by `BedrockClient` (the
// Converse API, signed with SigV4 or authorised with a Bedrock API key), everything else by
// `OpenAIClient` (chat completions). The app asks for a client here instead of choosing one itself —
// which is also where the main model gets its backups (`FailoverClient`).

/// A streaming client bound to one provider profile, with the model probe the
/// app uses to size the context gauge and to follow a server that swapped models.
public protocol ProviderClient: LLMClient {
    var profile: ProviderProfile { get }

    /// The route's model metadata (context window, the id actually served, …);
    /// nil when nothing answered.
    func modelInfo(_ model: String?) async -> ModelInfo?
}

extension OpenAIClient: ProviderClient {}

/// What the app hears from the clients it asks for: a turn that ran on a backup.
public struct ClientEvents: Sendable {
    public var failover: (@Sendable (FailoverNotice) -> Void)?

    public init(failover: (@Sendable (FailoverNotice) -> Void)? = nil) {
        self.failover = failover
    }
}

public enum ProviderClients {
    /// Where Bedrock routes signed with AWS credentials get them; the app sets
    /// this at startup to its AWS-CLI-backed source. Nil (or a route with
    /// neither an AWS profile nor an API key) leaves Bedrock clients without
    /// credentials: their calls fail with a request to sign in.
    nonisolated(unsafe) public static var awsCredentials: (@Sendable (ProviderProfile) -> (any AWSCredentialSource)?)?

    /// The client for `profile`.
    public static func make(_ profile: ProviderProfile) -> any ProviderClient {
        make(profile, backups: [])
    }

    /// The client for `profile`; with `backups`, a request it fails before answering is tried on each of them in
    /// turn (see `FailoverClient`).
    public static func make(_ profile: ProviderProfile, backups: [ProviderProfile], events: ClientEvents = ClientEvents()) -> any ProviderClient {
        let main = single(profile)
        guard !backups.isEmpty else { return main }
        return FailoverClient(primary: main, backups: backups.map { single($0) },
                              onFailover: events.failover ?? { _ in })
    }

    private static func single(_ profile: ProviderProfile) -> any ProviderClient {
        guard profile.kind == .bedrock else { return OpenAIClient(profile: profile) }
        let usesAPIKey = profile.awsProfile == nil && !(profile.apiKey ?? "").isEmpty
        return BedrockClient(profile: profile, credentials: usesAPIKey ? nil : awsCredentials?(profile))
    }
}
