import Foundation

// MARK: - Amazon Bedrock account setup
//
// Everything between "signed in to AWS" and "the model answers", done with the AWS CLI against the
// Bedrock control plane (botocore bedrock/2023-04-20):
//   * which models this Region offers (ListFoundationModels) and the id to call each by — the model
//     id when it runs on demand, otherwise a cross-Region inference profile (ListInferenceProfiles);
//   * whether this account may use a model (GetFoundationModelAvailability: agreement, authorization,
//     entitlement, Region);
//   * Anthropic's one-time "first time use" form (Get/PutUseCaseForModelAccess);
//   * a Marketplace model's terms — EULA link, prices, refund policy — to show and accept
//     (ListFoundationModelAgreementOffers, CreateFoundationModelAgreement), and waiting while AWS
//     finishes the subscription (it can take up to about 15 minutes).
// Since October 2025 serverless models are enabled by default in commercial Regions and Marketplace
// models subscribe on first use, so for most accounts this reports "ready" straight away; the rest is
// for the accounts where it doesn't.
//
// The pieces: `BedrockRegions` (this file), `BedrockCatalog`/`BedrockModel` (what to recommend and
// which id to call), `BedrockAccess` (per-model access states, offers, prices), `UseCaseForm`
// (Anthropic's form), `BedrockSetup` (the CLI calls) and `BedrockPermissions` (the IAM policy text).

// MARK: - Regions

/// A Region to offer in the guide's picker.
public struct AWSRegionChoice: Hashable, Sendable, Identifiable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public var id: String { code }

    /// "US East (N. Virginia) — us-east-1".
    public var display: String { "\(name) — \(code)" }
}

/// Bedrock Regions most people pick from.
public enum BedrockRegions {
    /// The Region with the most models (and the one `aws login` itself suggests).
    public static let defaultRegion = "us-east-1"

    public static let common: [AWSRegionChoice] = [
        AWSRegionChoice(code: "us-east-1", name: "US East (N. Virginia)"),
        AWSRegionChoice(code: "us-east-2", name: "US East (Ohio)"),
        AWSRegionChoice(code: "us-west-2", name: "US West (Oregon)"),
        AWSRegionChoice(code: "ca-central-1", name: "Canada (Central)"),
        AWSRegionChoice(code: "sa-east-1", name: "South America (São Paulo)"),
        AWSRegionChoice(code: "eu-central-1", name: "Europe (Frankfurt)"),
        AWSRegionChoice(code: "eu-west-1", name: "Europe (Ireland)"),
        AWSRegionChoice(code: "eu-west-2", name: "Europe (London)"),
        AWSRegionChoice(code: "eu-west-3", name: "Europe (Paris)"),
        AWSRegionChoice(code: "eu-north-1", name: "Europe (Stockholm)"),
        AWSRegionChoice(code: "ap-northeast-1", name: "Asia Pacific (Tokyo)"),
        AWSRegionChoice(code: "ap-northeast-2", name: "Asia Pacific (Seoul)"),
        AWSRegionChoice(code: "ap-south-1", name: "Asia Pacific (Mumbai)"),
        AWSRegionChoice(code: "ap-southeast-1", name: "Asia Pacific (Singapore)"),
        AWSRegionChoice(code: "ap-southeast-2", name: "Asia Pacific (Sydney)"),
    ]

    /// "Europe (Frankfurt)" for "eu-central-1"; the code itself for Regions not listed.
    public static func name(of region: String) -> String {
        common.first { $0.code == region }?.name ?? region
    }

    /// Inference-profile prefixes to prefer from `region`, closest geography first: a US Region
    /// prefers "us." profiles (requests stay in US Regions), then "global.". Profiles listed in a
    /// Region are all callable from it; this only decides which to pick when several are.
    public static func profilePrefixes(for region: String) -> [String] {
        let r = region.lowercased()
        func starts(_ prefix: String) -> Bool { r.utf8.starts(with: prefix.utf8) }
        if starts("us-gov-") { return ["us-gov"] }
        if starts("us-") { return ["us", "global"] }
        if starts("ca-") { return ["ca", "us", "global"] }
        if starts("eu-") { return ["eu", "global"] }
        if r == "ap-northeast-1" || r == "ap-northeast-3" { return ["jp", "apac", "global"] }
        if r == "ap-southeast-2" || r == "ap-southeast-4" { return ["au", "apac", "global"] }
        if starts("ap-") { return ["apac", "global"] }
        return ["global"]
    }
}
