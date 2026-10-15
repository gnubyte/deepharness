import XCTest
@testable import VisionHarnessCore

// MARK: - Fixtures in the shapes botocore's bedrock/2023-04-20 model gives (as the CLI prints them with --output json)

enum BedrockJSONFixtures {
    static func model(_ id: String, _ name: String, _ provider: String, _ inference: [String], lifecycle: String = "ACTIVE",
                      streaming: Bool = true, output: [String] = ["TEXT"], input: [String] = ["TEXT"]) -> JSONValue {
        .object([
            "modelArn": .string("arn:aws:bedrock:us-east-1::foundation-model/\(id)"),
            "modelId": .string(id),
            "modelName": .string(name),
            "providerName": .string(provider),
            "inputModalities": .array(input.map { .string($0) }),
            "outputModalities": .array(output.map { .string($0) }),
            "responseStreamingSupported": .bool(streaming),
            "customizationsSupported": .array([]),
            "inferenceTypesSupported": .array(inference.map { .string($0) }),
            "modelLifecycle": .object(["status": .string(lifecycle), "startOfLifeTime": "2025-09-29T00:00:00+00:00"]),
        ])
    }

    static func profile(_ id: String, _ name: String, _ modelARNs: [String]) -> JSONValue {
        .object([
            "inferenceProfileName": .string(name),
            "description": .string("Routes requests to \(name)."),
            "createdAt": "2025-09-29T00:00:00+00:00",
            "updatedAt": "2025-09-29T00:00:00+00:00",
            "inferenceProfileArn": .string("arn:aws:bedrock:us-east-1:111122223333:inference-profile/\(id)"),
            "models": .array(modelARNs.map { .object(["modelArn": .string($0)]) }),
            "inferenceProfileId": .string(id),
            "status": "ACTIVE",
            "type": "SYSTEM_DEFINED",
        ])
    }

    /// A geography's profile ("us.", "eu.", …) for a model, covering the given Regions ("" = no Region, as global).
    static func geo(_ prefix: String, _ modelID: String, _ regions: [String]) -> JSONValue {
        profile("\(prefix).\(modelID)", "\(prefix.uppercased()) \(modelID)",
                regions.map { "arn:aws:bedrock:\($0)::foundation-model/\(modelID)" })
    }

    static let sonnet45 = "anthropic.claude-sonnet-4-5-20250929-v1:0"

    /// The Windows tests' catalog: 21 models, 4 of which must be filtered out.
    static let foundationModels: JSONValue = .object(["modelSummaries": .array([
        model(sonnet45, "Claude Sonnet 4.5", "Anthropic", ["INFERENCE_PROFILE"], input: ["TEXT", "IMAGE"]),
        model("anthropic.claude-sonnet-4-20250514-v1:0", "Claude Sonnet 4", "Anthropic", ["INFERENCE_PROFILE"], input: ["TEXT", "IMAGE"]),
        model("anthropic.claude-3-7-sonnet-20250219-v1:0", "Claude 3.7 Sonnet", "Anthropic", ["INFERENCE_PROFILE"], input: ["TEXT", "IMAGE"]),
        model("anthropic.claude-opus-4-1-20250805-v1:0", "Claude Opus 4.1", "Anthropic", ["INFERENCE_PROFILE"]),
        model("anthropic.claude-opus-4-20250514-v1:0", "Claude Opus 4", "Anthropic", ["INFERENCE_PROFILE"]),
        model("anthropic.claude-haiku-4-5-20251001-v1:0", "Claude Haiku 4.5", "Anthropic", ["INFERENCE_PROFILE"]),
        model("anthropic.claude-3-haiku-20240307-v1:0", "Claude 3 Haiku", "Anthropic", ["ON_DEMAND"]),
        model("anthropic.claude-3-sonnet-20240229-v1:0:28k", "Claude 3 Sonnet", "Anthropic", ["PROVISIONED"]),
        model("anthropic.claude-v2:1", "Claude", "Anthropic", ["ON_DEMAND"], lifecycle: "LEGACY"),
        model("amazon.nova-pro-v1:0", "Nova Pro", "Amazon", ["ON_DEMAND", "INFERENCE_PROFILE"]),
        model("amazon.nova-lite-v1:0", "Nova Lite", "Amazon", ["ON_DEMAND"]),
        model("amazon.titan-embed-text-v2:0", "Titan Text Embeddings V2", "Amazon", ["ON_DEMAND"], output: ["EMBEDDING"]),
        model("meta.llama3-3-70b-instruct-v1:0", "Llama 3.3 70B Instruct", "Meta", ["INFERENCE_PROFILE"]),
        model("meta.llama4-maverick-17b-instruct-v1:0", "Llama 4 Maverick 17B Instruct", "Meta", ["INFERENCE_PROFILE"]),
        model("mistral.mistral-large-2402-v1:0", "Mistral Large (24.02)", "Mistral AI", ["ON_DEMAND"]),
        model("deepseek.r1-v1:0", "DeepSeek-R1", "DeepSeek", ["INFERENCE_PROFILE"]),
        model("qwen.qwen3-coder-480b-a35b-v1:0", "Qwen3 Coder 480B A35B Instruct", "Qwen", ["ON_DEMAND"]),
        model("openai.gpt-oss-20b-1:0", "gpt-oss-20b", "OpenAI", ["ON_DEMAND"]),
        model("openai.gpt-oss-120b-1:0", "gpt-oss-120b", "OpenAI", ["ON_DEMAND"]),
        model("cohere.command-r-plus-v1:0", "Command R+", "Cohere", ["ON_DEMAND"]),
        model("ai21.jamba-1-5-large-v1:0", "Jamba 1.5 Large", "AI21 Labs", ["ON_DEMAND"], streaming: false),
    ])])

