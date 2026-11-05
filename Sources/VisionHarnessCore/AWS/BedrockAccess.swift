import Foundation

// MARK: - Access

/// Where a model stands for this AWS account.
public enum ModelAccessState: Sendable, Hashable, CaseIterable {
    /// This account can use the model now.
    case ready
    /// Anthropic's one-time use-case form hasn't been submitted for this account.
    case needsUseCaseForm
    /// A Marketplace model whose terms haven't been accepted (`ModelAccess.offer` has them).
    case needsAgreement
    /// AWS is still setting up the subscription (up to about 15 minutes).
    case pending
    /// The model isn't offered in this Region.
    case notInRegion
    /// An IAM policy doesn't allow it (`ModelAccess.missingPermissions` says what).
    case notAuthorized
    case error
}

/// One price in a Marketplace offer's rate card.
public struct ModelPrice: Hashable, Sendable {
    public var dimension: String
    public var price: String
    public var unit: String?
    public var description: String?

    public init(dimension: String, price: String, unit: String? = nil, description: String? = nil) {
        self.dimension = dimension
        self.price = price
        self.unit = unit
        self.description = description
    }

    /// "Input tokens (per 1K): US$0.003".
    public var display: String {
        let label = BedrockText.isBlank(description) ? dimension : description!
        let perUnit = BedrockText.isBlank(unit) || BedrockText.equals(unit!, "Units") ? "" : " per \(unit!)"
        return "\(label): US$\(price)\(perUnit)"
    }
}

/// The terms a Marketplace model is sold on — what the guide shows before "Accept".
///
/// - `offerToken`: passed back to accept this offer.
/// - `legalTermsURL`: the EULA.
/// - `agreementDuration`: as AWS words it (often ISO 8601, e.g. "P1Y"); see `durationText`.
public struct ModelOffer: Hashable, Sendable {
    public var offerToken: String
    public var offerID: String?
    public var legalTermsURL: String?
    public var prices: [ModelPrice]
    public var refundPolicy: String?
    public var agreementDuration: String?

    public init(offerToken: String, offerID: String? = nil, legalTermsURL: String? = nil, prices: [ModelPrice] = [],
                refundPolicy: String? = nil, agreementDuration: String? = nil) {
        self.offerToken = offerToken
        self.offerID = offerID
        self.legalTermsURL = legalTermsURL
        self.prices = prices
        self.refundPolicy = refundPolicy
        self.agreementDuration = agreementDuration
    }

    /// "Input tokens: US$0.003; Output tokens: US$0.015", or a note that none are listed.
    public var pricingSummary: String {
        prices.isEmpty
            ? "No usage prices are listed in the offer; see the model's page in the AWS console."
            : prices.map(\.display).joined(separator: "; ")
    }

    /// "1 year" for "P1Y"; other texts as given.
    public var durationText: String? {
        agreementDuration.map(BedrockSetup.friendlyDuration)
    }
}

/// What GetFoundationModelAvailability said.
public struct BedrockAvailability: Hashable, Sendable {
    public var agreement: String
    public var agreementError: String?
    public var authorization: String
    public var entitlement: String
    public var region: String

    public init(agreement: String, agreementError: String? = nil, authorization: String, entitlement: String, region: String) {
        self.agreement = agreement
        self.agreementError = agreementError
        self.authorization = authorization
        self.entitlement = entitlement
        self.region = region
    }
}

/// Whether this account can use a model, and what to do if not.
public struct ModelAccess: Hashable, Sendable {
    public var state: ModelAccessState
    public var modelID: String
    /// A sentence for the person, already worded for the state.
    public var message: String
    public var offer: ModelOffer?
    /// The IAM actions that were refused (`notAuthorized`), or that couldn't be checked (`needsAgreement`
    /// when the offers couldn't be read).
    public var missingPermissions: [String]?
    /// Whether Anthropic's form is on file: nil when the model isn't Anthropic's or it couldn't be checked.
    public var useCaseSubmitted: Bool?
    public var availability: BedrockAvailability?

    public init(state: ModelAccessState, modelID: String, message: String, offer: ModelOffer? = nil,
                missingPermissions: [String]? = nil, useCaseSubmitted: Bool? = nil, availability: BedrockAvailability? = nil) {
        self.state = state
        self.modelID = modelID
        self.message = message
        self.offer = offer
        self.missingPermissions = missingPermissions
        self.useCaseSubmitted = useCaseSubmitted
        self.availability = availability
    }

    public var isReady: Bool { state == .ready }

    /// The app can accept the terms itself (there is an offer to accept).
    public var canAcceptInApp: Bool { state == .needsAgreement && offer != nil }
}
