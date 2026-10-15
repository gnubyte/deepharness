import XCTest
import CryptoKit
@testable import VisionHarnessCore

// MARK: - Fixtures (shapes from botocore's bedrock/2023-04-20 model, as the CLI prints them with --output json)

enum BedrockSetupFixtures {
    static let getAvailability = ["bedrock", "get-foundation-model-availability"]
    static let getUseCase = ["bedrock", "get-use-case-for-model-access"]
    static let putUseCase = ["bedrock", "put-use-case-for-model-access"]
    static let listOffers = ["bedrock", "list-foundation-model-agreement-offers"]
    static let createAgreement = ["bedrock", "create-foundation-model-agreement"]
    static let listModels = ["bedrock", "list-foundation-models"]
    static let listProfiles = ["bedrock", "list-inference-profiles"]

    static func availability(agreement: String = "AVAILABLE", authorization: String = "AUTHORIZED", entitlement: String = "AVAILABLE",
                             region: String = "AVAILABLE", error: String? = nil) -> String {
        var agreementObject: [String: JSONValue] = ["status": .string(agreement)]
        if let error { agreementObject["errorMessage"] = .string(error) }
        return JSONValue.object(["modelId": "x", "agreementAvailability": .object(agreementObject), "authorizationStatus": .string(authorization),
                                 "entitlementAvailability": .string(entitlement), "regionAvailability": .string(region)]).serialized()
    }