    static let inferenceProfiles: JSONValue = .object(["inferenceProfileSummaries": .array([
        geo("us", sonnet45, ["us-east-1", "us-east-2", "us-west-2"]),
        geo("eu", sonnet45, ["eu-central-1", "eu-west-1", "eu-west-3"]),
        geo("jp", sonnet45, ["ap-northeast-1", "ap-northeast-3"]),
        geo("apac", sonnet45, ["ap-northeast-1", "ap-south-1", "ap-southeast-2"]),
        geo("au", sonnet45, ["ap-southeast-2", "ap-southeast-4"]),
        geo("global", sonnet45, [""]),
        geo("us", "anthropic.claude-sonnet-4-20250514-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "anthropic.claude-3-7-sonnet-20250219-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "anthropic.claude-opus-4-1-20250805-v1:0", ["us-east-1", "us-west-2"]),
        geo("global", "anthropic.claude-haiku-4-5-20251001-v1:0", [""]),
        geo("us", "anthropic.claude-haiku-4-5-20251001-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "meta.llama3-3-70b-instruct-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "meta.llama4-maverick-17b-instruct-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "deepseek.r1-v1:0", ["us-east-1", "us-west-2"]),
        geo("us", "amazon.nova-pro-v1:0", ["us-east-1", "us-west-2"]),
        // A profile the user made themselves: not a system route, ignored.
        .object(["inferenceProfileName": "mine", "inferenceProfileId": "abcd1234efgh",
                 "inferenceProfileArn": "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/abcd1234efgh",
                 "models": .array([.object(["modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-20250514-v1:0"])]),
                 "status": "ACTIVE", "type": "APPLICATION"]),
    ])])

    static func build(_ region: String) -> [BedrockModel] {
        BedrockCatalog.build(foundationModels: foundationModels, inferenceProfiles: inferenceProfiles, region: region)
    }
}

/// Renders text the way the probe that captured the fixtures did: printable ASCII as is, backslash doubled,
/// everything else as \uXXXX per UTF-16 unit. (Lets a fixture hold non-ASCII text in plain ASCII.)
enum BedrockFixtureText {
    static func escaped(_ text: String?) -> String {
        guard let text else { return "<null>" }
        var out = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: out += "\\\\"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += "\\u" + String(format: "%04x", unit)
            }
        }
        return out
    }

    static func flag(_ value: Bool) -> String { value ? "True" : "False" }

    /// One line describing a model, as the edge-case fixtures list it.
    static func line(_ model: BedrockModel) -> String {
        "\(escaped(model.modelID)) -> \(escaped(model.invokeID)) \(model.recommended ? "R" : "-") name=\(escaped(model.name)) "
            + "provider=\(escaped(model.provider)) life=\(model.lifecycle) img=\(flag(model.acceptsImages)) "
            + "prof=\(flag(model.usesInferenceProfile)) anth=\(flag(model.isAnthropic)) invoke=\(flag(model.canInvoke)) "
            + "display=\(escaped(model.displayName))"
    }
}

/// Reads the compact catalog form of `BedrockCatalogFixtures.spec` into the JSON the CLI would print.
enum BedrockCatalogSpec {
    static func parse(_ spec: String) -> (models: JSONValue, profiles: JSONValue) {
        var models: [JSONValue] = [], profiles: [JSONValue] = []
        func csv(_ text: String) -> [JSONValue] { text.isEmpty ? [] : text.components(separatedBy: ",").map { .string($0) } }
        for raw in spec.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("M ") {
                let f = line.dropFirst(2).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                models.append(.object([
                    "modelArn": .string("arn:aws:bedrock:us-east-1::foundation-model/\(f[0])"), "modelId": .string(f[0]),
                    "modelName": .string(f[1]), "providerName": .string(f[2]),
                    "inputModalities": .array(csv(f[7])), "outputModalities": .array(csv(f[6])),
                    "responseStreamingSupported": .bool(f[5] == "1"), "customizationsSupported": .array([]),
                    "inferenceTypesSupported": .array(csv(f[3])), "modelLifecycle": .object(["status": .string(f[4])]),
                ]))
            } else if line.hasPrefix("P") {
                let odd = line.hasPrefix("P!")
                let f = line.dropFirst(odd ? 2 : 1).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let id = f[0]
                let regions = f[1].isEmpty ? [""] : f[1].components(separatedBy: ",")
                let modelID = id.firstIndex(of: ".").map { String(id[id.index(after: $0)...]) } ?? id
                profiles.append(.object([
                    "inferenceProfileName": .string(id),
                    "inferenceProfileArn": .string("arn:aws:bedrock:us-east-1:111122223333:inference-profile/\(id)"),
                    "models": .array(regions.map { .object(["modelArn": .string("arn:aws:bedrock:\($0)::foundation-model/\(modelID)")]) }),
                    "inferenceProfileId": .string(id), "status": .string(odd ? f[2] : "ACTIVE"),
                    "type": .string(odd ? f[3] : "SYSTEM_DEFINED"),
                ]))
            }
        }
        return (.object(["modelSummaries": .array(models)]), .object(["inferenceProfileSummaries": .array(profiles)]))
    }
}

// MARK: - The model list: what is kept, which id calls it, what is recommended, in what order

final class BedrockCatalogTests: XCTestCase {
    private let sonnet = BedrockJSONFixtures.sonnet45

    func testKeepsActiveStreamingTextModelsOnly() {
        let ids = BedrockJSONFixtures.build("us-east-1").map(\.modelID)
        XCTAssertFalse(ids.contains("anthropic.claude-3-sonnet-20240229-v1:0:28k"), "provisioned throughput only")
        XCTAssertFalse(ids.contains("anthropic.claude-v2:1"), "legacy")
        XCTAssertFalse(ids.contains("amazon.titan-embed-text-v2:0"), "embeddings")
        XCTAssertFalse(ids.contains("ai21.jamba-1-5-large-v1:0"), "no streaming")
        XCTAssertEqual(ids.count, 17)
        XCTAssertEqual(Set(ids).count, 17, "no id twice")
    }

    func testPicksTheClosestInferenceProfile() throws {
        let expected: [(String, String)] = [
            ("us-east-1", "us."), ("us-east-2", "us."), ("us-west-2", "us."), ("eu-central-1", "eu."), ("eu-west-1", "eu."),
            ("eu-west-3", "eu."), ("ap-northeast-1", "jp."), ("ap-northeast-3", "jp."), ("ap-southeast-2", "au."),
            ("ap-southeast-4", "au."), ("ap-south-1", "apac."), ("ap-southeast-1", "apac."), ("sa-east-1", "global."),
            ("me-central-1", "global."), ("ca-central-1", "us."), ("EU-WEST-1", "eu."),
        ]
        for (region, prefix) in expected {
            let model = try XCTUnwrap(BedrockJSONFixtures.build(region).first { $0.modelID == sonnet }, region)
            XCTAssertEqual(model.invokeID, prefix + sonnet, region)
            XCTAssertTrue(model.usesInferenceProfile, region)
            XCTAssertTrue(model.acceptsImages, region)
            XCTAssertTrue(model.isAnthropic, region)
            XCTAssertEqual(model.displayName, "Claude Sonnet 4.5 (Anthropic)", region)
        }
    }

    func testOnDemandModelsAreCalledByTheirOwnId() throws {
        let models = BedrockJSONFixtures.build("us-east-1")
        let nova = try XCTUnwrap(models.first { $0.modelID == "amazon.nova-pro-v1:0" })
        XCTAssertEqual(nova.invokeID, "amazon.nova-pro-v1:0", "on demand wins over a profile")
        XCTAssertFalse(nova.usesInferenceProfile)
        XCTAssertTrue(nova.canInvoke)
        XCTAssertEqual(models.first { $0.modelID == "anthropic.claude-3-haiku-20240307-v1:0" }?.invokeID, "anthropic.claude-3-haiku-20240307-v1:0")
    }

