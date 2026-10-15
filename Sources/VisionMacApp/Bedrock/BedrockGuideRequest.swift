import Foundation
import VisionHarnessCore

/// The pages of the Amazon Bedrock guide, in order.
enum BedrockPage: Int, CaseIterable, Comparable {
    case welcome, cli, signIn, model, access, connect, done

    static func < (a: BedrockPage, b: BedrockPage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .welcome: "Amazon Bedrock"
        case .cli: "The AWS CLI"
        case .signIn: "Sign in"
        case .model: "Pick a model"
        case .access: "Enable it"
        case .connect: "Connect"
        case .done: "Done"
        }
    }
}

/// What opens the guide: which page to start on and, when re-running it for an existing
/// route ("Change…" a model, "Sign in" again), which route.
struct BedrockGuideRequest: Identifiable {
    let id = UUID()
    var page: BedrockPage = .welcome
    var route: ProviderProfile?
}