    static let offers = #"""
        {
            "modelId": "cohere.command-r-plus-v1:0",
            "offers": [
                {
                    "offerId": "offer-3k2l5j6h7g8f",
                    "offerToken": "eyJvZmZlcklkIjoib2ZmZXItM2syIn0=",
                    "termDetails": {
                        "usageBasedPricingTerm": {
                            "rateCard": [
                                {"dimension": "InputTokenCount", "price": "0.0030", "description": "Input tokens (per 1K)", "unit": "Units"},
                                {"dimension": "OutputTokenCount", "price": "0.0150", "unit": "1K tokens"}
                            ]
                        },
                        "legalTerm": {"url": "https://aws-mp-legal-docs.s3.amazonaws.com/eula/cohere.pdf"},
                        "supportTerm": {"refundPolicyDescription": "No refunds for usage already billed."},
                        "validityTerm": {"agreementDuration": "P1Y"}
                    }
                }
            ]
        }
        """#

    static let cohere = BedrockModel(modelID: "cohere.command-r-plus-v1:0", name: "Command R+", provider: "Cohere", inputModalities: ["TEXT"],
                                     streaming: true, lifecycle: "ACTIVE", inferenceTypes: ["ON_DEMAND"], invokeID: "cohere.command-r-plus-v1:0")
    static let sonnet = BedrockModel(modelID: "anthropic.claude-sonnet-4-5-20250929-v1:0", name: "Claude Sonnet 4.5", provider: "Anthropic",
                                     inputModalities: ["TEXT", "IMAGE"], streaming: true, lifecycle: "ACTIVE", inferenceTypes: ["INFERENCE_PROFILE"],
                                     invokeID: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", recommended: true)

    static let useCaseNotFound = ScriptedCLIFailure.notFound(operation: "GetUseCaseForModelAccess", message: "Use case form not found.")
    static let acme = UseCaseFormTests.acme

    /// A setup on profile "vision-bedrock" in us-east-1, over a scripted CLI.
    static func setup(_ script: (ScriptedAWSCLI) -> Void = { _ in }, clock: BedrockWaitClock? = nil, region: String = "us-east-1") -> (setup: BedrockSetup, cli: ScriptedAWSCLI) {
        let cli = ScriptedAWSCLI()
        script(cli)
        if let clock {
            return (BedrockSetup(cli: cli, profile: "vision-bedrock", region: region, now: clock.nowClosure, sleep: clock.sleepClosure), cli)
        }
        return (BedrockSetup(cli: cli, profile: "vision-bedrock", region: region), cli)
    }
}

/// `XCTAssertThrowsError` for async code: the error is handed to `handler`.
func assertSetupThrows<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                     _ handler: (any Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("expected an error. \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}

private typealias Fixtures = BedrockSetupFixtures

// MARK: - Listing the models

final class BedrockSetupListingTests: XCTestCase {
    private func page(_ items: [JSONValue], key: String? = nil, token: String? = nil) -> String {
        var object: [String: JSONValue] = ["inferenceProfileSummaries": .array(items)]
        if let key, let token { object[key] = .string(token) }
        return JSONValue.object(object).serialized()
    }

    private var allProfiles: [JSONValue] { BedrockJSONFixtures.inferenceProfiles["inferenceProfileSummaries"]?.array ?? [] }

    func testListsModelsThroughTheCli() async throws {
        let page1 = page([BedrockJSONFixtures.geo("us", BedrockJSONFixtures.sonnet45, ["us-east-1"])], key: "NextToken", token: "eyJuZXh0IjogMn0=")
        let page2 = page([BedrockJSONFixtures.geo("global", "anthropic.claude-haiku-4-5-20251001-v1:0", [""])])
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized())
                .onSequence(Fixtures.listProfiles, [.output(page1), .output(page2)])
        }
        let models = try await setup.listModels()

        XCTAssertEqual(models.first { $0.modelID.contains("sonnet-4-5") }?.invokeID, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        XCTAssertEqual(models.first { $0.modelID.contains("haiku-4-5") }?.invokeID, "global.anthropic.claude-haiku-4-5-20251001-v1:0")
        XCTAssertEqual(cli.calls[0].command, ["bedrock", "list-foundation-models", "--by-output-modality", "TEXT"])
        XCTAssertEqual(cli.calls[0].profile, "vision-bedrock")
        XCTAssertEqual(cli.calls[0].region, "us-east-1")
        XCTAssertEqual(cli.calls[0].kind, .json)
        let profileCalls = cli.calls(to: "bedrock", "list-inference-profiles")
        XCTAssertEqual(profileCalls.count, 2)
        XCTAssertEqual(profileCalls[0].command, ["bedrock", "list-inference-profiles", "--type-equals", "SYSTEM_DEFINED"])
        XCTAssertEqual(profileCalls[0].profile, "vision-bedrock")
        XCTAssertEqual(profileCalls[0].region, "us-east-1")
        XCTAssertTrue(profileCalls[1].hasPair("--starting-token", "eyJuZXh0IjogMn0="))
        XCTAssertEqual(cli.calls.count, 3, "nothing else was asked")
    }

    func testTheModelsAreListedBeforeTheProfilesAreAskedFor() async {
        let (setup, cli) = Fixtures.setup { $0.fail(Fixtures.listModels, .accessDenied(operation: "ListFoundationModels", permission: "bedrock:ListFoundationModels")) }
        await assertSetupThrows(try await setup.listModels()) { error in
            XCTAssertEqual((error as? AWSCLIException)?.kind, .accessDenied)
        }
        XCTAssertEqual(cli.calls.count, 1)
    }

    func testListingNeedsPermission() async {
        let (setup, _) = Fixtures.setup {
            $0.fail(Fixtures.listModels, .accessDenied(operation: "ListFoundationModels", permission: "bedrock:ListFoundationModels"))
        }
        await assertSetupThrows(try await setup.listModels()) { error in
            let failure = error as? AWSCLIException
            XCTAssertEqual(failure?.kind, .accessDenied)
            XCTAssertEqual(failure?.error.permission, "bedrock:ListFoundationModels")
        }
    }

    func testTheProfilesNeedPermissionToo() async {
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized())
                .fail(Fixtures.listProfiles, .accessDenied(operation: "ListInferenceProfiles", permission: "bedrock:ListInferenceProfiles"))
        }
        await assertSetupThrows(try await setup.listModels()) { error in
            XCTAssertEqual((error as? AWSCLIException)?.error.permission, "bedrock:ListInferenceProfiles")
        }
        XCTAssertEqual(cli.calls.count, 2)
    }

    func testASignInThatRanOutIsNotHiddenAsAnEmptyList() async {
        let (setup, _) = Fixtures.setup { $0.fail(Fixtures.listModels, .ssoExpired) }
        await assertSetupThrows(try await setup.listModels()) { error in
            XCTAssertEqual((error as? AWSSignInRequiredError)?.profile, "vision-bedrock")
        }
    }

    func testOutputTheAppCannotReadIsAnError() async {
        let (setup, _) = Fixtures.setup { $0.on(Fixtures.listModels, "<html>not json</html>") }
        await assertSetupThrows(try await setup.listModels()) { error in
            XCTAssertEqual((error as? AWSCLIException)?.error.message, "The AWS CLI answered with something Vision couldn't read.")
        }
    }

    func testWhenTheCliStopsEarlyTheAppContinuesFromItsToken() async throws {
        let profiles = allProfiles
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized())
                .onSequence(Fixtures.listProfiles, [
                    .output(page(Array(profiles.prefix(5)), key: "nextToken", token: "T2")),        // a lower-case key works too
                    .output(page(Array(profiles.dropFirst(5).prefix(5)), key: "NextToken", token: "T3")),
                    .output(page(Array(profiles.dropFirst(10)), key: "NextToken", token: "")),      // an empty token ends it
                ])
        }
        let models = try await setup.listModels()
        XCTAssertEqual(cli.calls(to: "bedrock", "list-inference-profiles").count, 3)
        XCTAssertEqual(cli.calls(to: "bedrock", "list-inference-profiles").map { $0.command.contains("--starting-token") ? $0.command.last! : "-" }, ["-", "T2", "T3"])
        // All three pages were used: the same answer as with one page.
        let once = BedrockCatalog.build(foundationModels: BedrockJSONFixtures.foundationModels, inferenceProfiles: BedrockJSONFixtures.inferenceProfiles, region: "us-east-1")
        XCTAssertEqual(models, once)
    }

    func testAnEndlessTokenStopsAtFiftyPages() async throws {
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized())
                .on(Fixtures.listProfiles, page(Array(allProfiles.prefix(3)), key: "NextToken", token: "SAME"))
        }
        _ = try await setup.listModels()
        let profileCalls = cli.calls(to: "bedrock", "list-inference-profiles")
        XCTAssertEqual(profileCalls.count, 50)
        XCTAssertFalse(profileCalls[0].command.contains("--starting-token"))
        for call in profileCalls.dropFirst() { XCTAssertTrue(call.hasPair("--starting-token", "SAME")) }
    }

    func testMissingOrEmptyAnswersGiveNoProfilesNotAnError() async throws {
        for output in ["{}", "", "  \n", #"{"inferenceProfileSummaries": [null, 5, "x"]}"#, #"{"inferenceProfileSummaries": "nope"}"#] {
            let (setup, _) = Fixtures.setup {
                $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized()).on(Fixtures.listProfiles, output)
            }
            let models = try await setup.listModels()
            XCTAssertEqual(models.count, 17, output)
            XCTAssertEqual(models.first { $0.modelID == BedrockJSONFixtures.sonnet45 }?.invokeID, nil, "no profile, no way to call it: \(output)")
        }
        let (setup, _) = Fixtures.setup { $0.on(Fixtures.listModels, "{}").on(Fixtures.listProfiles, "{}") }
        let empty = try await setup.listModels()
        XCTAssertTrue(empty.isEmpty)
    }

    func testTheRegionDecidesWhichProfileIsChosen() async throws {
        for (region, prefix) in [("us-east-1", "us."), ("eu-central-1", "eu."), ("ap-northeast-1", "jp."), ("ap-southeast-2", "au."), ("sa-east-1", "global.")] {
            let (setup, cli) = Fixtures.setup({
                $0.on(Fixtures.listModels, BedrockJSONFixtures.foundationModels.serialized())
                    .on(Fixtures.listProfiles, BedrockJSONFixtures.inferenceProfiles.serialized())
            }, region: region)
            let models = try await setup.listModels()
            XCTAssertEqual(models.first { $0.modelID == BedrockJSONFixtures.sonnet45 }?.invokeID, prefix + BedrockJSONFixtures.sonnet45, region)
            XCTAssertTrue(cli.calls.allSatisfy { $0.region == region }, region)
            XCTAssertEqual(setup.region, region)
        }
    }

    func testTheRealisticCatalogThroughTheCli() async throws {
        let (models, profiles) = BedrockCatalogSpec.parse(BedrockCatalogFixtures.spec)
        let (setup, _) = Fixtures.setup {
            $0.on(Fixtures.listModels, models.serialized()).on(Fixtures.listProfiles, profiles.serialized())
        }
        let listed = try await setup.listModels()
        XCTAssertEqual(listed.map { "\($0.modelID) \($0.invokeID ?? "-") \($0.recommended ? "R" : "-")" },
                       (BedrockCatalogFixtures.expected["us-east-1"] ?? "").components(separatedBy: "\n"))
    }
}

// MARK: - What an account can do with a model

final class BedrockSetupAccessTests: XCTestCase {
    func testSummarizesAvailability() async throws {
        let rows: [(String, String, String, String, ModelAccessState)] = [
            ("AVAILABLE", "AUTHORIZED", "AVAILABLE", "AVAILABLE", .ready),
            ("AVAILABLE", "AUTHORIZED", "AVAILABLE", "NOT_AVAILABLE", .notInRegion),
            ("AVAILABLE", "NOT_AUTHORIZED", "AVAILABLE", "AVAILABLE", .notAuthorized),
            ("PENDING", "AUTHORIZED", "NOT_AVAILABLE", "AVAILABLE", .pending),
            ("AVAILABLE", "AUTHORIZED", "NOT_AVAILABLE", "AVAILABLE", .pending),
            ("NOT_AVAILABLE", "AUTHORIZED", "NOT_AVAILABLE", "AVAILABLE", .needsAgreement),
            ("ERROR", "AUTHORIZED", "NOT_AVAILABLE", "AVAILABLE", .error),
            ("NOT_AVAILABLE", "NOT_AUTHORIZED", "NOT_AVAILABLE", "NOT_AVAILABLE", .notInRegion),
        ]
        for (agreement, authorization, entitlement, region, state) in rows {
            let (setup, cli) = Fixtures.setup {
                $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: agreement, authorization: authorization, entitlement: entitlement,
                                                                     region: region, error: "Payment instrument declined"))
                    .on(Fixtures.listOffers, Fixtures.offers)
            }
            let access = try await setup.checkAccess(Fixtures.cohere)
            let label = "\(agreement)/\(authorization)/\(entitlement)/\(region)"
            XCTAssertEqual(access.state, state, label)
            XCTAssertEqual(access.isReady, state == .ready, label)
            XCTAssertEqual(access.modelID, "cohere.command-r-plus-v1:0", label)
            XCTAssertFalse(access.message.trimmingCharacters(in: .whitespaces).isEmpty, label)
            XCTAssertEqual(access.availability?.agreement, agreement, label)
            XCTAssertTrue(cli.calls(to: "bedrock", "get-use-case-for-model-access").isEmpty, "not an Anthropic model: \(label)")
            if state == .notAuthorized { XCTAssertEqual(access.missingPermissions, BedrockPermissions.invokeActions) }
            if state == .error { XCTAssertTrue(access.message.contains("Payment instrument declined")) }
            if state == .notInRegion { XCTAssertTrue(access.message.contains("US East (N. Virginia)")) }
        }
    }

    func testShowsTheTermsToAccept() async throws {
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE", entitlement: "NOT_AVAILABLE")).on(Fixtures.listOffers, Fixtures.offers)
        }
        let access = try await setup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(access.state, .needsAgreement)
        XCTAssertTrue(access.canAcceptInApp)
        let offer = try XCTUnwrap(access.offer)
        XCTAssertEqual(offer.offerToken, "eyJvZmZlcklkIjoib2ZmZXItM2syIn0=")
        XCTAssertEqual(offer.offerID, "offer-3k2l5j6h7g8f")
        XCTAssertEqual(offer.legalTermsURL, "https://aws-mp-legal-docs.s3.amazonaws.com/eula/cohere.pdf")
        XCTAssertEqual(offer.pricingSummary, "Input tokens (per 1K): US$0.0030; OutputTokenCount: US$0.0150 per 1K tokens")
        XCTAssertEqual(offer.refundPolicy, "No refunds for usage already billed.")
        XCTAssertEqual(offer.durationText, "1 year")
        XCTAssertEqual(offer.prices.count, 2)
        XCTAssertEqual(cli.calls(to: "bedrock", "list-foundation-model-agreement-offers").first?.command,
                       ["bedrock", "list-foundation-model-agreement-offers", "--model-id", "cohere.command-r-plus-v1:0"])
        XCTAssertNil(access.missingPermissions)
        XCTAssertNil(access.useCaseSubmitted, "not an Anthropic model")
    }

    func testNoOfferMeansAwsSubscribesOnFirstUse() async throws {
        for offers in [#"{"modelId": "x", "offers": []}"#, "{}", ""] {
            let (setup, _) = Fixtures.setup {
                $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE")).on(Fixtures.listOffers, offers)
            }
            let access = try await setup.checkAccess(Fixtures.cohere)
            XCTAssertEqual(access.state, .needsAgreement, offers)
            XCTAssertNil(access.offer)
            XCTAssertFalse(access.canAcceptInApp)
            XCTAssertTrue(access.message.contains("first time"))
            XCTAssertNil(access.missingPermissions, "nothing was refused")
        }
    }

    func testOffersThatCantBeReadNameThePermission() async throws {
        let (setup, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE"))
                .fail(Fixtures.listOffers, .accessDeniedWithoutAction(operation: "ListFoundationModelAgreementOffers", message: "Access denied"))
        }
        let access = try await setup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(access.state, .needsAgreement)
        XCTAssertEqual(access.missingPermissions, ["bedrock:ListFoundationModelAgreementOffers"])
        XCTAssertNil(access.offer)
        // A permission AWS names is the one reported.
        let (named, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE"))
                .fail(Fixtures.listOffers, .accessDenied(operation: "ListFoundationModelAgreementOffers", permission: "aws-marketplace:ViewSubscriptions"))
        }
        let other = try await named.checkAccess(Fixtures.cohere)
        XCTAssertEqual(other.missingPermissions, ["aws-marketplace:ViewSubscriptions"])
    }

    func testOtherOfferFailuresAreNotSwallowed() async {
        let (throttled, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE")).fail(Fixtures.listOffers, .throttled(operation: "ListFoundationModelAgreementOffers"))
        }
        await assertSetupThrows(try await throttled.checkAccess(Fixtures.cohere)) { XCTAssertEqual(($0 as? AWSCLIException)?.kind, .throttled) }
        let (signedOut, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE")).fail(Fixtures.listOffers, .ssoExpired)
        }
        await assertSetupThrows(try await signedOut.checkAccess(Fixtures.cohere)) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testAnthropicModelsNeedTheUseCaseFormFirst() async throws {
        let (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE", entitlement: "NOT_AVAILABLE")).fail(Fixtures.getUseCase, Fixtures.useCaseNotFound)
        }
        let access = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(access.state, .needsUseCaseForm)
        XCTAssertEqual(access.useCaseSubmitted, false)
        XCTAssertTrue(access.message.contains("Anthropic"))
        XCTAssertEqual(access.message, "Anthropic asks each AWS account once for a few details about how its models will be used. Fill in the short form and Vision sends it for you.")
        // Checked by the base model id, never the inference profile id.
        XCTAssertTrue(cli.calls(to: "bedrock", "get-foundation-model-availability")[0].hasPair("--model-id", "anthropic.claude-sonnet-4-5-20250929-v1:0"))
        XCTAssertTrue(cli.calls(to: "bedrock", "list-foundation-model-agreement-offers").isEmpty)
        XCTAssertNotNil(access.availability)
        XCTAssertNil(access.offer)
    }

    func testAnthropicModelsWithTheFormOnFileAreReady() async throws {
        let (setup, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability()).on(Fixtures.getUseCase, #"{"formData": "\#(Fixtures.acme.toBase64())"}"#)
        }
        let access = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(access.state, .ready)
        XCTAssertEqual(access.useCaseSubmitted, true)
        XCTAssertEqual(access.message, "Claude Sonnet 4.5 is ready to use.")
    }

    func testAFormThatCantBeCheckedDoesntBlock() async throws {
        for failure in [ScriptedCLIFailure.accessDeniedWithoutAction(operation: "GetUseCaseForModelAccess", message: "denied"),
                        .service(code: "InternalServerException", operation: "GetUseCaseForModelAccess", message: "Internal error."),
                        .throttled(operation: "GetUseCaseForModelAccess"),
                        .validation(operation: "GetUseCaseForModelAccess", message: "Bad request")] {
            let (setup, _) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()).fail(Fixtures.getUseCase, failure) }
            let access = try await setup.checkAccess(Fixtures.sonnet)
            XCTAssertEqual(access.state, .ready)
            XCTAssertNil(access.useCaseSubmitted)
        }
    }

    func testTheFormIsMissingWhateverWayAwsSaysSo() async throws {
        let outputs: [(String, ScriptedAWSCLI.Step)] = [
            ("not found error", .fail(Fixtures.useCaseNotFound)),
            ("a not-found error that doesn't say so", .fail(.notFound(operation: "GetUseCaseForModelAccess", message: "No such form"))),
            ("the words \"not found\" in another error", .fail(.validation(operation: "GetUseCaseForModelAccess", message: "The form was NOT FOUND for this account"))),
            ("an empty form", .output(#"{"formData": ""}"#)),
            ("no form field", .output("{}")),
            ("a form that isn't text", .output(#"{"formData": 5}"#)),
            ("no output", .output("")),
        ]
        for (label, step) in outputs {
            let (setup, _) = Fixtures.setup {
                $0.on(Fixtures.getAvailability, Fixtures.availability()).onSequence(Fixtures.getUseCase, [step])
            }
            let access = try await setup.checkAccess(Fixtures.sonnet)
            XCTAssertEqual(access.state, .needsUseCaseForm, label)
            XCTAssertEqual(access.useCaseSubmitted, false, label)
        }
    }

    func testASignInThatRanOutWhileCheckingTheFormIsNotAState() async {
        let (setup, _) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()).fail(Fixtures.getUseCase, .ssoExpired) }
        await assertSetupThrows(try await setup.checkAccess(Fixtures.sonnet)) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testCheckFailuresAreStatesNotCrashes() async throws {
        let (deniedSetup, _) = Fixtures.setup {
            $0.fail(Fixtures.getAvailability, .accessDenied(operation: "GetFoundationModelAvailability", permission: "bedrock:GetFoundationModelAvailability"))
        }
        let denied = try await deniedSetup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(denied.state, .notAuthorized)
        XCTAssertEqual(denied.missingPermissions, ["bedrock:GetFoundationModelAvailability"])
        XCTAssertTrue(denied.message.contains("try the model"))
        XCTAssertEqual(denied.message, "Vision can't check access to Command R+: your AWS permissions don't allow bedrock:GetFoundationModelAvailability. Ask whoever manages your AWS account to add the policy Vision shows — or just try the model.")
        XCTAssertNil(denied.availability)

        let (unknownSetup, _) = Fixtures.setup {
            $0.fail(Fixtures.getAvailability, .notFound(operation: "GetFoundationModelAvailability", message: "Model not found."))
        }
        let unknown = try await unknownSetup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(unknown.state, .notInRegion)
        XCTAssertEqual(unknown.message, "Command R+ isn't offered in US East (N. Virginia). Pick another model or Region.")

        let (brokenSetup, _) = Fixtures.setup {
            $0.fail(Fixtures.getAvailability, .service(code: "InternalServerException", operation: "GetFoundationModelAvailability", message: "Internal error."))
        }
        let broken = try await brokenSetup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(broken.state, .error)
        XCTAssertEqual(broken.message, "Internal error.")

        for failure in [ScriptedCLIFailure.throttled(operation: "GetFoundationModelAvailability"),
                        .validation(operation: "GetFoundationModelAvailability", message: "bad id"),
                        .conflict(operation: "GetFoundationModelAvailability", message: "busy")] {
            let (setup, _) = Fixtures.setup { $0.fail(Fixtures.getAvailability, failure) }
            let access = try await setup.checkAccess(Fixtures.cohere)
            XCTAssertEqual(access.state, .error)
            XCTAssertFalse(access.message.isEmpty)
        }

        let (signedOut, _) = Fixtures.setup { $0.fail(Fixtures.getAvailability, .ssoExpired) }
        await assertSetupThrows(try await signedOut.checkAccess(Fixtures.cohere)) { error in
            XCTAssertEqual((error as? AWSSignInRequiredError)?.profile, "vision-bedrock")
        }
    }

    func testAnAccessDeniedThatNamesNoActionIsNamedAfterTheOperation() async throws {
        let (setup, _) = Fixtures.setup { $0.fail(Fixtures.getAvailability, .accessDeniedWithoutAction(operation: "GetFoundationModelAvailability")) }
        let access = try await setup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(access.missingPermissions, ["bedrock:GetFoundationModelAvailability"])
    }

    func testARefusalThatNamesNothingIsNamedAfterWhatWasAsked() async throws {
        let (availability, _) = Fixtures.setup { $0.fail(Fixtures.getAvailability, .accessDeniedUnnamed) }
        let checked = try await availability.checkAccess(Fixtures.cohere)
        XCTAssertEqual(checked.state, .notAuthorized)
        XCTAssertEqual(checked.missingPermissions, ["bedrock:GetFoundationModelAvailability"])
        XCTAssertEqual(checked.message, "Vision can't check access to Command R+: your AWS permissions don't allow bedrock:GetFoundationModelAvailability. Ask whoever manages your AWS account to add the policy Vision shows — or just try the model.")

        let (offers, _) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE")).fail(Fixtures.listOffers, .accessDeniedUnnamed)
        }
        let terms = try await offers.checkAccess(Fixtures.cohere)
        XCTAssertEqual(terms.state, .needsAgreement)
        XCTAssertEqual(terms.missingPermissions, ["bedrock:ListFoundationModelAgreementOffers"])
        XCTAssertNil(terms.offer)

        let (others, _) = Fixtures.setup { $0.fail(Fixtures.createAgreement, .accessDeniedUnnamed).fail(Fixtures.getUseCase, .accessDeniedUnnamed) }
        await assertSetupThrows(try await others.acceptAgreement(modelID: "m", offerToken: "t")) { error in
            XCTAssertEqual((error as? AWSCLIException)?.kind, .accessDenied)
            XCTAssertNil((error as? AWSCLIException)?.error.permission)
        }
        let onFile = try await others.useCaseOnFile()
        XCTAssertNil(onFile)
    }

    func testEveryMessageForEveryState() async throws {
        func access(_ availability: String, model: BedrockModel = Fixtures.cohere, useCase: ScriptedAWSCLI.Step? = nil, offers: String? = nil,
                    region: String = "us-east-1") async throws -> ModelAccess {
            let (setup, _) = Fixtures.setup({
                $0.on(Fixtures.getAvailability, availability)
                if let useCase { $0.onSequence(Fixtures.getUseCase, [useCase]) }
                if let offers { $0.on(Fixtures.listOffers, offers) }
            }, region: region)
            return try await setup.checkAccess(model)
        }
        let ready = try await access(Fixtures.availability())
        XCTAssertEqual(ready.message, "Command R+ is ready to use.")
        let notInRegion = try await access(Fixtures.availability(region: "NOT_AVAILABLE"), region: "eu-central-1")
        XCTAssertEqual(notInRegion.message, "Command R+ isn't offered in Europe (Frankfurt). Pick another model or Region.")
        let unlisted = try await access(Fixtures.availability(region: "NOT_AVAILABLE"), region: "il-central-1")
        XCTAssertEqual(unlisted.message, "Command R+ isn't offered in il-central-1. Pick another model or Region.")
        let unauthorized = try await access(Fixtures.availability(authorization: "NOT_AUTHORIZED"))
        XCTAssertEqual(unauthorized.message, "Your AWS permissions don't allow using Command R+. Ask whoever manages your AWS account to allow bedrock:InvokeModel and bedrock:InvokeModelWithResponseStream — Vision can show the exact policy to send them.")
        XCTAssertEqual(unauthorized.missingPermissions, ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
        let withDetails = try await access(Fixtures.availability(agreement: "ERROR", error: "Payment instrument declined"))
        XCTAssertEqual(withDetails.message, "AWS reported a problem with access to Command R+: Payment instrument declined.")
        let noDetails = try await access(Fixtures.availability(agreement: "ERROR"))
        XCTAssertEqual(noDetails.message, "AWS reported a problem with access to Command R+: no details given.")
        let form = try await access(Fixtures.availability(), model: Fixtures.sonnet, useCase: .fail(Fixtures.useCaseNotFound))
        XCTAssertEqual(form.state, .needsUseCaseForm)
        let terms = try await access(Fixtures.availability(agreement: "NOT_AVAILABLE"), offers: Fixtures.offers)
        XCTAssertEqual(terms.message, "Command R+ is sold through AWS Marketplace. Review its terms and prices, then accept them to subscribe — usage is billed to your AWS account.")
        let noTerms = try await access(Fixtures.availability(agreement: "NOT_AVAILABLE"), offers: "{}")
        XCTAssertEqual(noTerms.message, "Command R+ is sold through AWS Marketplace. AWS subscribes your account the first time the model is used; that can take up to 15 minutes.")
        let pending = try await access(Fixtures.availability(agreement: "PENDING"))
        XCTAssertEqual(pending.message, "AWS is setting up your access to Command R+. This can take up to 15 minutes.")
        let entitlement = try await access(Fixtures.availability(entitlement: "NOT_AVAILABLE"))
        XCTAssertEqual(entitlement.state, .pending)
    }

    func testTheNameShownIsTheOneGivenOtherwiseTheId() async throws {
        let (setup, _) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()) }
        let byID = try await setup.checkAccess(modelID: "meta.llama3-70b-instruct-v1:0")
        XCTAssertEqual(byID.message, "meta.llama3-70b-instruct-v1:0 is ready to use.")
        for blank in [nil, "", "   ", "\t\n"] as [String?] {
            let access = try await setup.checkAccess(modelID: "acme.model", name: blank)
            XCTAssertEqual(access.message, "acme.model is ready to use.", "\(String(describing: blank))")
        }
        let named = try await setup.checkAccess(modelID: "meta.llama3-70b-instruct-v1:0", name: "  Llama 70B ")
        XCTAssertEqual(named.message, "  Llama 70B  is ready to use.", "a name that isn't blank is shown as given")
        XCTAssertEqual(named.modelID, "meta.llama3-70b-instruct-v1:0")
    }

    func testWhetherAModelNeedsTheFormIsDecidedByItsIdOrTheCallersWord() async throws {
        func asks(_ id: String, _ isAnthropic: Bool?) async throws -> Bool {
            let (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()).on(Fixtures.getUseCase, #"{"formData": "x"}"#) }
            _ = try await setup.checkAccess(modelID: id, name: nil, isAnthropic: isAnthropic)
            return !cli.calls(to: "bedrock", "get-use-case-for-model-access").isEmpty
        }
        let a1 = try await asks("anthropic.claude-3-haiku-20240307-v1:0", nil)
        XCTAssertTrue(a1)
        let a2 = try await asks("ANTHROPIC.claude-x", nil)
        XCTAssertTrue(a2)
        let a3 = try await asks("meta.llama3", nil)
        XCTAssertFalse(a3)
        let a4 = try await asks("meta.llama3", true)
        XCTAssertTrue(a4)
        let a5 = try await asks("anthropic.claude-3-haiku-20240307-v1:0", false)
        XCTAssertFalse(a5)
        let a6 = try await asks("us.anthropic.claude-sonnet-4-5-20250929-v1:0", nil)
        XCTAssertFalse(a6, "a profile id doesn't start with the provider")
    }

    func testChecksNeverAskForMoreThanTheStateNeeds() async throws {
        // Not in the Region: nothing else is asked.
        var (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability(region: "NOT_AVAILABLE")) }
        _ = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(cli.calls.map(\.joined), ["bedrock get-foundation-model-availability --model-id anthropic.claude-sonnet-4-5-20250929-v1:0"])
        // Not authorized: nothing else.
        (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability(authorization: "NOT_AUTHORIZED")) }
        _ = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(cli.calls.count, 1)
        // An agreement error: nothing else.
        (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "ERROR")) }
        _ = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(cli.calls.count, 1)
        // Ready and Anthropic's: the form is looked up, no offers.
        (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()).on(Fixtures.getUseCase, #"{"formData":"x"}"#) }
        _ = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(cli.calls.map { $0.command[1] }, ["get-foundation-model-availability", "get-use-case-for-model-access"])
        // Terms to accept: the form first, then the offers.
        (setup, cli) = Fixtures.setup {
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "NOT_AVAILABLE")).on(Fixtures.getUseCase, #"{"formData":"x"}"#).on(Fixtures.listOffers, Fixtures.offers)
        }
        _ = try await setup.checkAccess(Fixtures.sonnet)
        XCTAssertEqual(cli.calls.map { $0.command[1] }, ["get-foundation-model-availability", "get-use-case-for-model-access", "list-foundation-model-agreement-offers"])
        XCTAssertTrue(cli.calls.allSatisfy { $0.profile == "vision-bedrock" && $0.region == "us-east-1" && $0.timeout == nil })
    }

    func testOddAnswersFromAwsReadAsMissingFields() async throws {
        for output in ["{}", "", "[]", "null", #""text""#, #"{"agreementAvailability": "AVAILABLE"}"#, #"{"agreementAvailability": null, "authorizationStatus": null}"#] {
            let (setup, _) = Fixtures.setup { $0.on(Fixtures.getAvailability, output) }
            let access = try await setup.checkAccess(Fixtures.cohere)
            // Nothing says otherwise, so nothing stands in the way: usable now.
            XCTAssertEqual(access.state, .ready, output)
            XCTAssertEqual(access.availability, BedrockAvailability(agreement: "", agreementError: nil, authorization: "", entitlement: "", region: ""), output)
        }
        let (setup, _) = Fixtures.setup { $0.on(Fixtures.getAvailability, "this is not json") }
        let unreadable = try await setup.checkAccess(Fixtures.cohere)
        XCTAssertEqual(unreadable.state, .error)
        XCTAssertEqual(unreadable.message, "The AWS CLI answered with something Vision couldn't read.")
    }

    func testTheUseCaseOnFileIsTrueFalseOrUnknown() async throws {
        let cases: [(String, ScriptedAWSCLI.Step, Bool?)] = [
            ("a form", .output(#"{"formData": "e30="}"#), true),
            ("an empty form", .output(#"{"formData": ""}"#), false),
            ("no form field", .output("{}"), false),
            ("not found", .fail(Fixtures.useCaseNotFound), false),
            ("a not-found error that doesn't say so", .fail(.notFound(operation: "GetUseCaseForModelAccess", message: "No such form")), false),
            ("\"not found\" in the details", .fail(.validation(operation: "GetUseCaseForModelAccess", message: "Not Found")), false),
            ("denied", .fail(.accessDeniedWithoutAction(operation: "GetUseCaseForModelAccess")), nil),
            ("an internal error", .fail(.service(code: "InternalServerException", operation: "GetUseCaseForModelAccess", message: "oops")), nil),
            ("throttled", .fail(.throttled(operation: "GetUseCaseForModelAccess")), nil),
            ("unreadable output", .output("garbage"), nil),
        ]
        for (label, step, expected) in cases {
            let (setup, _) = Fixtures.setup { $0.onSequence(Fixtures.getUseCase, [step]) }
            let onFile = try await setup.useCaseOnFile()
            XCTAssertEqual(onFile, expected, label)
        }
        let (signedOut, _) = Fixtures.setup { $0.fail(Fixtures.getUseCase, .ssoExpired) }
        await assertSetupThrows(try await signedOut.useCaseOnFile()) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testTheFormOnFileIsReadBackOrNothing() async throws {
        let (found, _) = Fixtures.setup { $0.on(Fixtures.getUseCase, #"{"formData": "\#(Fixtures.acme.toBase64())"}"#) }
        let form = try await found.getUseCase()
        XCTAssertEqual(form, Fixtures.acme)
        for output in ["{}", #"{"formData": ""}"#, #"{"formData": "not a form"}"#, #"{"formData": "e30"}"#] {
            let (setup, _) = Fixtures.setup { $0.on(Fixtures.getUseCase, output) }
            let none = try await setup.getUseCase()
            XCTAssertNil(none, output)
        }
        for failure in [Fixtures.useCaseNotFound, .accessDeniedWithoutAction(operation: "GetUseCaseForModelAccess"), .throttled(operation: "x")] {
            let (setup, _) = Fixtures.setup { $0.fail(Fixtures.getUseCase, failure) }
            let none = try await setup.getUseCase()
            XCTAssertNil(none)
        }
        let (signedOut, _) = Fixtures.setup { $0.fail(Fixtures.getUseCase, .ssoExpired) }
        await assertSetupThrows(try await signedOut.getUseCase()) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testCancellingStopsACheckBeforeItAsksAws() async {
        let (setup, cli) = Fixtures.setup { $0.on(Fixtures.getAvailability, Fixtures.availability()) }
        let outcome = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await setup.checkAccess(Fixtures.cohere)
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertTrue(cli.calls.isEmpty)
    }
}

// MARK: - Every combination of what AWS can say

final class BedrockAccessMatrixTests: XCTestCase {
    /// The rules of `checkAccess`, restated from the Windows source as a chain, for checking every combination.
    private func expected(agreement: String?, authorization: String?, entitlement: String?, region: String?,
                          anthropic: Bool, form: FormState) -> ModelAccessState {
        func is_(_ value: String?, _ word: String) -> Bool { value?.uppercased() == word }
        if is_(region, "NOT_AVAILABLE") { return .notInRegion }
        if is_(authorization, "NOT_AUTHORIZED") { return .notAuthorized }
        if is_(agreement, "ERROR") { return .error }
        if anthropic && form == .missing { return .needsUseCaseForm }
        if is_(agreement, "NOT_AVAILABLE") { return .needsAgreement }
        if is_(agreement, "PENDING") || is_(entitlement, "NOT_AVAILABLE") { return .pending }
        return .ready
    }

    enum FormState { case onFile, missing, unknown }

    func testEveryCombinationEndsInTheStateTheRulesGive() async throws {
        let agreements: [String?] = ["AVAILABLE", "NOT_AVAILABLE", "PENDING", "ERROR", "available", "not_available", "Pending", "error", nil, "SOMETHING_ELSE"]
        let authorizations: [String?] = ["AUTHORIZED", "NOT_AUTHORIZED", "not_authorized", nil]
        let entitlements: [String?] = ["AVAILABLE", "NOT_AVAILABLE", "not_available", nil]
        let regions: [String?] = ["AVAILABLE", "NOT_AVAILABLE", "not_available", nil]
        var checked = 0
        for agreement in agreements { for authorization in authorizations { for entitlement in entitlements { for region in regions {
            var agreementObject: [String: JSONValue] = [:]
            if let agreement { agreementObject["status"] = .string(agreement) }
            if agreement?.uppercased() == "ERROR" { agreementObject["errorMessage"] = "declined" }
            var object: [String: JSONValue] = ["agreementAvailability": .object(agreementObject)]
            if let authorization { object["authorizationStatus"] = .string(authorization) }
            if let entitlement { object["entitlementAvailability"] = .string(entitlement) }
            if let region { object["regionAvailability"] = .string(region) }
            let json = JSONValue.object(object).serialized()

            for (model, formState): (BedrockModel, FormState) in [(Fixtures.cohere, .onFile), (Fixtures.sonnet, .onFile), (Fixtures.sonnet, .missing), (Fixtures.sonnet, .unknown)] {
                let (setup, cli) = Fixtures.setup {
                    $0.on(Fixtures.getAvailability, json).on(Fixtures.listOffers, Fixtures.offers)
                    switch formState {
                    case .onFile: $0.on(Fixtures.getUseCase, #"{"formData":"e30="}"#)
                    case .missing: $0.fail(Fixtures.getUseCase, Fixtures.useCaseNotFound)
                    case .unknown: $0.fail(Fixtures.getUseCase, .accessDeniedWithoutAction(operation: "GetUseCaseForModelAccess"))
                    }
                }
                let access = try await setup.checkAccess(model)
                let label = "a=\(agreement ?? "-") z=\(authorization ?? "-") e=\(entitlement ?? "-") r=\(region ?? "-") \(model.isAnthropic ? "anthropic" : "other") form=\(formState)"
                let state = expected(agreement: agreement, authorization: authorization, entitlement: entitlement, region: region,
                                     anthropic: model.isAnthropic, form: formState)
                XCTAssertEqual(access.state, state, label)
                XCTAssertEqual(access.isReady, state == .ready, label)
                XCTAssertEqual(access.canAcceptInApp, state == .needsAgreement, label)
                XCTAssertEqual(access.modelID, model.modelID, label)
                XCTAssertFalse(access.message.isEmpty, label)
                XCTAssertNotNil(access.availability, label)
                // What goes with each state.
                XCTAssertEqual(access.offer != nil, state == .needsAgreement, label)
                XCTAssertEqual(access.missingPermissions != nil, state == .notAuthorized, label)
                let blocked = region?.uppercased() == "NOT_AVAILABLE" || authorization?.uppercased() == "NOT_AUTHORIZED" || agreement?.uppercased() == "ERROR"
                let formLookedUp = model.isAnthropic && !blocked
                XCTAssertEqual(!cli.calls(to: "bedrock", "get-use-case-for-model-access").isEmpty, formLookedUp, label)
                if formLookedUp {
                    XCTAssertEqual(access.useCaseSubmitted, formState == .onFile ? true : formState == .missing ? false : nil, label)
                } else {
                    XCTAssertNil(access.useCaseSubmitted, label)
                }
                XCTAssertEqual(!cli.calls(to: "bedrock", "list-foundation-model-agreement-offers").isEmpty, state == .needsAgreement, label)
                checked += 1
            }
        } } } }
        XCTAssertEqual(checked, 640 * 4)
    }
}

// MARK: - The form, the terms, and waiting

final class BedrockSetupFormAndAgreementTests: XCTestCase {
    func testSubmitsTheFormAsBase64() async throws {
        let (setup, cli) = Fixtures.setup { $0.fail(Fixtures.getUseCase, Fixtures.useCaseNotFound).on(Fixtures.putUseCase, "") }
        let outcome = try await setup.submitUseCase(Fixtures.acme)
        XCTAssertEqual(outcome, .submitted)
        let puts = cli.calls(to: "bedrock", "put-use-case-for-model-access")
        XCTAssertEqual(puts.count, 1)
        let put = try XCTUnwrap(puts.first)
        XCTAssertEqual(put.command, ["bedrock", "put-use-case-for-model-access", "--form-data", Fixtures.acme.toBase64(), "--cli-binary-format", "base64"])
        XCTAssertEqual(put.kind, .checked)
        XCTAssertEqual(put.profile, "vision-bedrock")
        XCTAssertEqual(put.region, "us-east-1")
        XCTAssertEqual(String(decoding: Data(base64Encoded: put.command[3])!, as: UTF8.self), Fixtures.acme.toJSON())
        XCTAssertEqual(BedrockSetup.submitUseCaseCommand(Fixtures.acme), put.command)
    }

    func testAFormAlreadyOnFileIsntSentAgain() async throws {
        let (setup, cli) = Fixtures.setup { $0.on(Fixtures.getUseCase, #"{"formData": "\#(Fixtures.acme.toBase64())"}"#) }
        let outcome = try await setup.submitUseCase(Fixtures.acme)
        XCTAssertEqual(outcome, .alreadyOnFile)
        XCTAssertTrue(cli.calls(to: "bedrock", "put-use-case-for-model-access").isEmpty)
        let onFile = try await setup.getUseCase()
        XCTAssertEqual(onFile, Fixtures.acme)
    }

    func testAnIncompleteFormIsntSent() async {
        let (setup, cli) = Fixtures.setup()
        var form = Fixtures.acme
        form.companyWebsite = ""
        await assertSetupThrows(try await setup.submitUseCase(form)) { error in
            XCTAssertTrue(error is BedrockSetupArgumentError)
            XCTAssertTrue(error.localizedDescription.contains("website"))
            XCTAssertEqual(error.localizedDescription, "Enter your company's website, like https://example.com.")
        }
        XCTAssertTrue(cli.calls.isEmpty)
    }

    func testAFormThatCantBeCheckedIsStillSent() async throws {
        for failure in [ScriptedCLIFailure.accessDeniedWithoutAction(operation: "GetUseCaseForModelAccess"),
                        .service(code: "InternalServerException", operation: "GetUseCaseForModelAccess", message: "Internal error.")] {
            let (setup, cli) = Fixtures.setup { $0.fail(Fixtures.getUseCase, failure).on(Fixtures.putUseCase, "") }
            let outcome = try await setup.submitUseCase(Fixtures.acme)
            XCTAssertEqual(outcome, .submitted)
            XCTAssertEqual(cli.calls(to: "bedrock", "put-use-case-for-model-access").count, 1)
        }
    }

    func testAFormAwsRefusesIsAnError() async {
        let (denied, _) = Fixtures.setup {
            $0.fail(Fixtures.getUseCase, Fixtures.useCaseNotFound)
                .fail(Fixtures.putUseCase, .accessDenied(operation: "PutUseCaseForModelAccess", permission: "bedrock:PutUseCaseForModelAccess"))
        }
        await assertSetupThrows(try await denied.submitUseCase(Fixtures.acme)) { error in
            XCTAssertEqual((error as? AWSCLIException)?.error.permission, "bedrock:PutUseCaseForModelAccess")
        }
        let (invalid, _) = Fixtures.setup {
            $0.fail(Fixtures.getUseCase, Fixtures.useCaseNotFound).fail(Fixtures.putUseCase, .validation(operation: "PutUseCaseForModelAccess", message: "Bad form"))
        }
        await assertSetupThrows(try await invalid.submitUseCase(Fixtures.acme)) { error in
            XCTAssertEqual((error as? AWSCLIException)?.error.message, "AWS didn't accept the request: Bad form")
        }
        let (signedOut, _) = Fixtures.setup { $0.fail(Fixtures.getUseCase, .ssoExpired) }
        await assertSetupThrows(try await signedOut.submitUseCase(Fixtures.acme)) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testAcceptsAnOffer() async throws {
        let (setup, cli) = Fixtures.setup { $0.on(Fixtures.createAgreement, #"{"modelId": "cohere.command-r-plus-v1:0"}"#) }
        try await setup.acceptAgreement(modelID: "cohere.command-r-plus-v1:0", offerToken: "eyJvZmZlcklkIjoib2ZmZXItM2syIn0=")
        XCTAssertEqual(cli.calls.count, 1)
        XCTAssertEqual(cli.calls[0].command, ["bedrock", "create-foundation-model-agreement", "--model-id", "cohere.command-r-plus-v1:0",
                                              "--offer-token", "eyJvZmZlcklkIjoib2ZmZXItM2syIn0="])
        XCTAssertEqual(cli.calls[0].kind, .checked)
        XCTAssertEqual(cli.calls[0].profile, "vision-bedrock")
        XCTAssertEqual(cli.calls[0].region, "us-east-1")
    }

    func testAnAgreementInProgressCountsAsAccepted() async throws {
        let (conflict, _) = Fixtures.setup { $0.fail(Fixtures.createAgreement, .conflict(operation: "CreateFoundationModelAgreement", message: "Agreement already exists.")) }
        try await conflict.acceptAgreement(modelID: "cohere.command-r-plus-v1:0", offerToken: "token")

        let (denied, _) = Fixtures.setup {
            $0.fail(Fixtures.createAgreement, .accessDenied(operation: "CreateFoundationModelAgreement", permission: "aws-marketplace:Subscribe"))
        }
        await assertSetupThrows(try await denied.acceptAgreement(modelID: "cohere.command-r-plus-v1:0", offerToken: "token")) { error in
            XCTAssertEqual((error as? AWSCLIException)?.error.permission, "aws-marketplace:Subscribe")
        }
        let (invalid, _) = Fixtures.setup { $0.fail(Fixtures.createAgreement, .validation(operation: "CreateFoundationModelAgreement", message: "Bad token")) }
        await assertSetupThrows(try await invalid.acceptAgreement(modelID: "m", offerToken: "t")) { XCTAssertEqual(($0 as? AWSCLIException)?.kind, .invalid) }
        let (signedOut, _) = Fixtures.setup { $0.fail(Fixtures.createAgreement, .ssoExpired) }
        await assertSetupThrows(try await signedOut.acceptAgreement(modelID: "m", offerToken: "t")) { XCTAssertNotNil($0 as? AWSSignInRequiredError) }
    }

    func testABlankModelOrOfferIsNotSent() async {
        for (model, token) in [("", "t"), ("  ", "t"), ("m", ""), ("m", "  \n")] {
            let (setup, cli) = Fixtures.setup()
            await assertSetupThrows(try await setup.acceptAgreement(modelID: model, offerToken: token)) { XCTAssertTrue($0 is BedrockSetupArgumentError) }
            XCTAssertTrue(cli.calls.isEmpty)
        }
    }

    func testTheAppRefusesAnEmptyProfileOrRegionOnlyByProgrammingError() {
        // (The initialiser preconditions a non-blank profile and Region; the guide never passes blanks.)
        let setup = BedrockSetup(cli: ScriptedAWSCLI(), profile: " p ", region: "r")
        XCTAssertEqual(setup.profile, " p ", "given values are kept as they are")
        XCTAssertEqual(setup.region, "r")
    }
}

final class BedrockSetupWaitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func steps(_ jsons: [String]) -> [ScriptedAWSCLI.Step] { jsons.map { .output($0) } }

    private func run(_ jsons: [String], timeout: TimeInterval? = nil, poll: TimeInterval? = nil, model: BedrockModel = Fixtures.cohere,
                     cancelOnFirstReport: Bool = false, signInInstead: Bool = false)
    async -> (outcome: String, reported: [ModelAccessState], checks: Int, elapsed: TimeInterval, delays: [TimeInterval], cli: ScriptedAWSCLI) {
        let clock = BedrockWaitClock(start: start)
        let (setup, cli) = Fixtures.setup({
            $0.onSequence(Fixtures.getAvailability, signInInstead ? [.fail(.ssoExpired)] : steps(jsons))
            $0.on(Fixtures.listOffers, Fixtures.offers)
            $0.fail(Fixtures.getUseCase, Fixtures.useCaseNotFound)
        }, clock: clock)
        let log = BedrockProgressLog<ModelAccess>()
        let outcome = await Task { () -> String in
            if cancelOnFirstReport { log.onReport = { _ in withUnsafeCurrentTask { $0?.cancel() } } }
            do {
                let final = try await setup.waitUntilReady(model, progress: log.callback, timeout: timeout, pollInterval: poll)
                return "final=\(final.state)"
            } catch is CancellationError {
                return "cancelled"
            } catch is AWSSignInRequiredError {
                return "signin"
            } catch {
                return "other: \(error)"
            }
        }.value
        return (outcome, log.all.map(\.state), cli.calls(to: "bedrock", "get-foundation-model-availability").count, clock.elapsed, clock.delays, cli)
    }

    private func pendingAgreement() -> String { Fixtures.availability(agreement: "NOT_AVAILABLE", entitlement: "NOT_AVAILABLE") }
    private func pending() -> String { Fixtures.availability(agreement: "PENDING", entitlement: "NOT_AVAILABLE") }

    func testWaitsUntilTheSubscriptionIsReady() async {
        // Right after accepting AWS can still say "not available"; then pending; then ready.
        let r = await run([pendingAgreement(), pending(), pending(), Fixtures.availability()], poll: 15)
        XCTAssertEqual(r.outcome, "final=ready")
        XCTAssertEqual(r.reported, [.needsAgreement, .pending, .pending, .ready])
        XCTAssertEqual(r.checks, 4)
        XCTAssertEqual(r.elapsed, 45)
        XCTAssertEqual(r.delays, [15, 15, 15])
    }

    func testReadyAtOnceWaitsNotAtAll() async {
        let r = await run([Fixtures.availability()])
        XCTAssertEqual(r.outcome, "final=ready")
        XCTAssertEqual(r.reported, [.ready])
        XCTAssertEqual(r.checks, 1)
        XCTAssertEqual(r.elapsed, 0)
        XCTAssertEqual(r.delays, [])
    }

    func testStopsWaitingAtTheTimeout() async {
        let r = await run([Fixtures.availability(agreement: "PENDING", entitlement: "NOT_AVAILABLE")], timeout: 60, poll: 20)
        XCTAssertEqual(r.outcome, "final=pending")
        XCTAssertEqual(r.checks, 4, "at 0, 20, 40 and 60 seconds")
        XCTAssertEqual(r.elapsed, 60)
        XCTAssertEqual(r.delays, [20, 20, 20])
        XCTAssertEqual(r.reported, [.pending, .pending, .pending, .pending])
    }

    func testTheLastWaitIsShortenedToTheTimeLeft() async {
        let r = await run([pending()], timeout: 50, poll: 20)
        XCTAssertEqual(r.delays, [20, 20, 10])
        XCTAssertEqual(r.elapsed, 50)
        XCTAssertEqual(r.checks, 4)
        let short = await run([pending()], timeout: 10, poll: 20)
        XCTAssertEqual(short.delays, [10])
        XCTAssertEqual(short.checks, 2)
        XCTAssertEqual(short.elapsed, 10)
    }

    func testTheDefaultsAreFifteenSecondsEveryFifteenMinutes() async {
        let r = await run([pending()])
        XCTAssertEqual(r.checks, 61)
        XCTAssertEqual(r.elapsed, 900)
        XCTAssertEqual(r.delays, Array(repeating: 15, count: 60))
        XCTAssertEqual(r.outcome, "final=pending")
    }

    func testNoTimeLeftMeansOneCheck() async {
        for timeout: TimeInterval in [0, -5] {
            let r = await run([pending()], timeout: timeout, poll: 20)
            XCTAssertEqual(r.outcome, "final=pending", "\(timeout)")
            XCTAssertEqual(r.checks, 1, "\(timeout)")
            XCTAssertEqual(r.delays, [], "\(timeout)")
        }
    }

    func testStopsWaitingWhenTheUserMustAct() async {
        let cases: [(String, String, String)] = [
            (Fixtures.availability(authorization: "NOT_AUTHORIZED"), "final=notAuthorized", "user-must-act"),
            (Fixtures.availability(agreement: "ERROR"), "final=error", "error"),
            (Fixtures.availability(region: "NOT_AVAILABLE"), "final=notInRegion", "not in Region"),
        ]
        for (json, outcome, label) in cases {
            let r = await run([json])
            XCTAssertEqual(r.outcome, outcome, label)
            XCTAssertEqual(r.checks, 1, label)
            XCTAssertEqual(r.delays, [], label)
        }
        let form = await run([Fixtures.availability()], model: Fixtures.sonnet)
        XCTAssertEqual(form.outcome, "final=needsUseCaseForm", "the Anthropic form isn't on file (the fake has none)")
    }

    func testAnAgreementThenAProblemStops() async {
        let r = await run([pendingAgreement(), Fixtures.availability(authorization: "NOT_AUTHORIZED")], poll: 5)
        XCTAssertEqual(r.outcome, "final=notAuthorized")
        XCTAssertEqual(r.reported, [.needsAgreement, .notAuthorized])
        XCTAssertEqual(r.elapsed, 5)
    }

    func testEachCheckIsReportedAsItHappens() async {
        let r = await run([pendingAgreement(), pending(), Fixtures.availability()], poll: 1)
        XCTAssertEqual(r.reported, [.needsAgreement, .pending, .ready])
        XCTAssertEqual(r.reported.count, r.checks)
    }

    func testWaitingCanBeCancelled() async {
        let r = await run([Fixtures.availability(agreement: "PENDING")], cancelOnFirstReport: true)
        XCTAssertEqual(r.outcome, "cancelled")
        XCTAssertEqual(r.reported, [.pending], "the check that was under way is reported")
        XCTAssertEqual(r.checks, 1)
        XCTAssertEqual(r.delays, [], "and no more waiting or asking follows")
    }

    func testCancellingBeforeStartingAsksNothing() async {
        let clock = BedrockWaitClock(start: start)
        let (setup, cli) = Fixtures.setup({ $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "PENDING")) }, clock: clock)
        let outcome = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await setup.waitUntilReady(Fixtures.cohere)
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertTrue(cli.calls.isEmpty)
    }

    func testCancellingBeforeStartingAsksNothingEvenIfTheCliIgnoresCancellation() async {
        let clock = BedrockWaitClock(start: start)
        let (setup, cli) = Fixtures.setup({
            $0.checksCancellation = false
            $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "PENDING"))
        }, clock: clock)
        let outcome = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await setup.waitUntilReady(Fixtures.cohere)
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertTrue(cli.calls.isEmpty, "the wait looks at cancellation itself, before each check")
    }

    func testCancellationIsNoticedEvenIfTheSleepIgnoresIt() async {
        // A sleep that never throws (and the CLI ignoring cancellation too): the loop must still stop.
        let cli = ScriptedAWSCLI()
        cli.checksCancellation = false
        cli.on(Fixtures.getAvailability, Fixtures.availability(agreement: "PENDING"))
        let setup = BedrockSetup(cli: cli, profile: "vision-bedrock", region: "us-east-1", now: { Date(timeIntervalSince1970: 1_800_000_000) }, sleep: { _ in })
        let log = BedrockProgressLog<ModelAccess>()
        let outcome = await Task { () -> String in
            log.onReport = { _ in withUnsafeCurrentTask { $0?.cancel() } }
            do {
                _ = try await setup.waitUntilReady(Fixtures.cohere, progress: log.callback, timeout: 3600, pollInterval: 1)
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(cli.calls.count, 1, "no second check after the cancellation")
    }

    func testCancellingWhileSleepingEndsTheWait() async {
        let clock = BedrockWaitClock(start: start)
        clock.onSleep = { withUnsafeCurrentTask { $0?.cancel() } }
        let (setup, cli) = Fixtures.setup({ $0.on(Fixtures.getAvailability, Fixtures.availability(agreement: "PENDING")) }, clock: clock)
        let outcome = await Task { () -> String in
            do {
                _ = try await setup.waitUntilReady(Fixtures.cohere)
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other: \(error)"
            }
        }.value
        XCTAssertEqual(outcome, "cancelled")
        XCTAssertEqual(cli.calls(to: "bedrock", "get-foundation-model-availability").count, 1)
    }

    func testASignInThatRunsOutEndsTheWait() async {
        let r = await run([], signInInstead: true)
        XCTAssertEqual(r.outcome, "signin")
        XCTAssertEqual(r.reported, [])
        XCTAssertEqual(r.checks, 1)
    }

    func testTheClockDefaultsWaitForReal() async throws {
        let started = Date()
        try await BedrockSetup.systemSleep(0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.04)
        // Nothing to wait for: returns at once, whatever is asked (including nonsense).
        let quick = Date()
        for seconds: TimeInterval in [0, -1, -1e9, .nan] { try await BedrockSetup.systemSleep(seconds) }
        XCTAssertLessThan(Date().timeIntervalSince(quick), 0.5)
        // A sleeping task can be cancelled.
        let task = Task { try await BedrockSetup.systemSleep(60) }
        task.cancel()
        await assertSetupThrows(try await task.value) { XCTAssertTrue($0 is CancellationError) }
    }
}

// MARK: - Offers, prices and durations

final class BedrockOfferParsingTests: XCTestCase {
    func testDurationsReadNaturally() {
        for (iso, text) in [("P1Y", "1 year"), ("P12M", "12 months"), ("P30D", "30 days"), ("P1Y6M", "1 year, 6 months"), ("Until cancelled", "Until cancelled")] {
            XCTAssertEqual(BedrockSetup.friendlyDuration(iso), text, iso)
        }
    }

    func testDurationsMatchTheWindowsAppOnEveryText() {
        XCTAssertGreaterThan(UseCaseFormCorpora.durations.count, 50)
        for (text, expected) in UseCaseFormCorpora.durations {
            XCTAssertEqual(BedrockSetup.friendlyDuration(text), expected, BedrockFixtureText.escaped(text))
        }
    }

    func testDurationDetails() {
        XCTAssertEqual(BedrockSetup.friendlyDuration("P1Y6M2W3D"), "1 year, 6 months, 2 weeks, 3 days")
        XCTAssertEqual(BedrockSetup.friendlyDuration(" P1Y \n"), "1 year", "trimmed to read it")
        XCTAssertEqual(BedrockSetup.friendlyDuration("P0D"), "P0D", "nothing to say: as given")
        XCTAssertEqual(BedrockSetup.friendlyDuration("P1M1Y"), "P1M1Y", "wrong order: as given")
        XCTAssertEqual(BedrockSetup.friendlyDuration("p1y"), "p1y", "lower case: as given")
        XCTAssertEqual(BedrockSetup.friendlyDuration("PT1H"), "PT1H", "hours aren't read")
        XCTAssertEqual(BedrockSetup.friendlyDuration("P2147483648D"), "P2147483648D", "too big for an Int32")
        XCTAssertEqual(BedrockSetup.friendlyDuration("P1Y99999999999D"), "1 year", "a part too big is left out")
        XCTAssertEqual(BedrockSetup.friendlyDuration("P١Y"), "P١Y", "digits of another script")
        XCTAssertEqual(BedrockSetup.friendlyDuration(""), "")
    }

    func testPricesReadAsTheyAreShown() {
        XCTAssertEqual(ModelPrice(dimension: "InputTokenCount", price: "0.0030", unit: "Units", description: "Input tokens (per 1K)").display, "Input tokens (per 1K): US$0.0030")
        XCTAssertEqual(ModelPrice(dimension: "OutputTokenCount", price: "0.0150", unit: "1K tokens", description: nil).display, "OutputTokenCount: US$0.0150 per 1K tokens")
        XCTAssertEqual(ModelPrice(dimension: "D", price: "1", unit: "units", description: "Desc").display, "Desc: US$1", "\"Units\" in any case adds nothing")
        XCTAssertEqual(ModelPrice(dimension: "D", price: "1", unit: "  ", description: "  ").display, "D: US$1", "blank text is missing text")
        XCTAssertEqual(ModelPrice(dimension: "D", price: "1", unit: nil, description: nil).display, "D: US$1")
        XCTAssertEqual(ModelPrice(dimension: "", price: "?").display, ": US$?")
        XCTAssertEqual(ModelPrice(dimension: "D", price: "1", unit: " 1K tokens ", description: nil).display, "D: US$1 per  1K tokens ", "shown as AWS worded it")
    }

    func testAnOfferSummarisesItsPricesAndDuration() {
        var offer = ModelOffer(offerToken: "t")
        XCTAssertEqual(offer.pricingSummary, "No usage prices are listed in the offer; see the model's page in the AWS console.")
        XCTAssertNil(offer.durationText)
        offer.prices = [ModelPrice(dimension: "Input tokens", price: "0.003"), ModelPrice(dimension: "Output tokens", price: "0.015")]
        XCTAssertEqual(offer.pricingSummary, "Input tokens: US$0.003; Output tokens: US$0.015")
        offer.agreementDuration = "P1Y"
        XCTAssertEqual(offer.durationText, "1 year")
        offer.agreementDuration = "Perpetual"
        XCTAssertEqual(offer.durationText, "Perpetual")
    }

    func testOffersAreReadFromWhateverAwsSends() throws {
        let one = BedrockSetup.parseOffers(JSONValue(parsing: Fixtures.offers))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].offerToken, "eyJvZmZlcklkIjoib2ZmZXItM2syIn0=")
        XCTAssertEqual(one[0].prices, [ModelPrice(dimension: "InputTokenCount", price: "0.0030", unit: "Units", description: "Input tokens (per 1K)"),
                                        ModelPrice(dimension: "OutputTokenCount", price: "0.0150", unit: "1K tokens", description: nil)])
        // Not offers, or offers without a usable token.
        for json in ["{}", "[]", "null", #"{"offers": {"offerToken": "T"}}"#, #"{"offers": "x"}"#, #"{"offers": []}"#] {
            XCTAssertTrue(BedrockSetup.parseOffers(JSONValue(parsing: json)).isEmpty, json)
        }
        XCTAssertTrue(BedrockSetup.parseOffers(nil).isEmpty)
        let junk = BedrockSetup.parseOffers(JSONValue(parsing: #"{"offers": [{"offerToken": ""}, {"offerToken": 5}, {"offerId": "x"}, "text", null, [], {"offerToken": "T"}]}"#))
        XCTAssertEqual(junk, [ModelOffer(offerToken: "T")])

        let odd = BedrockSetup.parseOffers(JSONValue(parsing: """
            {"offers": [{"offerToken": "T1", "offerId": 7, "termDetails": {"usageBasedPricingTerm": {"rateCard": [
              {"dimension": "D", "price": 5}, {"price": "1"}, {"dimension": "X", "price": "2", "unit": "  ", "description": "  "}, "junk", null,
              {"dimension": "Y", "price": "3", "unit": "units", "description": "Desc"}, {"dimension": "Z", "price": "4", "unit": "Million tokens"}]},
              "legalTerm": "x", "supportTerm": null, "validityTerm": {"agreementDuration": 12}}}, {"offerToken": "T2"}]}
            """))
        XCTAssertEqual(odd.map(\.offerToken), ["T1", "T2"])
        XCTAssertNil(odd[0].offerID, "an id that isn't text")
        XCTAssertNil(odd[0].legalTermsURL)
        XCTAssertNil(odd[0].refundPolicy)
        XCTAssertNil(odd[0].agreementDuration)
        XCTAssertEqual(odd[0].prices.map(\.display), ["D: US$?", ": US$1", "X: US$2", "Desc: US$3", "Z: US$4 per Million tokens"], "a price that isn't text reads as ?")
        XCTAssertEqual(odd[0].pricingSummary, "D: US$?; : US$1; X: US$2; Desc: US$3; Z: US$4 per Million tokens")
        XCTAssertTrue(odd[1].prices.isEmpty)
        // Terms of the wrong type give what can be read.
        let wrong = BedrockSetup.parseOffers(JSONValue(parsing: #"{"offers": [{"offerToken": "T1", "termDetails": {"usageBasedPricingTerm": [], "legalTerm": {"url": 5}, "supportTerm": {"refundPolicyDescription": ""}, "validityTerm": {"agreementDuration": "P2Y3M"}}}]}"#))
        XCTAssertEqual(wrong.count, 1)
        XCTAssertTrue(wrong[0].prices.isEmpty)
        XCTAssertNil(wrong[0].legalTermsURL)
        XCTAssertEqual(wrong[0].refundPolicy, "", "an empty refund policy is kept as empty")
        XCTAssertEqual(wrong[0].durationText, "2 years, 3 months")
        let notArray = BedrockSetup.parseOffers(JSONValue(parsing: #"{"offers": [{"offerToken": "T1", "termDetails": {"usageBasedPricingTerm": {"rateCard": {"dimension": "D"}}}}]}"#))
        XCTAssertEqual(notArray.count, 1)
        XCTAssertTrue(notArray[0].prices.isEmpty)
        XCTAssertEqual(BedrockSetup.parseOffers(JSONValue(parsing: #"{"offers": [{"offerToken": "T1", "termDetails": []}]}"#)).count, 1)
    }

    func testAvailabilityIsReadFromWhateverAwsSends() {
        XCTAssertEqual(BedrockSetup.parseAvailability(JSONValue(parsing: Fixtures.availability(agreement: "PENDING", authorization: "AUTHORIZED", entitlement: "NOT_AVAILABLE", region: "AVAILABLE", error: "why"))),
                       BedrockAvailability(agreement: "PENDING", agreementError: "why", authorization: "AUTHORIZED", entitlement: "NOT_AVAILABLE", region: "AVAILABLE"))
        let empty = BedrockAvailability(agreement: "", agreementError: nil, authorization: "", entitlement: "", region: "")
        for json in ["{}", "[]", "null", #""x""#, "5"] { XCTAssertEqual(BedrockSetup.parseAvailability(JSONValue(parsing: json)), empty, json) }
        XCTAssertEqual(BedrockSetup.parseAvailability(nil), empty)
        XCTAssertEqual(BedrockSetup.parseAvailability(JSONValue(parsing: #"{"agreementAvailability": {"status": "AVAILABLE", "errorMessage": "x"}, "authorizationStatus": "AUTHORIZED"}"#)),
                       BedrockAvailability(agreement: "AVAILABLE", agreementError: "x", authorization: "AUTHORIZED", entitlement: "", region: ""))
        XCTAssertEqual(BedrockSetup.parseAvailability(JSONValue(parsing: #"{"agreementAvailability": {"status": 1, "errorMessage": 42}, "authorizationStatus": 7}"#)), empty, "numbers aren't text")
        XCTAssertEqual(BedrockSetup.parseAvailability(JSONValue(parsing: #"{"agreementAvailability": "AVAILABLE"}"#)), empty, "an agreement that isn't an object")
    }

    func testAModelAccessSaysWhatCanBeDone() {
        let offer = ModelOffer(offerToken: "t")
        XCTAssertTrue(ModelAccess(state: .ready, modelID: "m", message: "").isReady)
        XCTAssertFalse(ModelAccess(state: .pending, modelID: "m", message: "").isReady)
        XCTAssertTrue(ModelAccess(state: .needsAgreement, modelID: "m", message: "", offer: offer).canAcceptInApp)
        XCTAssertFalse(ModelAccess(state: .needsAgreement, modelID: "m", message: "").canAcceptInApp, "no offer to accept")
        XCTAssertFalse(ModelAccess(state: .ready, modelID: "m", message: "", offer: offer).canAcceptInApp, "only when the terms are what's needed")
        XCTAssertEqual(ModelAccessState.allCases.count, 7)
        let access = ModelAccess(state: .notAuthorized, modelID: "m", message: "x", missingPermissions: ["a:B"], useCaseSubmitted: false)
        XCTAssertEqual(access, ModelAccess(state: .notAuthorized, modelID: "m", message: "x", missingPermissions: ["a:B"], useCaseSubmitted: false))
        XCTAssertNotEqual(access, ModelAccess(state: .notAuthorized, modelID: "m", message: "x", missingPermissions: ["a:C"], useCaseSubmitted: false))
        XCTAssertEqual(Set([access, access]).count, 1)
    }
}

// MARK: - The policy an administrator is sent

final class BedrockPermissionsTests: XCTestCase {
    func testThePolicyIsValidIamJson() throws {
        let root = try XCTUnwrap(JSONValue(parsing: BedrockPermissions.policyJSON))
        XCTAssertEqual(root["Version"]?.string, "2012-10-17")
        var actions: [String] = []
        var sids = Set<String>()
        let sidPattern = try NSRegularExpression(pattern: "^[A-Za-z0-9]+$")
        let actionPattern = try NSRegularExpression(pattern: "^[a-z0-9-]+:[A-Za-z0-9]+$")
        func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
            pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        let statements = try XCTUnwrap(root["Statement"]?.array)
        XCTAssertEqual(statements.count, 5)
        for statement in statements {
            XCTAssertEqual(statement["Effect"]?.string, "Allow")
            let sid = try XCTUnwrap(statement["Sid"]?.string)
            XCTAssertTrue(sids.insert(sid).inserted, "sids are unique")
            XCTAssertTrue(matches(sidPattern, sid), sid)
            XCTAssertNotNil(statement["Resource"])
            let action = try XCTUnwrap(statement["Action"])
            actions += action.array?.compactMap(\.string) ?? [action.string!]
        }
        for action in actions { XCTAssertTrue(matches(actionPattern, action), action) }
        for needed in ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:ListFoundationModels", "bedrock:GetFoundationModelAvailability",
                       "bedrock:ListInferenceProfiles", "bedrock:GetInferenceProfile", "bedrock:ListFoundationModelAgreementOffers",
                       "bedrock:CreateFoundationModelAgreement", "bedrock:GetUseCaseForModelAccess", "bedrock:PutUseCaseForModelAccess",
                       "bedrock:CallWithBearerToken", "aws-marketplace:Subscribe", "aws-marketplace:ViewSubscriptions", "aws-marketplace:Unsubscribe",
                       "signin:AuthorizeOAuth2Access", "signin:CreateOAuth2Token"] {
            XCTAssertTrue(actions.contains(needed), needed)
        }
        XCTAssertEqual(actions.count, Set(actions).count, "no action twice")
        let marketplace = try XCTUnwrap(statements.first { ($0["Sid"]?.string ?? "").contains("Marketplace") })
        XCTAssertEqual(marketplace["Condition"]?["StringEquals"]?["aws:CalledViaLast"]?.string, "bedrock.amazonaws.com")
        XCTAssertTrue(BedrockPermissions.explanation.contains("whoever manages your AWS account"))
        XCTAssertTrue(BedrockPermissions.explanation.contains(BedrockPermissions.signInManagedPolicy))
    }

    func testTheInvokeActionsAreWhatCheckAccessNames() {
        XCTAssertEqual(BedrockPermissions.invokeActions, ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
        XCTAssertEqual(BedrockPermissions.signInManagedPolicy, "SignInLocalDevelopmentAccess")
        let policy = BedrockPermissions.policyJSON
        for action in BedrockPermissions.invokeActions { XCTAssertTrue(policy.contains("\"\(action)\""), action) }
    }

    func testThePolicyIsWordForWordTheWindowsAppsPolicy() {
        // SHA-256 of the C# constants' text (LF line ends, no trailing newline), as compiled and printed by the probe.
        // Both are the Windows app's after both apps were renamed Vision: the policy's statement ids (vision-windows
        // fd764a8) and the explanation's wording (vision-windows a3650ce), src/Vision.Core/Aws/BedrockSetup.cs.
        func sha256(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(BedrockPermissions.policyJSON.utf8.count, 1662)
        XCTAssertEqual(sha256(BedrockPermissions.policyJSON), "3163a2f8625ce1f20a6476f1678aa8a352ec28a614bcf8e118174d7d5ae9a0f9")
        XCTAssertEqual(BedrockPermissions.explanation.utf8.count, 769)
        XCTAssertEqual(sha256(BedrockPermissions.explanation), "9fb1c4041df46cc592f4e2124d2a140b624f84bf5ae64ce79457f492b0e11fb5")
        XCTAssertFalse(BedrockPermissions.policyJSON.contains("\r"))
        XCTAssertTrue(BedrockPermissions.policyJSON.hasPrefix("{\n  \"Version\""))
        XCTAssertTrue(BedrockPermissions.policyJSON.hasSuffix("\n  ]\n}"))
    }

    func testTheExplanationIsFitForAPerson() {
        let text = BedrockPermissions.explanation
        XCTAssertTrue(text.hasPrefix("Vision uses Amazon Bedrock with your own AWS sign-in."))
        XCTAssertTrue(text.hasSuffix("anything else in the account."))
        XCTAssertFalse(text.contains("\n"))
        for platformWord in ["Windows", "%USERPROFILE%", "C:\\", ".exe"] { XCTAssertFalse(text.contains(platformWord), platformWord) }
    }
}


// MARK: - The scripted CLI itself (so the other tests can trust it)

final class ScriptedAWSCLITests: XCTestCase {
    func testTheFirstMatchingRuleWinsAndCallsAreRecorded() async throws {
        let cli = ScriptedAWSCLI().on(["bedrock", "list-foundation-models"], #"{"a": 1}"#).on(["bedrock"], #"{"b": 2}"#)
        let first = try await cli.runJSON(["bedrock", "list-foundation-models", "--x"], profile: "p", region: "r")
        XCTAssertEqual(first["a"]?.int, 1)
        let second = try await cli.runJSON(["bedrock", "other"], profile: nil, region: nil, timeout: 5)
        XCTAssertEqual(second["b"]?.int, 2)
        XCTAssertEqual(cli.calls.map(\.command), [["bedrock", "list-foundation-models", "--x"], ["bedrock", "other"]])
        XCTAssertEqual(cli.calls[0].profile, "p")
        XCTAssertNil(cli.calls[1].profile)
        XCTAssertEqual(cli.calls[1].timeout, 5)
        XCTAssertEqual(cli.calls(to: "bedrock", "other").count, 1)
        XCTAssertEqual(cli.calls(to: "bedrock").count, 2)
        XCTAssertTrue(cli.calls(to: "sts").isEmpty)
        XCTAssertEqual(cli.calls[0].joined, "bedrock list-foundation-models --x")
    }

    func testSequencesAdvanceAndTheLastStepRepeats() async throws {
        let cli = ScriptedAWSCLI().onSequence(["c"], [.output(#"{"n": 1}"#), .fail(.throttled(operation: "Op")), .output(#"{"n": 3}"#)])
        let one = try await cli.runJSON(["c"], profile: nil, region: nil)
        XCTAssertEqual(one["n"]?.int, 1)
        await assertSetupThrows(try await cli.runJSON(["c"], profile: nil, region: nil)) { XCTAssertEqual(($0 as? AWSCLIException)?.kind, .throttled) }
        for _ in 0..<3 {
            let again = try await cli.runJSON(["c"], profile: nil, region: nil)
            XCTAssertEqual(again["n"]?.int, 3)
        }
    }

    func testOutputIsReadAsTheCliLayerReadsIt() async throws {
        let cli = ScriptedAWSCLI().on(["empty"], "").on(["blank"], " \n ").on(["text"], "not json")
        let empty = try await cli.runJSON(["empty"], profile: nil, region: nil)
        XCTAssertEqual(empty, .object([:]))
        let blank = try await cli.runJSON(["blank"], profile: nil, region: nil)
        XCTAssertEqual(blank, .object([:]))
        await assertSetupThrows(try await cli.runJSON(["text"], profile: nil, region: nil)) { error in
            let failure = error as? AWSCLIException
            XCTAssertEqual(failure?.kind, .other)
            XCTAssertEqual(failure?.error.details, "not json")
        }
        let checked = try await cli.runChecked(["empty"], profile: "p", region: "r")
        XCTAssertTrue(checked.succeeded)
        XCTAssertEqual(cli.calls.last?.kind, .checked)
        await assertSetupThrows(try await cli.runChecked(["unknown"], profile: nil, region: nil)) { XCTAssertTrue($0 is ScriptedAWSCLI.NoAnswer) }
    }

    func testFailuresCarryWhatTheCliLayerWouldHaveMadeOfThem() async {
        let denied = ScriptedCLIFailure.accessDenied(operation: "ListFoundationModels", permission: "bedrock:ListFoundationModels")
        let cli = ScriptedAWSCLI().fail(["a"], denied).fail(["b"], .ssoExpired).fail(["c"], .error(CancellationError()))
        await assertSetupThrows(try await cli.runJSON(["a"], profile: nil, region: nil)) { error in
            let e = (error as? AWSCLIException)?.error
            XCTAssertEqual(e?.kind, .accessDenied)
            XCTAssertEqual(e?.permission, "bedrock:ListFoundationModels")
            XCTAssertEqual(e?.operation, "ListFoundationModels")
            XCTAssertEqual(e?.code, "AccessDeniedException")
            XCTAssertTrue(e?.details.hasPrefix("aws: [ERROR]: An error occurred (AccessDeniedException) when calling the ListFoundationModels operation:") == true)
            XCTAssertEqual(e?.message, "Your AWS permissions don't allow bedrock:ListFoundationModels. Ask whoever manages your AWS account to allow it — Vision can show the exact policy to send them.")
        }
        await assertSetupThrows(try await cli.runJSON(["b"], profile: "vision-bedrock", region: nil)) { error in
            XCTAssertEqual((error as? AWSSignInRequiredError)?.profile, "vision-bedrock")
        }
        await assertSetupThrows(try await cli.runJSON(["b"], profile: nil, region: nil)) { error in
            XCTAssertEqual((error as? AWSSignInRequiredError)?.profile, "default")
        }
        await assertSetupThrows(try await cli.runChecked(["c"], profile: nil, region: nil)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testACancelledTaskGetsNoAnswerUnlessTheFakeIsToldToIgnoreIt() async {
        let cli = ScriptedAWSCLI().on(["a"], "{}")
        let result = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await cli.runJSON(["a"], profile: nil, region: nil); return "answered" } catch is CancellationError { return "cancelled" } catch { return "other" }
        }.value
        XCTAssertEqual(result, "cancelled")
        XCTAssertTrue(cli.calls.isEmpty)
        cli.checksCancellation = false
        let ignored = await Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await cli.runJSON(["a"], profile: nil, region: nil); return "answered" } catch { return "other" }
        }.value
        XCTAssertEqual(ignored, "answered")
    }

    func testAnEndlessLoopIsStoppedByTheFake() async throws {
        let cli = ScriptedAWSCLI().on(["a"], "{}")
        for _ in 0..<ScriptedAWSCLI.runawayLimit { _ = try await cli.runJSON(["a"], profile: nil, region: nil) }
        await assertSetupThrows(try await cli.runJSON(["a"], profile: nil, region: nil)) { XCTAssertTrue($0 is ScriptedAWSCLI.RunawayLoop) }
    }

    func testTheClockOnlyMovesWhenSlept() async throws {
        let clock = BedrockWaitClock(start: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 100))
        try await clock.sleep(15)
        try await clock.sleep(2.5)
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 117.5))
        XCTAssertEqual(clock.elapsed, 17.5)
        XCTAssertEqual(clock.delays, [15, 2.5])
        XCTAssertEqual(clock.nowClosure(), clock.now)
        try await clock.sleepClosure(1)
        XCTAssertEqual(clock.delays, [15, 2.5, 1])
    }
}