    func testFallsBackToGlobalThenToNothing() throws {
        let models = BedrockJSONFixtures.build("eu-west-1")
        XCTAssertEqual(models.first { $0.modelID == "anthropic.claude-haiku-4-5-20251001-v1:0" }?.invokeID,
                       "global.anthropic.claude-haiku-4-5-20251001-v1:0")
        // Opus 4 has no system profile (only the user's own application profile): it can't be called.
        let opus4 = try XCTUnwrap(models.first { $0.modelID == "anthropic.claude-opus-4-20250514-v1:0" })
        XCTAssertNil(opus4.invokeID)
        XCTAssertFalse(opus4.canInvoke)
        XCTAssertFalse(opus4.usesInferenceProfile)
        XCTAssertEqual(opus4, models.last, "listed last")
        // A US-only profile is still better than nothing from a European Region (profiles listed there are callable there).
        XCTAssertEqual(models.first { $0.modelID == "meta.llama4-maverick-17b-instruct-v1:0" }?.invokeID,
                       "us.meta.llama4-maverick-17b-instruct-v1:0")
    }

    func testRecommendsTheNewestOfEachFamilyInOrder() {
        let models = BedrockJSONFixtures.build("us-east-1")
        let recommended = models.filter(\.recommended).map(\.modelID)
        XCTAssertEqual(recommended, [
            "anthropic.claude-sonnet-4-5-20250929-v1:0",
            "anthropic.claude-opus-4-1-20250805-v1:0",
            "anthropic.claude-haiku-4-5-20251001-v1:0",
            "amazon.nova-pro-v1:0",
            "meta.llama4-maverick-17b-instruct-v1:0",
            "mistral.mistral-large-2402-v1:0",
            "deepseek.r1-v1:0",
            "qwen.qwen3-coder-480b-a35b-v1:0",
            "openai.gpt-oss-120b-1:0",
        ])
        XCTAssertEqual(Array(models.prefix(recommended.count).map(\.modelID)), recommended)
        // Then the rest of the families, newest first, then everything else.
        XCTAssertEqual(Array(models.dropFirst(recommended.count).prefix(2).map(\.modelID)),
                       ["anthropic.claude-sonnet-4-20250514-v1:0", "anthropic.claude-3-7-sonnet-20250219-v1:0"])
        XCTAssertEqual(BedrockCatalog.familyOf("anthropic.claude-3-7-sonnet-20250219-v1:0"), "Claude Sonnet")
        XCTAssertNil(BedrockCatalog.familyOf("cohere.command-r-plus-v1:0"))
    }

    func testModelPropertiesAreDerivedFromTheFields() {
        var model = BedrockModel(modelID: "acme.thing-v1:0", name: "Thing", provider: "Acme", inputModalities: ["TEXT"], streaming: true,
                                 lifecycle: "ACTIVE", inferenceTypes: ["ON_DEMAND"], invokeID: "acme.thing-v1:0")
        XCTAssertEqual(model.id, "acme.thing-v1:0")
        XCTAssertFalse(model.recommended)
        XCTAssertFalse(model.acceptsImages)
        XCTAssertFalse(model.isAnthropic)
        XCTAssertFalse(model.usesInferenceProfile)
        XCTAssertEqual(model.displayName, "Thing (Acme)")
        model.provider = ""
        XCTAssertEqual(model.displayName, "Thing")
        model.inputModalities = ["text", "Image"]
        XCTAssertTrue(model.acceptsImages, "modalities compare without case")
        model.invokeID = "us.acme.thing-v1:0"
        XCTAssertTrue(model.usesInferenceProfile)
        model.invokeID = nil
        XCTAssertFalse(model.canInvoke)
        XCTAssertFalse(model.usesInferenceProfile)
        // Anthropic: by id prefix or by provider, either without regard to case.
        XCTAssertTrue(BedrockModel(modelID: "Anthropic.claude-x", name: "", provider: "Other", inputModalities: [], streaming: true, lifecycle: "ACTIVE", inferenceTypes: [], invokeID: nil).isAnthropic)
        XCTAssertTrue(BedrockModel(modelID: "acme.claude", name: "", provider: "ANTHROPIC", inputModalities: [], streaming: true, lifecycle: "ACTIVE", inferenceTypes: [], invokeID: nil).isAnthropic)
        XCTAssertFalse(BedrockModel(modelID: "anthropic-claude", name: "", provider: "Other", inputModalities: [], streaming: true, lifecycle: "ACTIVE", inferenceTypes: [], invokeID: nil).isAnthropic)
        XCTAssertFalse(BedrockModel(modelID: "acme.claude", name: "", provider: " Anthropic", inputModalities: [], streaming: true, lifecycle: "ACTIVE", inferenceTypes: [], invokeID: nil).isAnthropic)
        XCTAssertEqual(Set([model, model]).count, 1, "models hash by value")
    }

    // MARK: A realistic catalog, in every Region, against what the Windows app answers

    func testARealisticCatalogGivesTheWindowsAnswerInEveryRegion() throws {
        let (models, profiles) = BedrockCatalogSpec.parse(BedrockCatalogFixtures.spec)
        XCTAssertEqual(BedrockCatalogFixtures.expected.count, 13)
        for (region, expected) in BedrockCatalogFixtures.expected.sorted(by: { $0.key < $1.key }) {
            let list = BedrockCatalog.build(foundationModels: models, inferenceProfiles: profiles, region: region)
            let actual = list.map { "\($0.modelID) \($0.invokeID ?? "-") \($0.recommended ? "R" : "-")" }
            XCTAssertEqual(actual, expected.components(separatedBy: "\n"), "Region \"\(region)\"")
        }
    }

    func testTheRealisticCatalogDropsWhatCannotChat() {
        let (models, profiles) = BedrockCatalogSpec.parse(BedrockCatalogFixtures.spec)
        let ids = Set(BedrockCatalog.build(foundationModels: models, inferenceProfiles: profiles, region: "us-east-1").map(\.modelID))
        for gone in ["anthropic.claude-3-haiku-20240307-v1:0:48k", "anthropic.claude-3-haiku-20240307-v1:0:200k",
                     "anthropic.claude-3-sonnet-20240229-v1:0:28k", "anthropic.claude-3-sonnet-20240229-v1:0", "anthropic.claude-3-opus-20240229-v1:0",
                     "anthropic.claude-v2:1", "anthropic.claude-instant-v1", "amazon.titan-embed-text-v2:0", "amazon.nova-canvas-v1:0",
                     "ai21.jamba-1-5-large-v1:0"] {
            XCTAssertFalse(ids.contains(gone), gone)
        }
        XCTAssertTrue(ids.contains("ai21.jamba-1-5-mini-v1:0"))
        XCTAssertTrue(ids.contains("anthropic.claude-opus-4-5-20251101-v1:0"))
    }

