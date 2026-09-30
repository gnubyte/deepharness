import Foundation

// PLACEHOLDER — replaced by the real Converse client. It exists so the provider factory and the
// rest of the app compile while the Bedrock runtime is being written; the public shape below is the
// contract the real client keeps.

public struct BedrockClient: ProviderClient {
    public let profile: ProviderProfile
    let credentials: (any AWSCredentialSource)?

    /// `credentials` is nil when the profile uses a Bedrock API key (or has no sign-in yet — then
    /// every call explains that). `session` replaces the network (tests); `clock` the time.
    public init(profile: ProviderProfile, credentials: (any AWSCredentialSource)?,
                session: URLSession? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile
        self.credentials = credentials
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.unsupported("Amazon Bedrock")) }
    }

    public func listModels() async throws -> [String] { throw LLMError.unsupported("Amazon Bedrock") }

    public func modelInfo(_ model: String?) async -> ModelInfo? { nil }
}
