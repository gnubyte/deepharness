import Foundation

// MARK: - The setup calls

/// A call the setup layer can't make because of what it was handed (a form that isn't complete, a blank
/// model id): a programming or UI slip rather than something AWS said. `message` is plain language.
public struct BedrockSetupArgumentError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// The Bedrock side of setup for one AWS CLI profile and Region.
///
/// Every call is one `aws bedrock …` command run through `AWSCLICommands`, so the whole layer is
/// testable with scripted output and no AWS account. A sign-in that has run out surfaces as
/// `AWSSignInRequiredError` (sign in again); other CLI failures as `AWSCLIException` — except where a
/// failure is an answer (`checkAccess` reports it as a `ModelAccess` state).
public final class BedrockSetup: Sendable {
    private let cli: any AWSCLICommands
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The AWS CLI profile every call uses (--profile).
    public let profile: String
    public let region: String

    /// `now` and `sleep` are the clock waiting uses; tests replace them so a 15-minute wait takes no time.
    /// A blank profile or Region is a programming error (the Windows app throws an ArgumentException).
    public init(cli: any AWSCLICommands, profile: String, region: String,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = BedrockSetup.systemSleep) {
        precondition(!BedrockText.isBlank(profile), "BedrockSetup needs an AWS CLI profile")
        precondition(!BedrockText.isBlank(region), "BedrockSetup needs a Region")
        self.cli = cli
        self.profile = profile
        self.region = region
        self.now = now
        self.sleep = sleep
    }