    func testEveryRealisticModelThatCanBeCalledHasAnIdItCanBeCalledBy() {
        let (models, profiles) = BedrockCatalogSpec.parse(BedrockCatalogFixtures.spec)
        for region in ["us-east-1", "eu-west-1", "ap-northeast-1", "ap-southeast-2", "sa-east-1", "us-gov-west-1"] {
            let list = BedrockCatalog.build(foundationModels: models, inferenceProfiles: profiles, region: region)
            let callable = list.prefix { $0.canInvoke }
            XCTAssertEqual(callable.count, list.filter(\.canInvoke).count, "callable models come first in \(region)")
            for model in callable {
                if model.usesInferenceProfile {
                    XCTAssertTrue(model.invokeID!.hasSuffix("." + model.modelID), "\(model.invokeID!) for \(model.modelID)")
                } else {
                    XCTAssertEqual(model.invokeID, model.modelID)
                }
            }
        }
    }

    // MARK: Odd and missing fields, profile choice and ties: against the Windows app on 152 catalogs in 8 Regions

    func testEdgeCatalogsGiveTheWindowsAnswer() throws {
        var checked = 0
        for scenario in BedrockCatalogEdgeFixtures.scenarios {
            let models = try XCTUnwrap(JSONValue(parsing: scenario.models), scenario.label)
            let profiles = try XCTUnwrap(JSONValue(parsing: scenario.profiles), scenario.label)
            for region in BedrockCatalogEdgeFixtures.regions {
                let list = BedrockCatalog.build(foundationModels: .object(["modelSummaries": models]),
                                                inferenceProfiles: .object(["inferenceProfileSummaries": profiles]), region: region)
                let expected = scenario.expected[region] ?? scenario.expected["*"] ?? "<no expectation>"
                XCTAssertEqual(list.map(BedrockFixtureText.line).joined(separator: "\n"), expected, "\(scenario.label) in \"\(region)\"")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 152 * 8)
    }

    // MARK: Filters, one at a time

    private func one(_ region: String = "us-east-1", models: [JSONValue], profiles: [JSONValue] = []) -> [BedrockModel] {
        BedrockCatalog.build(foundationModels: .object(["modelSummaries": .array(models)]),
                             inferenceProfiles: .object(["inferenceProfileSummaries": .array(profiles)]), region: region)
    }

    func testStreamingIsRequiredAndReadLeniently() {
        func listed(_ streaming: JSONValue?) -> Bool {
            guard case .object(var fields) = BedrockJSONFixtures.model("x.m", "M", "P", ["ON_DEMAND"]) else { return false }
            fields["responseStreamingSupported"] = streaming
            return !one(models: [.object(fields)]).isEmpty
        }
        for yes: JSONValue in [true, "true", "TRUE", " yes ", "1"] { XCTAssertTrue(listed(yes), "\(yes)") }
        for no: JSONValue in [false, "false", "no", "0", "maybe", 1, 0, .null, [true], [:]] { XCTAssertFalse(listed(no), "\(no)") }
        XCTAssertFalse(listed(nil), "missing")
    }

    func testOnlyActiveModelsAreListedWhateverTheCase() {
        func listed(_ status: String) -> Bool { !one(models: [BedrockJSONFixtures.model("x.m", "M", "P", ["ON_DEMAND"], lifecycle: status)]).isEmpty }
        XCTAssertTrue(listed("ACTIVE"))
        XCTAssertTrue(listed("active"))
        XCTAssertTrue(listed("Active"))
        XCTAssertFalse(listed("LEGACY"))
        XCTAssertFalse(listed(""))
        XCTAssertFalse(listed(" ACTIVE"))
        XCTAssertFalse(listed("ACTIVE "))
        XCTAssertEqual(one(models: [BedrockJSONFixtures.model("x.m", "M", "P", ["ON_DEMAND"], lifecycle: "active")]).first?.lifecycle, "ACTIVE",
                       "kept in capitals")
        // A lifecycle that isn't an object with a text status doesn't count as active.
        guard case .object(var fields) = BedrockJSONFixtures.model("x.m", "M", "P", ["ON_DEMAND"]) else { return XCTFail() }
        for odd: JSONValue? in [nil, "ACTIVE", ["ACTIVE"], .object(["status": 1]), .object(["status": .null]), .object([:])] {
            fields["modelLifecycle"] = odd
            XCTAssertTrue(one(models: [.object(fields)]).isEmpty, "\(String(describing: odd))")
        }
    }

    func testTextOutputIsRequired() {
        func listed(_ output: [String]) -> Bool { !one(models: [BedrockJSONFixtures.model("x.m", "M", "P", ["ON_DEMAND"], output: output)]).isEmpty }
        XCTAssertTrue(listed(["TEXT"]))
        XCTAssertTrue(listed(["text"]))
        XCTAssertTrue(listed(["IMAGE", "TEXT"]))
        XCTAssertTrue(listed(["EMBEDDING", "Text", "IMAGE"]))
        XCTAssertFalse(listed(["IMAGE"]))
        XCTAssertFalse(listed(["EMBEDDING"]))
        XCTAssertFalse(listed([]))
        XCTAssertFalse(listed(["TEXTS"]))
        XCTAssertFalse(listed([" TEXT"]))
    }

    func testProvisionedOnlyModelsNeedAProfileToBeListed() {
        let target = "x.target-v1:0"
        let profile = BedrockJSONFixtures.geo("us", target, ["us-east-1"])
        func model(_ types: [String]) -> JSONValue { BedrockJSONFixtures.model(target, "T", "P", types) }
        // Nothing covers it: dropped when it can only be bought as provisioned throughput …
        XCTAssertTrue(one(models: [model(["PROVISIONED"])]).isEmpty)
        XCTAssertTrue(one(models: [model(["provisioned", "PROVISIONED"])]).isEmpty)
        // … but a profile that covers it makes it callable, and listed.
        XCTAssertEqual(one(models: [model(["PROVISIONED"])], profiles: [profile]).first?.invokeID, "us." + target)
        // Other or unknown ways to run stay listed, uncallable.
        for types in [["INFERENCE_PROFILE"], ["INFERENCE_PROFILE", "PROVISIONED"], [], ["OTHER"]] {
            let listed = one(models: [model(types)])
            XCTAssertEqual(listed.count, 1, "\(types)")
            XCTAssertNil(listed.first?.invokeID, "\(types)")
        }
        // On demand needs no profile, in any case.
        XCTAssertEqual(one(models: [model(["on_demand"])]).first?.invokeID, target)
        XCTAssertEqual(one(models: [model(["ON_DEMAND", "PROVISIONED"])]).first?.invokeID, target)
    }

    func testANameOrProviderThatIsMissingIsFilledIn() {
        guard case .object(var fields) = BedrockJSONFixtures.model("x.thing", "Thing", "Acme", ["ON_DEMAND"]) else { return XCTFail() }
        fields["modelName"] = nil
        fields["providerName"] = nil
        let model = one(models: [.object(fields)]).first
        XCTAssertEqual(model?.name, "x.thing", "the id stands in for the name")
        XCTAssertEqual(model?.provider, "")
        XCTAssertEqual(model?.displayName, "x.thing")
        fields["modelName"] = ""
        XCTAssertEqual(one(models: [.object(fields)]).first?.name, "", "an empty name is kept")
        fields["modelName"] = 5
        XCTAssertEqual(one(models: [.object(fields)]).first?.name, "x.thing", "a name that is not text is ignored")
    }

    func testIdsMustBeNonEmptyText() {
        guard case .object(var fields) = BedrockJSONFixtures.model("x.thing", "Thing", "Acme", ["ON_DEMAND"]) else { return XCTFail() }
        for odd: JSONValue? in ["", nil, 5, .null] {
            fields["modelId"] = odd
            XCTAssertTrue(one(models: [.object(fields)]).isEmpty, "\(String(describing: odd))")
        }
        XCTAssertEqual(one(models: [BedrockJSONFixtures.model(" ", "Blank", "P", ["ON_DEMAND"])]).count, 1, "a blank id is still an id")
        XCTAssertEqual(one(models: [BedrockJSONFixtures.model("x.same", "First", "P", ["ON_DEMAND"]), BedrockJSONFixtures.model("x.same", "Second", "P", ["ON_DEMAND"])]).map(\.name),
                       ["First", "Second"], "the same id twice is listed twice, in listing order")
    }

    func testListingsThatAreNotListingsGiveNoModels() {
        XCTAssertTrue(BedrockCatalog.build(foundationModels: nil, inferenceProfiles: nil, region: "us-east-1").isEmpty)
        XCTAssertTrue(BedrockCatalog.build(foundationModels: .object([:]), inferenceProfiles: .object([:]), region: "us-east-1").isEmpty)
        XCTAssertTrue(BedrockCatalog.build(foundationModels: .array([]), inferenceProfiles: .string("x"), region: "us-east-1").isEmpty)
        XCTAssertTrue(BedrockCatalog.build(foundationModels: .object(["modelSummaries": "nope"]), inferenceProfiles: nil, region: "us-east-1").isEmpty)
        XCTAssertTrue(BedrockCatalog.build(foundationModels: .object(["modelSummaries": .array([1, "x", .null, [], [:]])]), inferenceProfiles: nil, region: "us-east-1").isEmpty)
        XCTAssertEqual(BedrockCatalog.build(foundationModels: .object(["modelSummaries": .array([1, .null, BedrockJSONFixtures.model("x.ok", "OK", "P", ["ON_DEMAND"])])]),
                                            inferenceProfiles: .object(["inferenceProfileSummaries": .array([.null, 5, "x"])]), region: "us-east-1").map(\.modelID), ["x.ok"])
    }

    // MARK: Which profile carries the call

    private let target = "x.target-v1:0"

    private func chosen(_ region: String, _ profiles: [JSONValue]) -> String? {
        BedrockCatalog.chooseInvokeID(modelID: target, inferenceTypes: ["INFERENCE_PROFILE"],
                                      inferenceProfiles: .object(["inferenceProfileSummaries": .array(profiles)]), region: region)
    }

    func testTheProfileWhosePrefixComesFirstInThePreferenceListIsChosen() {
        let all = ["global", "us", "eu", "apac", "jp", "au", "ca", "us-gov"].map { BedrockJSONFixtures.geo($0, target, ["us-east-1"]) }
        XCTAssertEqual(chosen("us-east-1", all), "us." + target)
        XCTAssertEqual(chosen("us-gov-west-1", all), "us-gov." + target)
        XCTAssertEqual(chosen("ca-central-1", all), "ca." + target)
        XCTAssertEqual(chosen("eu-west-1", all), "eu." + target)
        XCTAssertEqual(chosen("ap-northeast-1", all), "jp." + target)
        XCTAssertEqual(chosen("ap-southeast-2", all), "au." + target)
        XCTAssertEqual(chosen("ap-south-1", all), "apac." + target)
        XCTAssertEqual(chosen("sa-east-1", all), "global." + target)
        // Without the closest geography, the next in the list; ca falls back to us, then global.
        XCTAssertEqual(chosen("ca-central-1", all.filter { !($0["inferenceProfileId"]?.string ?? "").hasPrefix("ca.") }), "us." + target)
        XCTAssertEqual(chosen("ca-central-1", [BedrockJSONFixtures.geo("global", target, [""]), BedrockJSONFixtures.geo("eu", target, [])]), "global." + target)
    }

    func testAPrefixNotInThePreferenceListComesAfterTheListedOnesAndTheFirstListedWinsATie() {
        let unlisted = BedrockJSONFixtures.geo("zz", target, ["us-east-1"])
        let other = BedrockJSONFixtures.geo("yy", target, ["us-east-1"])
        let global = BedrockJSONFixtures.geo("global", target, [""])
        XCTAssertEqual(chosen("us-east-1", [unlisted, other]), "zz." + target, "two unlisted: the first listed")
        XCTAssertEqual(chosen("us-east-1", [other, unlisted]), "yy." + target)
        XCTAssertEqual(chosen("us-east-1", [unlisted, global]), "global." + target, "a listed prefix beats an unlisted one")
        XCTAssertEqual(chosen("eu-west-1", [BedrockJSONFixtures.geo("us", target, ["us-east-1"])]), "us." + target, "any profile beats none")
        XCTAssertNil(chosen("us-east-1", []))
        let duplicate = BedrockJSONFixtures.profile("us." + target, "second copy", ["arn:aws:bedrock:us-east-1::foundation-model/" + target])
        XCTAssertEqual(chosen("us-east-1", [duplicate, duplicate]), "us." + target)
    }

    func testAProfileNeedsToBeActiveAndSystemDefined() {
        func profile(status: JSONValue?, type: JSONValue?) -> JSONValue {
            guard case .object(var fields) = BedrockJSONFixtures.geo("us", target, ["us-east-1"]) else { return .null }
            fields["status"] = status
            fields["type"] = type
            return .object(fields)
        }
        XCTAssertEqual(chosen("us-east-1", [profile(status: "ACTIVE", type: "SYSTEM_DEFINED")]), "us." + target)
        XCTAssertEqual(chosen("us-east-1", [profile(status: "active", type: "system_defined")]), "us." + target, "without regard to case")
        XCTAssertEqual(chosen("us-east-1", [profile(status: nil, type: nil)]), "us." + target, "a missing status or type doesn't disqualify")
        XCTAssertEqual(chosen("us-east-1", [profile(status: .null, type: .null)]), "us." + target)
        XCTAssertNil(chosen("us-east-1", [profile(status: "INACTIVE", type: "SYSTEM_DEFINED")]))
        XCTAssertNil(chosen("us-east-1", [profile(status: "ACTIVE", type: "APPLICATION")]))
        XCTAssertNil(chosen("us-east-1", [profile(status: "", type: "SYSTEM_DEFINED")]))
    }

    func testAProfileIsFoundByItsModelsOrByTheEndOfItsId() {
        let arn = "arn:aws:bedrock:us-east-1::foundation-model/" + target
        // By its models (the id says nothing about the model) …
        XCTAssertEqual(chosen("us-east-1", [BedrockJSONFixtures.profile("us.something-else", "n", [arn])]), "us.something-else")
        // … or, when its models aren't listed, by the id ending in ".<model id>".
        XCTAssertEqual(chosen("us-east-1", [BedrockJSONFixtures.profile("us." + target, "n", [])]), "us." + target)
        XCTAssertNil(chosen("us-east-1", [BedrockJSONFixtures.profile("us.prefix-" + target, "n", [])]), "the model id must be the whole tail")
        XCTAssertNil(chosen("us-east-1", [BedrockJSONFixtures.profile("us.other-v1:0", "n", ["arn:aws:bedrock:us-east-1::model/" + target])]),
                     "an ARN that isn't a foundation model's says nothing")
        XCTAssertEqual(chosen("us-east-1", [BedrockJSONFixtures.profile("us.other-v1:0", "n", ["foundation-model/" + target])]), "us.other-v1:0")
        // An id that isn't text, or is empty, isn't a profile.
        XCTAssertNil(chosen("us-east-1", [.object(["inferenceProfileId": 5, "models": .array([.object(["modelArn": .string(arn)])])])]))
        XCTAssertNil(chosen("us-east-1", [BedrockJSONFixtures.profile("", "n", [arn])]))
        // A profile id without a dot has no prefix: after every preferred one.
        XCTAssertEqual(chosen("us-east-1", [BedrockJSONFixtures.profile("plainid", "n", [arn]), BedrockJSONFixtures.geo("global", target, [""])]), "global." + target)
        XCTAssertEqual(chosen("us-east-1", [BedrockJSONFixtures.profile("plainid", "n", [arn])]), "plainid")
    }

    func testOnDemandModelsNeverNeedAProfile() {
        XCTAssertEqual(BedrockCatalog.chooseInvokeID(modelID: "m", inferenceTypes: ["ON_DEMAND"], inferenceProfiles: nil, region: "us-east-1"), "m")
        XCTAssertEqual(BedrockCatalog.chooseInvokeID(modelID: "m", inferenceTypes: ["inference_profile", "on_demand"], inferenceProfiles: nil, region: "x"), "m")
        XCTAssertNil(BedrockCatalog.chooseInvokeID(modelID: "m", inferenceTypes: ["INFERENCE_PROFILE"], inferenceProfiles: nil, region: "us-east-1"))
        XCTAssertNil(BedrockCatalog.chooseInvokeID(modelID: "m", inferenceTypes: [], inferenceProfiles: nil, region: "us-east-1"))
    }

    // MARK: The order

    func testUncallableModelsAreNeverRecommendedAndComeLast() {
        let models = one(models: [
            BedrockJSONFixtures.model("anthropic.claude-opus-4-5-20251101-v1:0", "Opus 4.5", "Anthropic", ["INFERENCE_PROFILE"]),
            BedrockJSONFixtures.model("anthropic.claude-opus-4-1-20250805-v1:0", "Opus 4.1", "Anthropic", ["ON_DEMAND"]),
            BedrockJSONFixtures.model("acme.thing-v1:0", "Thing", "Acme", ["ON_DEMAND"]),
        ])
        XCTAssertEqual(models.map(\.modelID), ["anthropic.claude-opus-4-1-20250805-v1:0", "acme.thing-v1:0", "anthropic.claude-opus-4-5-20251101-v1:0"])
        XCTAssertEqual(models.map(\.recommended), [true, false, false])
    }

    func testTwoModelsThatRankAlikeKeepTheirListingOrderAndTheFirstIsRecommended() {
        let models = one(models: [
            BedrockJSONFixtures.model("meta.llama4-scout-17b-instruct-v1:0", "Scout", "Meta", ["ON_DEMAND"]),
            BedrockJSONFixtures.model("meta.llama4-maverick-17b-instruct-v1:0", "Maverick", "Meta", ["ON_DEMAND"]),
        ])
        XCTAssertEqual(models.map(\.name), ["Scout", "Maverick"])
        XCTAssertEqual(models.map(\.recommended), [true, false])
        let reversed = one(models: [
            BedrockJSONFixtures.model("meta.llama4-maverick-17b-instruct-v1:0", "Maverick", "Meta", ["ON_DEMAND"]),
            BedrockJSONFixtures.model("meta.llama4-scout-17b-instruct-v1:0", "Scout", "Meta", ["ON_DEMAND"]),
        ])
        XCTAssertEqual(reversed.map(\.name), ["Maverick", "Scout"])
        XCTAssertEqual(reversed.map(\.recommended), [true, false])
    }

    func testProviderThenNameBreakTiesWithoutRegardToCase() {
        // Ids without numbers rank alike, so only the provider and the name are left to decide.
        let letters = Array("abcdefghijkl")
        func order(_ pairs: [(name: String, provider: String)]) -> [String] {
            one(models: pairs.enumerated().map { BedrockJSONFixtures.model("x.t\(letters[$0.offset])", $0.element.name, $0.element.provider, ["ON_DEMAND"]) })
                .map { "\($0.provider)/\($0.name)" }
        }
        XCTAssertEqual(order([("b", "P"), ("a", "P"), ("B", "p"), ("A", "P"), ("a", "p")]),
                       ["P/a", "P/A", "p/a", "P/b", "p/B"], "a before b; equal names keep the listing order; providers compare first")
        XCTAssertEqual(order([("N", "beta"), ("N", "Alpha"), ("N", "ALPHA"), ("N", "alpha")]), ["Alpha/N", "ALPHA/N", "alpha/N", "beta/N"])
        // "_" sorts after letters when case is ignored by upper-casing (ordinal ignore case), unlike a lower-casing compare.
        XCTAssertEqual(order([("a_", "P"), ("aa", "P"), ("_a", "P"), ("a", "P")]), ["P/a", "P/aa", "P/a_", "P/_a"])
        XCTAssertEqual(order([("z", "P"), ("Z", "P"), ("y", "P")]), ["P/y", "P/z", "P/Z"])
        // A provider that sorts first wins whatever the names.
        XCTAssertEqual(order([("a", "Zeta"), ("z", "Alpha")]), ["Alpha/z", "Zeta/a"])
    }

    func testTheNewerIdComesFirstBeforeProviderAndNameAreLookedAt() {
        // Same provider and name, ids that differ in a revision: the higher revision first.
        let models = one(models: [
            BedrockJSONFixtures.model("x.thing-v1:0", "T", "P", ["ON_DEMAND"]),
            BedrockJSONFixtures.model("x.thing-v3:0", "T", "P", ["ON_DEMAND"]),
            BedrockJSONFixtures.model("x.thing-v2:0", "T", "P", ["ON_DEMAND"]),
        ])
        XCTAssertEqual(models.map(\.modelID), ["x.thing-v3:0", "x.thing-v2:0", "x.thing-v1:0"])
    }

    func testNewestFirstWithinAFamilyAndFamiliesInTheirOrder() {
        let ids = ["anthropic.claude-3-5-haiku-20241022-v1:0", "meta.llama3-1-70b-instruct-v1:0", "anthropic.claude-sonnet-4-20250514-v1:0",
                   "anthropic.claude-opus-4-1-20250805-v1:0", "acme.zzz-v1:0", "anthropic.claude-sonnet-4-5-20250929-v1:0", "meta.llama3-3-70b-instruct-v1:0"]
        let models = one(models: ids.map { BedrockJSONFixtures.model($0, $0, "P", ["ON_DEMAND"]) })
        XCTAssertEqual(models.map(\.modelID), [
            "anthropic.claude-sonnet-4-5-20250929-v1:0",   // recommended, in family order
            "anthropic.claude-opus-4-1-20250805-v1:0",
            "anthropic.claude-3-5-haiku-20241022-v1:0",
            "meta.llama3-3-70b-instruct-v1:0",
            "anthropic.claude-sonnet-4-20250514-v1:0",     // then the rest of each family, newest first
            "meta.llama3-1-70b-instruct-v1:0",
            "acme.zzz-v1:0",                                // then everything else
        ])
    }
}

// MARK: - Which model is newer

final class BedrockRecencyTests: XCTestCase {
    private typealias Recency = BedrockCatalog.RecencyComparer

