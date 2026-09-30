import Foundation

// GENERATED FROM THE WINDOWS APP: edge-case catalogs (odd or missing fields, profile selection, ties) and what
// `BedrockCatalog.Build` answered for each in eight Regions (dshwindows, .NET 8, captured by a probe program).
// An expected block is one line per model in the order the catalog returned them; "*" means every Region gave the same.
// The probe compiled the unmodified src/Dsh.Core/Aws/BedrockSetup.cs (dshwindows at bf08ade) and printed its answers;
// nothing below was written by hand, so don't edit it by hand either (regenerate it from a fresh probe run).

enum BedrockCatalogEdgeFixtures {
    struct Scenario {
        var label: String
        /// The `modelSummaries` array as JSON text.
        var models: String
        /// The `inferenceProfileSummaries` array as JSON text.
        var profiles: String
        /// Region → expected lines ("*" for all Regions when they agree).
        var expected: [String: String]
    }

    static let regions: [String] = ["us-east-1", "eu-west-1", "ap-northeast-1", "ap-southeast-2", "ca-central-1", "us-gov-west-1", "me-central-1", ""]

    static let scenarios: [Scenario] = [
        Scenario(
            label: "streaming-True",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-0","modelId":"x.stream-0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-0 -> x.stream-0 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-False",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-1","modelId":"x.stream-1","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":false,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-'true'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-2","modelId":"x.stream-2","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"true","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-2 -> x.stream-2 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-'TRUE'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-3","modelId":"x.stream-3","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"TRUE","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-3 -> x.stream-3 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-' yes '",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-4","modelId":"x.stream-4","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":" yes ","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-4 -> x.stream-4 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-'1'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-5","modelId":"x.stream-5","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"1","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-5 -> x.stream-5 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-'false'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-6","modelId":"x.stream-6","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"false","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-'no'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-7","modelId":"x.stream-7","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"no","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-'0'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-8","modelId":"x.stream-8","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"0","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-'maybe'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-9","modelId":"x.stream-9","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"maybe","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-1",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-10","modelId":"x.stream-10","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":1,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-0",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-11","modelId":"x.stream-11","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":0,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-None",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-12","modelId":"x.stream-12","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":null,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-[True]",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-13","modelId":"x.stream-13","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":[true],"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-{'a': 1}",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-14","modelId":"x.stream-14","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":{"a":1},"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "streaming-'True '",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-15","modelId":"x.stream-15","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":"True ","inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.stream-15 -> x.stream-15 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "streaming-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.stream-missing","modelId":"x.stream-missing","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-'ACTIVE'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-0","modelId":"x.life-0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.life-0 -> x.life-0 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "lifecycle-'active'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-1","modelId":"x.life-1","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"active"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.life-1 -> x.life-1 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "lifecycle-'Active'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-2","modelId":"x.life-2","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"Active"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.life-2 -> x.life-2 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "lifecycle-' ACTIVE'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-3","modelId":"x.life-3","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":" ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-'ACTIVE '",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-4","modelId":"x.life-4","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE "}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-'LEGACY'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-5","modelId":"x.life-5","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"LEGACY"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-''",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-6","modelId":"x.life-6","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":""}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-'ACTIVE\\n'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-7","modelId":"x.life-7","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE\n"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-missing","modelId":"x.life-missing","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"]}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-null-status",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-null","modelId":"x.life-null","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":null}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-string",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-string","modelId":"x.life-string","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":"ACTIVE"}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-number-status",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-number","modelId":"x.life-number","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":1}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "lifecycle-array",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.life-array","modelId":"x.life-array","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":["ACTIVE"]}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-['TEXT']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-0","modelId":"x.out-0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-0 -> x.out-0 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-['text']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-1","modelId":"x.out-1","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["text"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-1 -> x.out-1 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-['Text']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-2","modelId":"x.out-2","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["Text"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-2 -> x.out-2 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-['IMAGE', 'TEXT']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-3","modelId":"x.out-3","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["IMAGE","TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-3 -> x.out-3 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-['IMAGE']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-4","modelId":"x.out-4","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["IMAGE"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-[]",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-5","modelId":"x.out-5","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":[],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-'TEXT'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-6","modelId":"x.out-6","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":"TEXT","responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-[1, 'TEXT']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-7","modelId":"x.out-7","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":[1,"TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-7 -> x.out-7 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-[None, 'Text']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-8","modelId":"x.out-8","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":[null,"Text"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-8 -> x.out-8 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-['TEXTS']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-9","modelId":"x.out-9","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXTS"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-[' TEXT']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-10","modelId":"x.out-10","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":[" TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "output-['EMBEDDING', 'TEXT', 'IMAGE']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-11","modelId":"x.out-11","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["EMBEDDING","TEXT","IMAGE"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.out-11 -> x.out-11 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "output-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.out-missing","modelId":"x.out-missing","modelName":"N","providerName":"P","inputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "input-['IMAGE']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-0","modelId":"x.in-0","modelName":"N","providerName":"P","inputModalities":["IMAGE"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-0 -> x.in-0 - name=N provider=P life=ACTIVE img=True prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-['image']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-1","modelId":"x.in-1","modelName":"N","providerName":"P","inputModalities":["image"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-1 -> x.in-1 - name=N provider=P life=ACTIVE img=True prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-['Image', 'TEXT']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-2","modelId":"x.in-2","modelName":"N","providerName":"P","inputModalities":["Image","TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-2 -> x.in-2 - name=N provider=P life=ACTIVE img=True prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-[]",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-3","modelId":"x.in-3","modelName":"N","providerName":"P","inputModalities":[],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-3 -> x.in-3 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-'IMAGE'",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-4","modelId":"x.in-4","modelName":"N","providerName":"P","inputModalities":"IMAGE","outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-4 -> x.in-4 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-['IMAGES']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-5","modelId":"x.in-5","modelName":"N","providerName":"P","inputModalities":["IMAGES"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-5 -> x.in-5 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-[None, 'IMAGE']",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-6","modelId":"x.in-6","modelName":"N","providerName":"P","inputModalities":[null,"IMAGE"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-6 -> x.in-6 - name=N provider=P life=ACTIVE img=True prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "input-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.in-missing","modelId":"x.in-missing","modelName":"N","providerName":"P","outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.in-missing -> x.in-missing - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-0","modelId":"x.inf-0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-0 -> x.inf-0 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-0","modelId":"x.inf-0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-0","inferenceProfileName":"us.x.inf-0","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-0 -> x.inf-0 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['on_demand']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-1","modelId":"x.inf-1","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["on_demand"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-1 -> x.inf-1 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['on_demand']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-1","modelId":"x.inf-1","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["on_demand"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-1","inferenceProfileName":"us.x.inf-1","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-1"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-1 -> x.inf-1 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['On_Demand']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-2","modelId":"x.inf-2","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["On_Demand"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-2 -> x.inf-2 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['On_Demand']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-2","modelId":"x.inf-2","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["On_Demand"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-2","inferenceProfileName":"us.x.inf-2","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-2"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-2 -> x.inf-2 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND', 'PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-3","modelId":"x.inf-3","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-3 -> x.inf-3 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND', 'PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-3","modelId":"x.inf-3","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-3","inferenceProfileName":"us.x.inf-3","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-3"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-3 -> x.inf-3 - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-4","modelId":"x.inf-4","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "types-['PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-4","modelId":"x.inf-4","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-4","inferenceProfileName":"us.x.inf-4","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-4"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-4 -> us.x.inf-4 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['provisioned']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-5","modelId":"x.inf-5","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["provisioned"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "types-['provisioned']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-5","modelId":"x.inf-5","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["provisioned"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-5","inferenceProfileName":"us.x.inf-5","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-5"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-5 -> us.x.inf-5 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['PROVISIONED', 'PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-6","modelId":"x.inf-6","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "types-['PROVISIONED', 'PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-6","modelId":"x.inf-6","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-6","inferenceProfileName":"us.x.inf-6","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-6"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-6 -> us.x.inf-6 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['Provisioned', 'PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-7","modelId":"x.inf-7","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["Provisioned","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "types-['Provisioned', 'PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-7","modelId":"x.inf-7","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["Provisioned","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-7","inferenceProfileName":"us.x.inf-7","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-7"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-7 -> us.x.inf-7 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-[]-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-8","modelId":"x.inf-8","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-8 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-[]-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-8","modelId":"x.inf-8","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-8","inferenceProfileName":"us.x.inf-8","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-8"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-8 -> us.x.inf-8 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['INFERENCE_PROFILE']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-9","modelId":"x.inf-9","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-9 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-['INFERENCE_PROFILE']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-9","modelId":"x.inf-9","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-9","inferenceProfileName":"us.x.inf-9","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-9"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-9 -> us.x.inf-9 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['INFERENCE_PROFILE', 'PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-10","modelId":"x.inf-10","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-10 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-['INFERENCE_PROFILE', 'PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-10","modelId":"x.inf-10","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE","PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-10","inferenceProfileName":"us.x.inf-10","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-10"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-10 -> us.x.inf-10 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['PROVISIONED', 'INFERENCE_PROFILE']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-11","modelId":"x.inf-11","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-11 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-['PROVISIONED', 'INFERENCE_PROFILE']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-11","modelId":"x.inf-11","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-11","inferenceProfileName":"us.x.inf-11","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-11"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-11 -> us.x.inf-11 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['OTHER']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-12","modelId":"x.inf-12","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["OTHER"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-12 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-['OTHER']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-12","modelId":"x.inf-12","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["OTHER"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-12","inferenceProfileName":"us.x.inf-12","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-12"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-12 -> us.x.inf-12 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-[1, 'PROVISIONED']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-13","modelId":"x.inf-13","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[1,"PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "types-[1, 'PROVISIONED']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-13","modelId":"x.inf-13","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[1,"PROVISIONED"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-13","inferenceProfileName":"us.x.inf-13","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-13"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-13 -> us.x.inf-13 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-[None]-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-14","modelId":"x.inf-14","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[null],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-14 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-[None]-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-14","modelId":"x.inf-14","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":[null],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-14","inferenceProfileName":"us.x.inf-14","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-14"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-14 -> us.x.inf-14 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND ']-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-15","modelId":"x.inf-15","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND "],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-15 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-['ON_DEMAND ']-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-15","modelId":"x.inf-15","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND "],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-15","inferenceProfileName":"us.x.inf-15","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-15"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-15 -> us.x.inf-15 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-missing-no-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-missing","modelId":"x.inf-missing","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-missing -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "types-missing-with-profile",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-missing","modelId":"x.inf-missing","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.inf-missing","inferenceProfileName":"us.x.inf-missing","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-missing"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.inf-missing -> us.x.inf-missing - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "types-string",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.inf-string","modelId":"x.inf-string","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":"ON_DEMAND","modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.inf-string -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "ids-empty",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/","modelId":"","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "ids-space",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/ ","modelId":" ","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
  ->   - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "ids-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.no-id","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "ids-number",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.num-id","modelId":5,"modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": ""]),
        Scenario(
            label: "ids-duplicate",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.same","modelId":"x.same","modelName":"First","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.same","modelId":"x.same","modelName":"Second","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.same -> x.same - name=First provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=First (P)
x.same -> x.same - name=Second provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=Second (P)
"""]),
        Scenario(
            label: "ids-case",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.Case","modelId":"x.Case","modelName":"A","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.case","modelId":"x.case","modelName":"B","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.Case -> x.Case - name=A provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=A (P)
x.case -> x.case - name=B provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=B (P)
"""]),
        Scenario(
            label: "ids-unusual",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/weird id with spaces","modelId":"weird id with spaces","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/ünïcode.modèl","modelId":"ünïcode.modèl","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/a.b.c.d.e","modelId":"a.b.c.d.e","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/.leading","modelId":".leading","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/trailing.","modelId":"trailing.","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/no-dot","modelId":"no-dot","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": #"""
weird id with spaces -> weird id with spaces - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
\u00fcn\u00efcode.mod\u00e8l -> \u00fcn\u00efcode.mod\u00e8l - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
a.b.c.d.e -> a.b.c.d.e - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
.leading -> .leading - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
trailing. -> trailing. - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
no-dot -> no-dot - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""#]),
        Scenario(
            label: "name-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.name-missing","modelId":"x.name-missing","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.name-missing -> x.name-missing - name=x.name-missing provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=x.name-missing (P)
"""]),
        Scenario(
            label: "name-empty",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.name-empty","modelId":"x.name-empty","modelName":"","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.name-empty -> x.name-empty - name= provider=P life=ACTIVE img=False prof=False anth=False invoke=True display= (P)
"""]),
        Scenario(
            label: "name-blank",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.name-blank","modelId":"x.name-blank","modelName":"  ","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.name-blank -> x.name-blank - name=   provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=   (P)
"""]),
        Scenario(
            label: "name-number",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.name-number","modelId":"x.name-number","modelName":5,"providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.name-number -> x.name-number - name=x.name-number provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=x.name-number (P)
"""]),
        Scenario(
            label: "provider-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.prov-missing","modelId":"x.prov-missing","modelName":"N","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.prov-missing -> x.prov-missing - name=N provider= life=ACTIVE img=False prof=False anth=False invoke=True display=N
"""]),
        Scenario(
            label: "provider-empty",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.prov-empty","modelId":"x.prov-empty","modelName":"N","providerName":"","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.prov-empty -> x.prov-empty - name=N provider= life=ACTIVE img=False prof=False anth=False invoke=True display=N
"""]),
        Scenario(
            label: "provider-anthropic-lowercase",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.claude","modelId":"acme.claude","modelName":"N","providerName":"anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
acme.claude -> acme.claude - name=N provider=anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=N (anthropic)
"""]),
        Scenario(
            label: "provider-anthropic-upper",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.claude","modelId":"acme.claude","modelName":"N","providerName":"ANTHROPIC","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
acme.claude -> acme.claude - name=N provider=ANTHROPIC life=ACTIVE img=False prof=False anth=True invoke=True display=N (ANTHROPIC)
"""]),
        Scenario(
            label: "provider-anthropic-spaced",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.claude","modelId":"acme.claude","modelName":"N","providerName":" Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
acme.claude -> acme.claude - name=N provider= Anthropic life=ACTIVE img=False prof=False anth=False invoke=True display=N ( Anthropic)
"""]),
        Scenario(
            label: "id-anthropic-prefix-cased",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/Anthropic.claude-x","modelId":"Anthropic.claude-x","modelName":"N","providerName":"Other","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropicx.claude","modelId":"anthropicx.claude","modelName":"N","providerName":"Other","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic-claude","modelId":"anthropic-claude","modelName":"N","providerName":"Other","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
Anthropic.claude-x -> Anthropic.claude-x - name=N provider=Other life=ACTIVE img=False prof=False anth=True invoke=True display=N (Other)
anthropicx.claude -> anthropicx.claude - name=N provider=Other life=ACTIVE img=False prof=False anth=False invoke=True display=N (Other)
anthropic-claude -> anthropic-claude - name=N provider=Other life=ACTIVE img=False prof=False anth=False invoke=True display=N (Other)
"""]),
        Scenario(
            label: "summaries-not-objects",
            models: #"[1,"x",null,[],{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.ok","modelId":"x.ok","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
x.ok -> x.ok - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-status-inactive",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"INACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-status-lower",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"active","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-status-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-status-null",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":null,"type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-status-number",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":5,"type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-type-application",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"APPLICATION"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-type-lower",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"system_defined"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-type-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-type-null",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":null}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-id-missing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-id-empty",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"","inferenceProfileName":"","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-id-number",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":5,"inferenceProfileName":5,"models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-id-no-dot",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"plainid","inferenceProfileName":"plainid","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> plainid - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-id-leading-dot",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":".x.target-v1:0","inferenceProfileName":".x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> .x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-id-two-prefixes",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.extra.x.target-v1:0","inferenceProfileName":"us.extra.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.extra.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-models-empty-suffix-match",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-models-missing-suffix-match",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-models-not-array",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","models":{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0"},"status":"ACTIVE"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-models-other-model-suffix-not-match",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.prefix-x.target-v1:0","inferenceProfileName":"us.prefix-x.target-v1:0","models":[],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-arn-no-marker",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","inferenceProfileName":"us.other-v1:0","models":[{"modelArn":"arn:aws:bedrock:us-east-1::model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-arn-marker-first",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","inferenceProfileName":"us.other-v1:0","models":[{"modelArn":"foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.other-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-arn-marker-twice",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","inferenceProfileName":"us.other-v1:0","models":[{"modelArn":"arn:foundation-model/foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-arn-number",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","inferenceProfileName":"us.other-v1:0","models":[{"modelArn":5},{"modelArn":null},"text",null,{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.other-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-arn-with-trailing",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.other-v1:0","inferenceProfileName":"us.other-v1:0","models":[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0/extra"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> <null> - name=N provider=P life=ACTIVE img=False prof=False anth=False invoke=False display=N (P)
"""]),
        Scenario(
            label: "profile-summaries-junk",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[1,"x",null,[],{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "profile-with-model-id-inside-different-model",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.other-v1:0","modelId":"x.other-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.combo-v1:0","inferenceProfileName":"us.combo-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"},{"modelArn":"arn:aws:bedrock:::foundation-model/x.other-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.combo-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
x.other-v1:0 -> us.combo-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-all",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"global.x.target-v1:0","inferenceProfileName":"global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"eu.x.target-v1:0","inferenceProfileName":"eu.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"apac.x.target-v1:0","inferenceProfileName":"apac.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"jp.x.target-v1:0","inferenceProfileName":"jp.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"au.x.target-v1:0","inferenceProfileName":"au.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"ca.x.target-v1:0","inferenceProfileName":"ca.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us-gov.x.target-v1:0","inferenceProfileName":"us-gov.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"zz.x.target-v1:0","inferenceProfileName":"zz.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":".x.target-v1:0","inferenceProfileName":".x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: [
                "us-east-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "eu-west-1": """
x.target-v1:0 -> eu.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-northeast-1": """
x.target-v1:0 -> jp.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-southeast-2": """
x.target-v1:0 -> au.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ca-central-1": """
x.target-v1:0 -> ca.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "us-gov-west-1": """
x.target-v1:0 -> us-gov.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "me-central-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
            ]),
        Scenario(
            label: "prefix-only-global",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"global.x.target-v1:0","inferenceProfileName":"global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-us",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-eu",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"eu.x.target-v1:0","inferenceProfileName":"eu.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> eu.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-apac",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"apac.x.target-v1:0","inferenceProfileName":"apac.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> apac.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-jp",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"jp.x.target-v1:0","inferenceProfileName":"jp.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> jp.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-au",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"au.x.target-v1:0","inferenceProfileName":"au.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> au.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-ca",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"ca.x.target-v1:0","inferenceProfileName":"ca.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> ca.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-us-gov",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us-gov.x.target-v1:0","inferenceProfileName":"us-gov.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> us-gov.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-zz",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"zz.x.target-v1:0","inferenceProfileName":"zz.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> zz.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-only-empty",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":".x.target-v1:0","inferenceProfileName":".x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> .x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-order-global-first",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"global.x.target-v1:0","inferenceProfileName":"global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: [
                "us-east-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "eu-west-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-northeast-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-southeast-2": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ca-central-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "us-gov-west-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "me-central-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
            ]),
        Scenario(
            label: "prefix-order-us-first",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"global.x.target-v1:0","inferenceProfileName":"global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: [
                "us-east-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "eu-west-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-northeast-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-southeast-2": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ca-central-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "us-gov-west-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "me-central-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
            ]),
        Scenario(
            label: "prefix-two-unlisted",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"zz.x.target-v1:0","inferenceProfileName":"zz.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"yy.x.target-v1:0","inferenceProfileName":"yy.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> zz.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "prefix-unlisted-then-listed",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"zz.x.target-v1:0","inferenceProfileName":"zz.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"global.x.target-v1:0","inferenceProfileName":"global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: [
                "us-east-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "eu-west-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-northeast-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-southeast-2": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ca-central-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "us-gov-west-1": """
x.target-v1:0 -> zz.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "me-central-1": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "": """
x.target-v1:0 -> global.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
            ]),
        Scenario(
            label: "prefix-duplicates",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.x.target-v1:0","inferenceProfileName":"us.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"eu.x.target-v1:0","inferenceProfileName":"eu.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: [
                "us-east-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "eu-west-1": """
x.target-v1:0 -> eu.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-northeast-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ap-southeast-2": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "ca-central-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "us-gov-west-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "me-central-1": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
                "": """
x.target-v1:0 -> us.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
""",
            ]),
        Scenario(
            label: "prefix-case",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.target-v1:0","modelId":"x.target-v1:0","modelName":"N","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"US.x.target-v1:0","inferenceProfileName":"US.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"Global.x.target-v1:0","inferenceProfileName":"Global.x.target-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/x.target-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
x.target-v1:0 -> US.x.target-v1:0 - name=N provider=P life=ACTIVE img=False prof=True anth=False invoke=True display=N (P)
"""]),
        Scenario(
            label: "families-no-profiles",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0","modelId":"anthropic.claude-sonnet-4-5-20250929-v1:0","modelName":"S45","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v2:0","modelId":"anthropic.claude-sonnet-4-5-20250929-v2:0","modelName":"S45v2","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20260101-v1:0","modelId":"anthropic.claude-sonnet-4-5-20260101-v1:0","modelName":"S45new","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-1-20250805-v1:0","modelId":"anthropic.claude-opus-4-1-20250805-v1:0","modelName":"O41","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-1-20250805-v1:0","modelId":"anthropic.claude-opus-4-1-20250805-v1:0","modelName":"O41dup","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0","modelId":"amazon.nova-pro-v1:0","modelName":"NovaPro","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-2-pro-v1:0","modelId":"amazon.nova-2-pro-v1:0","modelName":"NovaPro2","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-lite-v1:0","modelId":"amazon.nova-lite-v1:0","modelName":"NovaLite","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-70b-instruct-v1:0","modelId":"meta.llama3-70b-instruct-v1:0","modelName":"L3","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama4-scout-17b-instruct-v1:0","modelId":"meta.llama4-scout-17b-instruct-v1:0","modelName":"L4s","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama4-maverick-17b-instruct-v1:0","modelId":"meta.llama4-maverick-17b-instruct-v1:0","modelName":"L4m","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/mistral.mistral-large-2402-v1:0","modelId":"mistral.mistral-large-2402-v1:0","modelName":"M1","providerName":"Mistral AI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/mistral.mistral-large-2407-v1:0","modelId":"mistral.mistral-large-2407-v1:0","modelName":"M2","providerName":"Mistral AI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/deepseek.r1-v1:0","modelId":"deepseek.r1-v1:0","modelName":"R1","providerName":"DeepSeek","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/deepseek.v3-v1:0","modelId":"deepseek.v3-v1:0","modelName":"V3","providerName":"DeepSeek","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/qwen.qwen3-32b-v1:0","modelId":"qwen.qwen3-32b-v1:0","modelName":"Q32","providerName":"Qwen","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-oss-20b-1:0","modelId":"openai.gpt-oss-20b-1:0","modelName":"G20","providerName":"OpenAI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-oss-120b-1:0","modelId":"openai.gpt-oss-120b-1:0","modelName":"G120","providerName":"OpenAI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/cohere.command-r-v1:0","modelId":"cohere.command-r-v1:0","modelName":"CR","providerName":"Cohere","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
anthropic.claude-sonnet-4-5-20250929-v2:0 -> anthropic.claude-sonnet-4-5-20250929-v2:0 R name=S45v2 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=S45v2 (Anthropic)
anthropic.claude-opus-4-1-20250805-v1:0 -> anthropic.claude-opus-4-1-20250805-v1:0 R name=O41 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=O41 (Anthropic)
anthropic.claude-opus-4-1-20250805-v1:0 -> anthropic.claude-opus-4-1-20250805-v1:0 R name=O41dup provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=O41dup (Anthropic)
amazon.nova-2-pro-v1:0 -> amazon.nova-2-pro-v1:0 R name=NovaPro2 provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaPro2 (Amazon)
meta.llama4-scout-17b-instruct-v1:0 -> meta.llama4-scout-17b-instruct-v1:0 R name=L4s provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L4s (Meta)
mistral.mistral-large-2402-v1:0 -> mistral.mistral-large-2402-v1:0 R name=M1 provider=Mistral AI life=ACTIVE img=False prof=False anth=False invoke=True display=M1 (Mistral AI)
deepseek.r1-v1:0 -> deepseek.r1-v1:0 R name=R1 provider=DeepSeek life=ACTIVE img=False prof=False anth=False invoke=True display=R1 (DeepSeek)
qwen.qwen3-32b-v1:0 -> qwen.qwen3-32b-v1:0 R name=Q32 provider=Qwen life=ACTIVE img=False prof=False anth=False invoke=True display=Q32 (Qwen)
openai.gpt-oss-20b-1:0 -> openai.gpt-oss-20b-1:0 R name=G20 provider=OpenAI life=ACTIVE img=False prof=False anth=False invoke=True display=G20 (OpenAI)
amazon.nova-pro-v1:0 -> amazon.nova-pro-v1:0 - name=NovaPro provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaPro (Amazon)
meta.llama4-maverick-17b-instruct-v1:0 -> meta.llama4-maverick-17b-instruct-v1:0 - name=L4m provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L4m (Meta)
meta.llama3-70b-instruct-v1:0 -> meta.llama3-70b-instruct-v1:0 - name=L3 provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L3 (Meta)
amazon.nova-lite-v1:0 -> amazon.nova-lite-v1:0 - name=NovaLite provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaLite (Amazon)
cohere.command-r-v1:0 -> cohere.command-r-v1:0 - name=CR provider=Cohere life=ACTIVE img=False prof=False anth=False invoke=True display=CR (Cohere)
anthropic.claude-sonnet-4-5-20260101-v1:0 -> <null> - name=S45new provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=False display=S45new (Anthropic)
anthropic.claude-sonnet-4-5-20250929-v1:0 -> <null> - name=S45 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=False display=S45 (Anthropic)
mistral.mistral-large-2407-v1:0 -> <null> - name=M2 provider=Mistral AI life=ACTIVE img=False prof=False anth=False invoke=False display=M2 (Mistral AI)
deepseek.v3-v1:0 -> <null> - name=V3 provider=DeepSeek life=ACTIVE img=False prof=False anth=False invoke=False display=V3 (DeepSeek)
openai.gpt-oss-120b-1:0 -> <null> - name=G120 provider=OpenAI life=ACTIVE img=False prof=False anth=False invoke=False display=G120 (OpenAI)
"""]),
        Scenario(
            label: "families-some-profiles",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0","modelId":"anthropic.claude-sonnet-4-5-20250929-v1:0","modelName":"S45","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v2:0","modelId":"anthropic.claude-sonnet-4-5-20250929-v2:0","modelName":"S45v2","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20260101-v1:0","modelId":"anthropic.claude-sonnet-4-5-20260101-v1:0","modelName":"S45new","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-1-20250805-v1:0","modelId":"anthropic.claude-opus-4-1-20250805-v1:0","modelName":"O41","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-1-20250805-v1:0","modelId":"anthropic.claude-opus-4-1-20250805-v1:0","modelName":"O41dup","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0","modelId":"amazon.nova-pro-v1:0","modelName":"NovaPro","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-2-pro-v1:0","modelId":"amazon.nova-2-pro-v1:0","modelName":"NovaPro2","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-lite-v1:0","modelId":"amazon.nova-lite-v1:0","modelName":"NovaLite","providerName":"Amazon","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-70b-instruct-v1:0","modelId":"meta.llama3-70b-instruct-v1:0","modelName":"L3","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama4-scout-17b-instruct-v1:0","modelId":"meta.llama4-scout-17b-instruct-v1:0","modelName":"L4s","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/meta.llama4-maverick-17b-instruct-v1:0","modelId":"meta.llama4-maverick-17b-instruct-v1:0","modelName":"L4m","providerName":"Meta","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/mistral.mistral-large-2402-v1:0","modelId":"mistral.mistral-large-2402-v1:0","modelName":"M1","providerName":"Mistral AI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/mistral.mistral-large-2407-v1:0","modelId":"mistral.mistral-large-2407-v1:0","modelName":"M2","providerName":"Mistral AI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/deepseek.r1-v1:0","modelId":"deepseek.r1-v1:0","modelName":"R1","providerName":"DeepSeek","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/deepseek.v3-v1:0","modelId":"deepseek.v3-v1:0","modelName":"V3","providerName":"DeepSeek","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/qwen.qwen3-32b-v1:0","modelId":"qwen.qwen3-32b-v1:0","modelName":"Q32","providerName":"Qwen","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-oss-20b-1:0","modelId":"openai.gpt-oss-20b-1:0","modelName":"G20","providerName":"OpenAI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-oss-120b-1:0","modelId":"openai.gpt-oss-120b-1:0","modelName":"G120","providerName":"OpenAI","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["PROVISIONED","INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/cohere.command-r-v1:0","modelId":"cohere.command-r-v1:0","modelName":"CR","providerName":"Cohere","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: #"[{"inferenceProfileId":"us.anthropic.claude-sonnet-4-5-20250929-v1:0","inferenceProfileName":"us.anthropic.claude-sonnet-4-5-20250929-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.mistral.mistral-large-2407-v1:0","inferenceProfileName":"us.mistral.mistral-large-2407-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/mistral.mistral-large-2407-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.deepseek.v3-v1:0","inferenceProfileName":"us.deepseek.v3-v1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/deepseek.v3-v1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"},{"inferenceProfileId":"us.openai.gpt-oss-120b-1:0","inferenceProfileName":"us.openai.gpt-oss-120b-1:0","models":[{"modelArn":"arn:aws:bedrock:::foundation-model/openai.gpt-oss-120b-1:0"}],"status":"ACTIVE","type":"SYSTEM_DEFINED"}]"#,
            expected: ["*": """
anthropic.claude-sonnet-4-5-20250929-v2:0 -> anthropic.claude-sonnet-4-5-20250929-v2:0 R name=S45v2 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=S45v2 (Anthropic)
anthropic.claude-opus-4-1-20250805-v1:0 -> anthropic.claude-opus-4-1-20250805-v1:0 R name=O41 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=O41 (Anthropic)
anthropic.claude-opus-4-1-20250805-v1:0 -> anthropic.claude-opus-4-1-20250805-v1:0 R name=O41dup provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=O41dup (Anthropic)
amazon.nova-2-pro-v1:0 -> amazon.nova-2-pro-v1:0 R name=NovaPro2 provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaPro2 (Amazon)
meta.llama4-scout-17b-instruct-v1:0 -> meta.llama4-scout-17b-instruct-v1:0 R name=L4s provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L4s (Meta)
mistral.mistral-large-2407-v1:0 -> us.mistral.mistral-large-2407-v1:0 R name=M2 provider=Mistral AI life=ACTIVE img=False prof=True anth=False invoke=True display=M2 (Mistral AI)
deepseek.v3-v1:0 -> us.deepseek.v3-v1:0 R name=V3 provider=DeepSeek life=ACTIVE img=False prof=True anth=False invoke=True display=V3 (DeepSeek)
qwen.qwen3-32b-v1:0 -> qwen.qwen3-32b-v1:0 R name=Q32 provider=Qwen life=ACTIVE img=False prof=False anth=False invoke=True display=Q32 (Qwen)
openai.gpt-oss-120b-1:0 -> us.openai.gpt-oss-120b-1:0 R name=G120 provider=OpenAI life=ACTIVE img=False prof=True anth=False invoke=True display=G120 (OpenAI)
anthropic.claude-sonnet-4-5-20250929-v1:0 -> us.anthropic.claude-sonnet-4-5-20250929-v1:0 - name=S45 provider=Anthropic life=ACTIVE img=False prof=True anth=True invoke=True display=S45 (Anthropic)
amazon.nova-pro-v1:0 -> amazon.nova-pro-v1:0 - name=NovaPro provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaPro (Amazon)
meta.llama4-maverick-17b-instruct-v1:0 -> meta.llama4-maverick-17b-instruct-v1:0 - name=L4m provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L4m (Meta)
meta.llama3-70b-instruct-v1:0 -> meta.llama3-70b-instruct-v1:0 - name=L3 provider=Meta life=ACTIVE img=False prof=False anth=False invoke=True display=L3 (Meta)
mistral.mistral-large-2402-v1:0 -> mistral.mistral-large-2402-v1:0 - name=M1 provider=Mistral AI life=ACTIVE img=False prof=False anth=False invoke=True display=M1 (Mistral AI)
deepseek.r1-v1:0 -> deepseek.r1-v1:0 - name=R1 provider=DeepSeek life=ACTIVE img=False prof=False anth=False invoke=True display=R1 (DeepSeek)
openai.gpt-oss-20b-1:0 -> openai.gpt-oss-20b-1:0 - name=G20 provider=OpenAI life=ACTIVE img=False prof=False anth=False invoke=True display=G20 (OpenAI)
amazon.nova-lite-v1:0 -> amazon.nova-lite-v1:0 - name=NovaLite provider=Amazon life=ACTIVE img=False prof=False anth=False invoke=True display=NovaLite (Amazon)
cohere.command-r-v1:0 -> cohere.command-r-v1:0 - name=CR provider=Cohere life=ACTIVE img=False prof=False anth=False invoke=True display=CR (Cohere)
anthropic.claude-sonnet-4-5-20260101-v1:0 -> <null> - name=S45new provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=False display=S45new (Anthropic)
"""]),
        Scenario(
            label: "families-newest-uncallable",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-5-20251101-v1:0","modelId":"anthropic.claude-opus-4-5-20251101-v1:0","modelName":"O45","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-4-1-20250805-v1:0","modelId":"anthropic.claude-opus-4-1-20250805-v1:0","modelName":"O41","providerName":"Anthropic","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
anthropic.claude-opus-4-1-20250805-v1:0 -> anthropic.claude-opus-4-1-20250805-v1:0 R name=O41 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=True display=O41 (Anthropic)
anthropic.claude-opus-4-5-20251101-v1:0 -> <null> - name=O45 provider=Anthropic life=ACTIVE img=False prof=False anth=True invoke=False display=O45 (Anthropic)
"""]),
        Scenario(
            label: "ordering-ties",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-0","modelId":"x.tie-0","modelName":"b","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-1","modelId":"x.tie-1","modelName":"a","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-2","modelId":"x.tie-2","modelName":"B","providerName":"p","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-3","modelId":"x.tie-3","modelName":"A","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-4","modelId":"x.tie-4","modelName":"a","providerName":"p","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-5","modelId":"x.tie-5","modelName":"_a","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-6","modelId":"x.tie-6","modelName":"aa","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-7","modelId":"x.tie-7","modelName":"a_","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-8","modelId":"x.tie-8","modelName":"Z","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-9","modelId":"x.tie-9","modelName":"z","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-10","modelId":"x.tie-10","modelName":"ß","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/x.tie-11","modelId":"x.tie-11","modelName":"SS","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": #"""
x.tie-11 -> x.tie-11 - name=SS provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=SS (P)
x.tie-10 -> x.tie-10 - name=\u00df provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=\u00df (P)
x.tie-9 -> x.tie-9 - name=z provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=z (P)
x.tie-8 -> x.tie-8 - name=Z provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=Z (P)
x.tie-7 -> x.tie-7 - name=a_ provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=a_ (P)
x.tie-6 -> x.tie-6 - name=aa provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=aa (P)
x.tie-5 -> x.tie-5 - name=_a provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=_a (P)
x.tie-4 -> x.tie-4 - name=a provider=p life=ACTIVE img=False prof=False anth=False invoke=True display=a (p)
x.tie-3 -> x.tie-3 - name=A provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=A (P)
x.tie-2 -> x.tie-2 - name=B provider=p life=ACTIVE img=False prof=False anth=False invoke=True display=B (p)
x.tie-1 -> x.tie-1 - name=a provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=a (P)
x.tie-0 -> x.tie-0 - name=b provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=b (P)
"""#]),
        Scenario(
            label: "ordering-non-families",
            models: #"[{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-v1:0","modelId":"acme.thing-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-v2:0","modelId":"acme.thing-v2:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-2-v1:0","modelId":"acme.thing-2-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-10-v1:0","modelId":"acme.thing-10-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-1-5-v1:0","modelId":"acme.thing-1-5-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-20250101-v1:0","modelId":"acme.thing-20250101-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-beta","modelId":"acme.thing-beta","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-3","modelId":"acme.thing-3","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-3-v1:0","modelId":"acme.thing-3-v1:0","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}},{"modelArn":"arn:aws:bedrock:us-east-1::foundation-model/acme.thing-","modelId":"acme.thing-","modelName":"T","providerName":"P","inputModalities":["TEXT"],"outputModalities":["TEXT"],"responseStreamingSupported":true,"inferenceTypesSupported":["ON_DEMAND"],"modelLifecycle":{"status":"ACTIVE"}}]"#,
            profiles: "[]",
            expected: ["*": """
acme.thing-10-v1:0 -> acme.thing-10-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-3-v1:0 -> acme.thing-3-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-2-v1:0 -> acme.thing-2-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-1-5-v1:0 -> acme.thing-1-5-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-20250101-v1:0 -> acme.thing-20250101-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-3 -> acme.thing-3 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-v2:0 -> acme.thing-v2:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-v1:0 -> acme.thing-v1:0 - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing-beta -> acme.thing-beta - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
acme.thing- -> acme.thing- - name=T provider=P life=ACTIVE img=False prof=False anth=False invoke=True display=T (P)
"""]),
    ]
}