    /// Waits on the task's clock (cancelling the task ends the wait with `CancellationError`).
    public static let systemSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 1e9) * 1e9))
    }

    /// Same as `BedrockRegions.common`.
    public static var commonRegions: [AWSRegionChoice] { BedrockRegions.common }
    public static var defaultRegion: String { BedrockRegions.defaultRegion }

    private func json(_ command: [String]) async throws -> JSONValue {
        try await cli.runJSON(command, profile: profile, region: region)
    }

    // MARK: Models

    /// The models this Region offers for chat, each with the id to call it by (`BedrockCatalog.build`).
    /// Needs bedrock:ListFoundationModels and bedrock:ListInferenceProfiles.
    public func listModels() async throws -> [BedrockModel] {
        let models = try await json(["bedrock", "list-foundation-models", "--by-output-modality", "TEXT"])
        let profiles = try await listInferenceProfiles()
        return BedrockCatalog.build(foundationModels: models, inferenceProfiles: profiles, region: region)
    }

    /// All system inference profiles. The CLI fetches every page itself; should it ever stop early (it
    /// prints "NextToken" then), the app continues from there.
    private func listInferenceProfiles() async throws -> JSONValue {
        var all: [JSONValue] = []
        var next: String?
        for _ in 0..<50 {
            var command = ["bedrock", "list-inference-profiles", "--type-equals", "SYSTEM_DEFINED"]
            if let next { command += ["--starting-token", next] }
            let page = try await json(command)
            all += page["inferenceProfileSummaries"]?.array ?? []
            next = BedrockJSON.string(page, "NextToken") ?? BedrockJSON.string(page, "nextToken")
            if next?.isEmpty ?? true { break }
        }
        return .object(["inferenceProfileSummaries": .array(all)])
    }

    // MARK: Access

    /// Whether this account can use `model` (checked by its base model id), and if not, what's needed:
    /// the use-case form (Anthropic), accepting terms (with the offer to show), a wait, a permission, or
    /// another Region.
    public func checkAccess(_ model: BedrockModel) async throws -> ModelAccess {
        try await checkAccess(modelID: model.modelID, name: model.name, isAnthropic: model.isAnthropic)
    }

    /// The same for a model known only by id (for example the one a saved route uses). `name` is what the
    /// messages call it (the id when omitted or blank); `isAnthropic` says whether Anthropic's form applies
    /// (an id starting "anthropic." when omitted).
    public func checkAccess(modelID: String, name: String? = nil, isAnthropic: Bool? = nil) async throws -> ModelAccess {
        let shown = BedrockText.isBlank(name) ? modelID : name!
        let anthropic = isAnthropic ?? BedrockText.hasPrefix(modelID, "anthropic.", ignoringCase: true)
        let answer: JSONValue
        do {
            answer = try await json(["bedrock", "get-foundation-model-availability", "--model-id", modelID])
        } catch let error as AWSCLIException where error.kind == .accessDenied {
            let permission = error.error.permission ?? "bedrock:GetFoundationModelAvailability"
            return ModelAccess(state: .notAuthorized, modelID: modelID,
                               message: "Vision can't check access to \(shown): your AWS permissions don't allow \(permission). Ask whoever manages your AWS account to add the policy Vision shows — or just try the model.",
                               missingPermissions: [permission])
        } catch let error as AWSCLIException where error.kind == .notFound {
            return ModelAccess(state: .notInRegion, modelID: modelID,
                               message: "\(shown) isn't offered in \(BedrockRegions.name(of: region)). Pick another model or Region.")
        } catch let error as AWSCLIException {
            return ModelAccess(state: .error, modelID: modelID, message: error.error.message)
        }

        let availability = Self.parseAvailability(answer)
        if BedrockText.equals(availability.region, "NOT_AVAILABLE") {
            return ModelAccess(state: .notInRegion, modelID: modelID,
                               message: "\(shown) isn't offered in \(BedrockRegions.name(of: region)). Pick another model or Region.",
                               availability: availability)
        }
        if BedrockText.equals(availability.authorization, "NOT_AUTHORIZED") {
            return ModelAccess(state: .notAuthorized, modelID: modelID,
                               message: "Your AWS permissions don't allow using \(shown). Ask whoever manages your AWS account to allow \(BedrockPermissions.invokeActions.joined(separator: " and ")) — Vision can show the exact policy to send them.",
                               missingPermissions: BedrockPermissions.invokeActions, availability: availability)
        }
        if BedrockText.equals(availability.agreement, "ERROR") {
            return ModelAccess(state: .error, modelID: modelID,
                               message: "AWS reported a problem with access to \(shown): \(availability.agreementError ?? "no details given").",
                               availability: availability)
        }

        var useCase: Bool?
        if anthropic {
            useCase = try await useCaseOnFile()
            if useCase == false {
                return ModelAccess(state: .needsUseCaseForm, modelID: modelID,
                                   message: "Anthropic asks each AWS account once for a few details about how its models will be used. Fill in the short form and Vision sends it for you.",
                                   useCaseSubmitted: false, availability: availability)
            }
        }

        if BedrockText.equals(availability.agreement, "NOT_AVAILABLE") {
            var offer: ModelOffer?
            var missing: [String]?
            do {
                offer = try await firstOffer(modelID: modelID)
            } catch let error as AWSCLIException where error.kind == .accessDenied {
                missing = [error.error.permission ?? "bedrock:ListFoundationModelAgreementOffers"]
            }
            let message = offer != nil
                ? "\(shown) is sold through AWS Marketplace. Review its terms and prices, then accept them to subscribe — usage is billed to your AWS account."
                : "\(shown) is sold through AWS Marketplace. AWS subscribes your account the first time the model is used; that can take up to 15 minutes."
            return ModelAccess(state: .needsAgreement, modelID: modelID, message: message, offer: offer,
                               missingPermissions: missing, useCaseSubmitted: useCase, availability: availability)
        }
        if BedrockText.equals(availability.agreement, "PENDING") || BedrockText.equals(availability.entitlement, "NOT_AVAILABLE") {
            return ModelAccess(state: .pending, modelID: modelID,
                               message: "AWS is setting up your access to \(shown). This can take up to 15 minutes.",
                               useCaseSubmitted: useCase, availability: availability)
        }
        return ModelAccess(state: .ready, modelID: modelID, message: "\(shown) is ready to use.",
                           useCaseSubmitted: useCase, availability: availability)
    }

    /// Read GetFoundationModelAvailability's answer.
    public static func parseAvailability(_ json: JSONValue?) -> BedrockAvailability {
        let agreement = json?["agreementAvailability"]
        return BedrockAvailability(
            agreement: BedrockJSON.string(agreement, "status") ?? "",
            agreementError: BedrockJSON.string(agreement, "errorMessage"),
            authorization: BedrockJSON.string(json, "authorizationStatus") ?? "",
            entitlement: BedrockJSON.string(json, "entitlementAvailability") ?? "",
            region: BedrockJSON.string(json, "regionAvailability") ?? "")
    }

    // MARK: Marketplace offers

    /// The first offer for a Marketplace model, or nil when AWS lists none.
    public func firstOffer(modelID: String) async throws -> ModelOffer? {
        let answer = try await json(["bedrock", "list-foundation-model-agreement-offers", "--model-id", modelID])
        return Self.parseOffers(answer).first
    }

    /// Read ListFoundationModelAgreementOffers' answer.
    public static func parseOffers(_ json: JSONValue?) -> [ModelOffer] {
        var offers: [ModelOffer] = []
        for offer in json?["offers"]?.array ?? [] {
            guard offer.object != nil, let token = BedrockJSON.string(offer, "offerToken"), !token.isEmpty else { continue }
            let terms = offer["termDetails"]
            var prices: [ModelPrice] = []
            for rate in terms?["usageBasedPricingTerm"]?["rateCard"]?.array ?? [] where rate.object != nil {
                prices.append(ModelPrice(dimension: BedrockJSON.string(rate, "dimension") ?? "",
                                         price: BedrockJSON.string(rate, "price") ?? "?",
                                         unit: BedrockJSON.string(rate, "unit"),
                                         description: BedrockJSON.string(rate, "description")))
            }
            offers.append(ModelOffer(
                offerToken: token,
                offerID: BedrockJSON.string(offer, "offerId"),
                legalTermsURL: BedrockJSON.string(terms?["legalTerm"], "url"),
                prices: prices,
                refundPolicy: BedrockJSON.string(terms?["supportTerm"], "refundPolicyDescription"),
                agreementDuration: BedrockJSON.string(terms?["validityTerm"], "agreementDuration")))
        }
        return offers
    }

    /// "P1Y" → "1 year", "P12M" → "12 months", "P30D" → "30 days"; anything else unchanged.
    public static func friendlyDuration(_ duration: String) -> String {
        let text = BedrockText.trimmed(duration) as NSString
        guard let match = durationPattern.firstMatch(in: text as String, options: [], range: NSRange(location: 0, length: text.length))
        else { return duration }
        var parts: [String] = []
        for (group, unit) in [(1, "year"), (2, "month"), (3, "week"), (4, "day")] {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { continue }
            // Digits of another script (\d matches them) or too many for an Int32 don't count.
            let digits = text.substring(with: range)
            guard digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int32(digits), n > 0 else { continue }
            parts.append(n == 1 ? "1 \(unit)" : "\(n) \(unit)s")
        }
        return parts.isEmpty ? duration : parts.joined(separator: ", ")
    }

    private static let durationPattern = try! NSRegularExpression(pattern: #"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$"#)

    // MARK: Anthropic's use-case form

    /// Whether Anthropic's use-case form is on file for this account: true, false (AWS says there is
    /// none), or nil when the app can't tell (for example, no permission to read it).
    public func useCaseOnFile() async throws -> Bool? {
        do {
            let answer = try await json(["bedrock", "get-use-case-for-model-access"])
            return !(BedrockJSON.string(answer, "formData") ?? "").isEmpty
        } catch let error as AWSCLIException {
            if error.kind == .notFound || error.error.details.range(of: "not found", options: .caseInsensitive) != nil { return false }
            return nil
        }
    }

    /// The form on file, or nil when there is none (or it can't be read).
    public func getUseCase() async throws -> UseCaseForm? {
        do {
            let answer = try await json(["bedrock", "get-use-case-for-model-access"])
            guard let data = BedrockJSON.string(answer, "formData"), !data.isEmpty else { return nil }
            return UseCaseForm.fromFormData(data)
        } catch is AWSCLIException {
            return nil
        }
    }

    /// The CLI arguments that submit `form`.
    public static func submitUseCaseCommand(_ form: UseCaseForm) -> [String] {
        ["bedrock", "put-use-case-for-model-access", "--form-data", form.toBase64(), "--cli-binary-format", "base64"]
    }

    /// Submit Anthropic's use-case form, unless this account already has one (it can't be changed, so
    /// it isn't sent twice). Throws `BedrockSetupArgumentError` with a plain message when the form is
    /// incomplete.
    public func submitUseCase(_ form: UseCaseForm) async throws -> UseCaseSubmission {
        if let problem = form.problem { throw BedrockSetupArgumentError(problem) }
        if try await useCaseOnFile() == true { return .alreadyOnFile }
        _ = try await cli.runChecked(Self.submitUseCaseCommand(form), profile: profile, region: region)
        return .submitted
    }

    // MARK: Agreements and waiting

    /// Accept a Marketplace offer's terms (CreateFoundationModelAgreement). AWS then subscribes the
    /// account; follow with `waitUntilReady`. An agreement already in progress (ConflictException)
    /// counts as accepted.
    public func acceptAgreement(modelID: String, offerToken: String) async throws {
        if BedrockText.isBlank(modelID) { throw BedrockSetupArgumentError("The model id is empty.") }
        if BedrockText.isBlank(offerToken) { throw BedrockSetupArgumentError("The offer to accept is empty.") }
        do {
            _ = try await cli.runChecked(["bedrock", "create-foundation-model-agreement", "--model-id", modelID, "--offer-token", offerToken],
                                         profile: profile, region: region)
        } catch let error as AWSCLIException where error.kind == .conflict {
            // Already accepted, or being processed.
        }
    }

    /// Check access now and then every `pollInterval` (default 15 s) until the model is ready, needs
    /// something from the user, or `timeout` (default 15 minutes) passes; each check is reported.
    /// "Pending" and "needs agreement" keep it waiting — right after an agreement is accepted AWS can
    /// still report it as not available for a moment. Returns the last check. Cancelling the task ends
    /// the wait with `CancellationError`.
    public func waitUntilReady(_ model: BedrockModel, progress: (@Sendable (ModelAccess) -> Void)? = nil,
                               timeout: TimeInterval? = nil, pollInterval: TimeInterval? = nil) async throws -> ModelAccess {
        let deadline = now().addingTimeInterval(timeout ?? 15 * 60)
        let interval = pollInterval ?? 15
        while true {
            try Task.checkCancellation()
            let access = try await checkAccess(model)
            progress?(access)
            if access.state != .pending && access.state != .needsAgreement { return access }
            let left = deadline.timeIntervalSince(now())
            if left <= 0 { return access }
            try await sleep(min(left, interval))
        }
    }
}