    func testKnowsWhichModelIsNewer() {
        let pairs: [(newer: String, older: String)] = [
            ("anthropic.claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-sonnet-4-20250514-v1:0"),
            ("anthropic.claude-sonnet-4-20250514-v1:0", "anthropic.claude-3-7-sonnet-20250219-v1:0"),
            ("anthropic.claude-3-5-sonnet-20241022-v2:0", "anthropic.claude-3-5-sonnet-20240620-v1:0"),
            ("anthropic.claude-opus-4-1-20250805-v1:0", "anthropic.claude-opus-4-20250514-v1:0"),
            ("meta.llama4-scout-17b-instruct-v1:0", "meta.llama3-3-70b-instruct-v1:0"),
            ("openai.gpt-oss-120b-1:0", "openai.gpt-oss-20b-1:0"),
        ]
        for (newer, older) in pairs {
            XCTAssertGreaterThan(Recency.compare(newer, older), 0, "\(newer) vs \(older)")
            XCTAssertLessThan(Recency.compare(older, newer), 0, "\(older) vs \(newer)")
            XCTAssertEqual(Recency.compare(newer, newer), 0)
        }
    }

    func testVersionThenDateThenRevision() {
        // The version numbers decide first, whatever the dates say …
        XCTAssertGreaterThan(Recency.compare("anthropic.claude-sonnet-4-5-20250101-v1:0", "anthropic.claude-sonnet-4-20991231-v1:0"), 0)
        // … the date next …
        XCTAssertGreaterThan(Recency.compare("anthropic.claude-sonnet-4-20250601-v1:0", "anthropic.claude-sonnet-4-20250514-v1:0"), 0)
        // … and the revision last.
        XCTAssertGreaterThan(Recency.compare("anthropic.claude-3-5-sonnet-20241022-v2:0", "anthropic.claude-3-5-sonnet-20241022-v1:0"), 0)
        // A missing number reads as 0: 4 is older than 4.1 and equal to 4.0.
        XCTAssertLessThan(Recency.compare("anthropic.claude-opus-4-20250514-v1:0", "anthropic.claude-opus-4-1-20250514-v1:0"), 0)
        // The provider prefix, and a profile's geography, say nothing about recency.
        XCTAssertEqual(Recency.compare("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-sonnet-4-5-20250929-v1:0"), 0)
        XCTAssertEqual(Recency.compare("global.anthropic.claude-sonnet-4-5-20250929-v1:0", "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"), 0)
        // Numbers after the release date don't count as version numbers.
        XCTAssertEqual(Recency.key("anthropic.claude-sonnet-4-5-20250929-v1:0").version, [4, 5])
        // Unreadable ids rank as the oldest, without crashing.
        XCTAssertEqual(Recency.compare("", ""), 0)
        XCTAssertLessThan(Recency.compare("x", "anthropic.claude-sonnet-4-5-20250929-v1:0"), 0)
        XCTAssertEqual(Recency.key("anthropic.claude-sonnet-99999999999999999999-v1:0").version, [], "a number too big for 64 bits is skipped")
        XCTAssertEqual(Recency.key("anthropic.claude-sonnet-٤-٥-v1:0").version, [], "digits of other scripts are skipped")
    }

    func testEveryIdReadsTheSameAsTheWindowsAppReadsIt() {
        XCTAssertGreaterThan(BedrockCatalogFixtures.recencyKeys.count, 100)
        for row in BedrockCatalogFixtures.recencyKeys {
            let key = Recency.key(row.id)
            XCTAssertEqual(key.version, row.version, row.id)
            XCTAssertEqual(key.date, row.date, row.id)
            XCTAssertEqual(key.revision, row.revision, row.id)
            XCTAssertEqual(BedrockCatalog.familyOf(row.id), row.family, row.id)
        }
    }

    func testTheOrderOfEveryIdMatchesTheWindowsApp() {
        let ids = BedrockCatalogFixtures.recencyKeys.map(\.id)
        // A stable sort, oldest first.
        let sorted = ids.enumerated().sorted { a, b in
            let c = Recency.compare(a.element, b.element)
            return c != 0 ? c < 0 : a.offset < b.offset
        }.map(\.element)
        XCTAssertEqual(sorted, BedrockCatalogFixtures.recencyAscending)
    }

    func testTheWholeComparisonMatrixMatchesTheWindowsApp() {
        let ids = BedrockCatalogFixtures.recencyKeys.map(\.id)
        let rows = ids.map { a in ids.map { b -> String in
            let c = Recency.compare(a, b)
            return c < 0 ? "<" : c > 0 ? ">" : "="
        }.joined() }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in rows.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        XCTAssertEqual(String(format: "%016llx", hash), BedrockCatalogFixtures.recencyMatrixHash)
        // Antisymmetric: every row is the mirror of its column.
        for i in ids.indices { for j in ids.indices {
            let a = Array(rows[i])[j], b = Array(rows[j])[i]
            XCTAssertEqual(a == "<" ? ">" : a == ">" ? "<" : "=", String(b), "\(ids[i]) vs \(ids[j])")
        } }
    }

    func testFamilies() {
        let cases: [(String, String?)] = [
            ("anthropic.claude-sonnet-4-5-20250929-v1:0", "Claude Sonnet"), ("anthropic.claude-3-7-sonnet-20250219-v1:0", "Claude Sonnet"),
            ("anthropic.claude-3-5-sonnet-20241022-v2:0", "Claude Sonnet"), ("anthropic.claude-opus-4-1-20250805-v1:0", "Claude Opus"),
            ("anthropic.claude-3-haiku-20240307-v1:0", "Claude Haiku"), ("anthropic.claude-haiku-4-5-20251001-v1:0", "Claude Haiku"),
            ("amazon.nova-pro-v1:0", "Amazon Nova Pro"), ("amazon.nova-2-pro-v1:0", "Amazon Nova Pro"), ("amazon.nova-lite-v1:0", nil),
            ("meta.llama3-3-70b-instruct-v1:0", "Llama"), ("meta.llama4-scout-17b-instruct-v1:0", "Llama"), ("mistral.mistral-large-2402-v1:0", "Mistral"),
            ("deepseek.r1-v1:0", "DeepSeek"), ("qwen.qwen3-coder-480b-a35b-v1:0", "Qwen"), ("openai.gpt-oss-120b-1:0", "gpt-oss"),
            ("cohere.command-r-plus-v1:0", nil), ("anthropic.claude-v2:1", nil), ("anthropic.claude-instant-v1", nil),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", nil), ("Anthropic.claude-sonnet-4", nil), ("anthropic.Claude-sonnet-4", nil), ("", nil),
        ]
        for (id, family) in cases { XCTAssertEqual(BedrockCatalog.familyOf(id), family, id) }
    }
}

// MARK: - Regions

final class BedrockRegionsTests: XCTestCase {
    func testProfilePrefixesFollowGeography() {
        let cases: [(String, [String])] = [
            ("us-east-1", ["us", "global"]), ("us-east-2", ["us", "global"]), ("us-west-1", ["us", "global"]), ("us-west-2", ["us", "global"]),
            ("us-gov-west-1", ["us-gov"]), ("us-gov-east-1", ["us-gov"]),
            ("ca-central-1", ["ca", "us", "global"]), ("ca-west-1", ["ca", "us", "global"]),
            ("eu-west-3", ["eu", "global"]), ("eu-central-1", ["eu", "global"]), ("eu-north-1", ["eu", "global"]), ("eu-south-2", ["eu", "global"]),
            ("ap-northeast-1", ["jp", "apac", "global"]), ("ap-northeast-3", ["jp", "apac", "global"]),
            ("ap-southeast-2", ["au", "apac", "global"]), ("ap-southeast-4", ["au", "apac", "global"]),
            ("ap-southeast-1", ["apac", "global"]), ("ap-south-1", ["apac", "global"]), ("ap-northeast-2", ["apac", "global"]),
            ("me-central-1", ["global"]), ("sa-east-1", ["global"]), ("af-south-1", ["global"]), ("il-central-1", ["global"]),
            ("", ["global"]), ("nonsense", ["global"]),
            ("US-EAST-1", ["us", "global"]), ("Eu-West-1", ["eu", "global"]), ("AP-NORTHEAST-1", ["jp", "apac", "global"]),
            ("us-", ["us", "global"]), ("us-gov-", ["us-gov"]), ("us", ["global"]), ("usa-east-1", ["global"]), (" us-east-1", ["global"]),
        ]
        for (region, prefixes) in cases { XCTAssertEqual(BedrockRegions.profilePrefixes(for: region), prefixes, "\"\(region)\"") }
    }

    func testOffersCommonRegions() {
        let regions = BedrockRegions.common
        XCTAssertEqual(BedrockRegions.defaultRegion, "us-east-1")
        XCTAssertEqual(BedrockSetup.defaultRegion, "us-east-1")
        XCTAssertEqual(BedrockSetup.commonRegions, regions)
        XCTAssertTrue(regions.contains { $0.code == BedrockRegions.defaultRegion })
        XCTAssertEqual(regions.count, 15)
        XCTAssertEqual(Set(regions.map(\.code)).count, regions.count, "no Region twice")
        XCTAssertEqual(Set(regions.map(\.name)).count, regions.count, "no name twice")
        XCTAssertEqual(regions.first?.code, "us-east-1", "the default first")
        for code in ["us-east-1", "us-west-2", "us-east-2", "eu-central-1", "eu-west-1", "eu-west-3", "ap-northeast-1", "ap-southeast-2", "ap-south-1",
                     "ca-central-1", "sa-east-1"] {
            XCTAssertTrue(regions.contains { $0.code == code }, code)
        }
        XCTAssertEqual(regions.first { $0.code == "us-west-2" }?.display, "US West (Oregon) — us-west-2")
        XCTAssertEqual(regions.first { $0.code == "sa-east-1" }?.display, "South America (São Paulo) — sa-east-1")
        XCTAssertEqual(regions.first { $0.code == "us-west-2" }?.id, "us-west-2")
        XCTAssertEqual(AWSRegionChoice(code: "x-1", name: "X").display, "X — x-1")
        for region in regions { XCTAssertFalse(BedrockRegions.profilePrefixes(for: region.code).isEmpty, region.code) }
    }

    func testNamesOfRegions() {
        XCTAssertEqual(BedrockRegions.name(of: "eu-central-1"), "Europe (Frankfurt)")
        XCTAssertEqual(BedrockRegions.name(of: "us-east-1"), "US East (N. Virginia)")
        XCTAssertEqual(BedrockRegions.name(of: "ap-southeast-2"), "Asia Pacific (Sydney)")
        XCTAssertEqual(BedrockRegions.name(of: "il-central-1"), "il-central-1", "a Region not listed is its code")
        XCTAssertEqual(BedrockRegions.name(of: ""), "")
        XCTAssertEqual(BedrockRegions.name(of: "EU-CENTRAL-1"), "EU-CENTRAL-1", "codes are lower case")
        for region in BedrockRegions.common { XCTAssertEqual(BedrockRegions.name(of: region.code), region.name) }
    }
}
