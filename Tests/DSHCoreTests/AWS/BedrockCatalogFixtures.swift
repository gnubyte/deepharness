import Foundation

// GENERATED FROM THE WINDOWS APP: a realistic Bedrock catalog and the ordering/invoke ids it must produce
// Every expected value below is what the C# implementation answered (dshwindows, BedrockSetup.cs, built and
// run on .NET 8), captured by a probe program; the tests check that the Swift port answers the same.
// The probe compiled the unmodified src/Dsh.Core/Aws/BedrockSetup.cs (dshwindows at bf08ade) and printed its answers;
// nothing below was written by hand, so don't edit it by hand either (regenerate it from a fresh probe run).

enum BedrockCatalogFixtures {
    /// A Bedrock text-model catalog in a compact form (`M` = a model summary, `P` = a system inference profile,
    /// `P!` = one with a status/type of its own):
    ///   M id | name | provider | inference types | lifecycle | streaming | output modalities | input modalities
    ///   P profile id | Regions its models run in
    static let spec = """
# A realistic Bedrock text-model catalog (shapes from list-foundation-models --by-output-modality TEXT)
# M id | name | provider | inference types | lifecycle | streaming | output | input
# P profile id | regions the profile routes to     (SYSTEM_DEFINED, ACTIVE)
# P! profile id | regions | status | type

# Anthropic
M anthropic.claude-3-haiku-20240307-v1:0:48k | Claude 3 Haiku | Anthropic | PROVISIONED | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-haiku-20240307-v1:0:200k | Claude 3 Haiku | Anthropic | PROVISIONED | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-haiku-20240307-v1:0 | Claude 3 Haiku | Anthropic | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-sonnet-20240229-v1:0:28k | Claude 3 Sonnet | Anthropic | PROVISIONED | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-sonnet-20240229-v1:0 | Claude 3 Sonnet | Anthropic | ON_DEMAND | LEGACY | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-opus-20240229-v1:0 | Claude 3 Opus | Anthropic | ON_DEMAND | LEGACY | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-5-sonnet-20240620-v1:0 | Claude 3.5 Sonnet | Anthropic | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-5-sonnet-20241022-v2:0 | Claude 3.5 Sonnet v2 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-3-5-haiku-20241022-v1:0 | Claude 3.5 Haiku | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M anthropic.claude-3-7-sonnet-20250219-v1:0 | Claude 3.7 Sonnet | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-sonnet-4-20250514-v1:0 | Claude Sonnet 4 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-opus-4-20250514-v1:0 | Claude Opus 4 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-opus-4-1-20250805-v1:0 | Claude Opus 4.1 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-sonnet-4-5-20250929-v1:0 | Claude Sonnet 4.5 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-haiku-4-5-20251001-v1:0 | Claude Haiku 4.5 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-opus-4-5-20251101-v1:0 | Claude Opus 4.5 | Anthropic | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M anthropic.claude-v2:1 | Claude | Anthropic | ON_DEMAND | LEGACY | 1 | TEXT | TEXT
M anthropic.claude-instant-v1 | Claude Instant | Anthropic | ON_DEMAND | LEGACY | 1 | TEXT | TEXT

# Amazon
M amazon.nova-micro-v1:0 | Nova Micro | Amazon | ON_DEMAND,INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M amazon.nova-lite-v1:0 | Nova Lite | Amazon | ON_DEMAND,INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE,VIDEO
M amazon.nova-pro-v1:0 | Nova Pro | Amazon | ON_DEMAND,INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE,VIDEO
M amazon.nova-premier-v1:0 | Nova Premier | Amazon | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE,VIDEO
M amazon.titan-text-express-v1 | Titan Text G1 - Express | Amazon | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M amazon.titan-text-lite-v1 | Titan Text G1 - Lite | Amazon | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M amazon.titan-embed-text-v2:0 | Titan Text Embeddings V2 | Amazon | ON_DEMAND | ACTIVE | 0 | EMBEDDING | TEXT
M amazon.nova-canvas-v1:0 | Nova Canvas | Amazon | ON_DEMAND | ACTIVE | 0 | IMAGE | TEXT,IMAGE

# Meta
M meta.llama3-8b-instruct-v1:0 | Llama 3 8B Instruct | Meta | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-70b-instruct-v1:0 | Llama 3 70B Instruct | Meta | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-1-8b-instruct-v1:0 | Llama 3.1 8B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-1-70b-instruct-v1:0 | Llama 3.1 70B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-1-405b-instruct-v1:0 | Llama 3.1 405B Instruct | Meta | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-2-1b-instruct-v1:0 | Llama 3.2 1B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-2-3b-instruct-v1:0 | Llama 3.2 3B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M meta.llama3-2-11b-instruct-v1:0 | Llama 3.2 11B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M meta.llama3-2-90b-instruct-v1:0 | Llama 3.2 90B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M meta.llama3-3-70b-instruct-v1:0 | Llama 3.3 70B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M meta.llama4-scout-17b-instruct-v1:0 | Llama 4 Scout 17B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE
M meta.llama4-maverick-17b-instruct-v1:0 | Llama 4 Maverick 17B Instruct | Meta | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE

# Mistral
M mistral.mistral-7b-instruct-v0:2 | Mistral 7B Instruct | Mistral AI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M mistral.mixtral-8x7b-instruct-v0:1 | Mixtral 8x7B Instruct | Mistral AI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M mistral.mistral-large-2402-v1:0 | Mistral Large (24.02) | Mistral AI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M mistral.mistral-large-2407-v1:0 | Mistral Large (24.07) | Mistral AI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M mistral.mistral-small-2402-v1:0 | Mistral Small (24.02) | Mistral AI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M mistral.pixtral-large-2502-v1:0 | Pixtral Large (25.02) | Mistral AI | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT,IMAGE

# DeepSeek, Qwen, OpenAI
M deepseek.r1-v1:0 | DeepSeek-R1 | DeepSeek | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M deepseek.v3-v1:0 | DeepSeek-V3.1 | DeepSeek | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M qwen.qwen3-coder-480b-a35b-v1:0 | Qwen3 Coder 480B A35B Instruct | Qwen | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M qwen.qwen3-235b-a22b-2507-v1:0 | Qwen3 235B A22B 2507 | Qwen | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M qwen.qwen3-32b-v1:0 | Qwen3 32B (dense) | Qwen | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M qwen.qwen3-coder-30b-a3b-v1:0 | Qwen3 Coder 30B A3B Instruct | Qwen | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M openai.gpt-oss-20b-1:0 | gpt-oss-20b | OpenAI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M openai.gpt-oss-120b-1:0 | gpt-oss-120b | OpenAI | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT

# Others
M cohere.command-r-plus-v1:0 | Command R+ | Cohere | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M cohere.command-r-v1:0 | Command R | Cohere | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M ai21.jamba-1-5-large-v1:0 | Jamba 1.5 Large | AI21 Labs | ON_DEMAND | ACTIVE | 0 | TEXT | TEXT
M ai21.jamba-1-5-mini-v1:0 | Jamba 1.5 Mini | AI21 Labs | ON_DEMAND | ACTIVE | 1 | TEXT | TEXT
M writer.palmyra-x4-v1:0 | Palmyra X4 | Writer | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT
M writer.palmyra-x5-v1:0 | Palmyra X5 | Writer | INFERENCE_PROFILE | ACTIVE | 1 | TEXT | TEXT

# Inference profiles
P us.anthropic.claude-3-5-sonnet-20241022-v2:0 | us-east-1,us-east-2,us-west-2
P us.anthropic.claude-3-5-haiku-20241022-v1:0 | us-east-1,us-east-2,us-west-2
P us.anthropic.claude-3-7-sonnet-20250219-v1:0 | us-east-1,us-east-2,us-west-2
P eu.anthropic.claude-3-7-sonnet-20250219-v1:0 | eu-central-1,eu-west-1,eu-west-3,eu-north-1
P us.anthropic.claude-sonnet-4-20250514-v1:0 | us-east-1,us-east-2,us-west-2
P eu.anthropic.claude-sonnet-4-20250514-v1:0 | eu-central-1,eu-west-1,eu-west-3,eu-north-1
P apac.anthropic.claude-sonnet-4-20250514-v1:0 | ap-northeast-1,ap-south-1,ap-southeast-2
P global.anthropic.claude-sonnet-4-20250514-v1:0 |
P us.anthropic.claude-opus-4-20250514-v1:0 | us-east-1,us-east-2,us-west-2
P us.anthropic.claude-opus-4-1-20250805-v1:0 | us-east-1,us-east-2,us-west-2
P us.anthropic.claude-sonnet-4-5-20250929-v1:0 | us-east-1,us-east-2,us-west-2
P eu.anthropic.claude-sonnet-4-5-20250929-v1:0 | eu-central-1,eu-west-1,eu-west-3
P jp.anthropic.claude-sonnet-4-5-20250929-v1:0 | ap-northeast-1,ap-northeast-3
P apac.anthropic.claude-sonnet-4-5-20250929-v1:0 | ap-northeast-1,ap-south-1,ap-southeast-2
P au.anthropic.claude-sonnet-4-5-20250929-v1:0 | ap-southeast-2,ap-southeast-4
P global.anthropic.claude-sonnet-4-5-20250929-v1:0 |
P us.anthropic.claude-haiku-4-5-20251001-v1:0 | us-east-1,us-east-2,us-west-2
P eu.anthropic.claude-haiku-4-5-20251001-v1:0 | eu-central-1,eu-west-1
P jp.anthropic.claude-haiku-4-5-20251001-v1:0 | ap-northeast-1,ap-northeast-3
P global.anthropic.claude-haiku-4-5-20251001-v1:0 |
P global.anthropic.claude-opus-4-5-20251101-v1:0 |
P us.anthropic.claude-opus-4-5-20251101-v1:0 | us-east-1,us-east-2,us-west-2
P us.amazon.nova-micro-v1:0 | us-east-1,us-east-2,us-west-2
P us.amazon.nova-lite-v1:0 | us-east-1,us-east-2,us-west-2
P us.amazon.nova-pro-v1:0 | us-east-1,us-east-2,us-west-2
P eu.amazon.nova-pro-v1:0 | eu-central-1,eu-west-1,eu-west-3,eu-north-1
P apac.amazon.nova-pro-v1:0 | ap-northeast-1,ap-south-1,ap-southeast-2
P us.amazon.nova-premier-v1:0 | us-east-1,us-east-2,us-west-2
P us.meta.llama3-1-8b-instruct-v1:0 | us-east-1,us-east-2,us-west-2
P us.meta.llama3-1-70b-instruct-v1:0 | us-east-1,us-east-2,us-west-2
P eu.meta.llama3-1-70b-instruct-v1:0 | eu-central-1,eu-west-1,eu-west-3
P us.meta.llama3-2-1b-instruct-v1:0 | us-east-1,us-west-2
P us.meta.llama3-2-3b-instruct-v1:0 | us-east-1,us-west-2
P eu.meta.llama3-2-3b-instruct-v1:0 | eu-central-1,eu-west-1,eu-west-3
P us.meta.llama3-2-11b-instruct-v1:0 | us-east-1,us-west-2
P us.meta.llama3-2-90b-instruct-v1:0 | us-east-1,us-west-2
P us.meta.llama3-3-70b-instruct-v1:0 | us-east-1,us-east-2,us-west-2
P us.meta.llama4-scout-17b-instruct-v1:0 | us-east-1,us-east-2,us-west-1,us-west-2
P us.meta.llama4-maverick-17b-instruct-v1:0 | us-east-1,us-east-2,us-west-1,us-west-2
P us.mistral.pixtral-large-2502-v1:0 | us-east-1,us-east-2,us-west-2
P eu.mistral.pixtral-large-2502-v1:0 | eu-central-1,eu-west-1,eu-west-3
P us.deepseek.r1-v1:0 | us-east-1,us-east-2,us-west-2
P us.writer.palmyra-x4-v1:0 | us-east-1,us-east-2,us-west-2
P us.writer.palmyra-x5-v1:0 | us-east-1,us-east-2,us-west-2
# Not system routes: ignored
P! abcd1234efgh | us-east-1 | ACTIVE | APPLICATION
P! us.anthropic.claude-opus-4-20250514-v1:0 | us-east-1 | INACTIVE | SYSTEM_DEFINED
P! eu.anthropic.claude-opus-4-20250514-v1:0 | eu-west-1 | ACTIVE | APPLICATION
"""

    /// What `BedrockCatalog.build` answered for `spec` in each Region: one line per model, in order:
    /// model id, the id to call it by (- when none), R when recommended.
    static let expected: [String: String] = [
        "us-east-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 us.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 us.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 us.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 us.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "us-west-2": """
anthropic.claude-sonnet-4-5-20250929-v1:0 us.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 us.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 us.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 us.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "ca-central-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 us.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 us.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 us.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 us.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "sa-east-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 global.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 global.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 global.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "eu-west-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 eu.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 eu.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 eu.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 eu.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 eu.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 eu.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 eu.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "eu-central-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 eu.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 eu.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 eu.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 eu.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 eu.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 eu.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 eu.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "ap-northeast-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 jp.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 jp.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 apac.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "ap-southeast-2": """
anthropic.claude-sonnet-4-5-20250929-v1:0 au.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 global.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 apac.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "ap-south-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 apac.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 global.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 apac.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "us-gov-west-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 us.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 us.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 us.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "me-central-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 global.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 global.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 global.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "EU-WEST-1": """
anthropic.claude-sonnet-4-5-20250929-v1:0 eu.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 eu.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 eu.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 eu.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 eu.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 eu.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 eu.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
        "": """
anthropic.claude-sonnet-4-5-20250929-v1:0 global.anthropic.claude-sonnet-4-5-20250929-v1:0 R
anthropic.claude-opus-4-5-20251101-v1:0 global.anthropic.claude-opus-4-5-20251101-v1:0 R
anthropic.claude-haiku-4-5-20251001-v1:0 global.anthropic.claude-haiku-4-5-20251001-v1:0 R
amazon.nova-pro-v1:0 amazon.nova-pro-v1:0 R
meta.llama4-scout-17b-instruct-v1:0 us.meta.llama4-scout-17b-instruct-v1:0 R
mistral.pixtral-large-2502-v1:0 us.mistral.pixtral-large-2502-v1:0 R
deepseek.v3-v1:0 deepseek.v3-v1:0 R
qwen.qwen3-coder-480b-a35b-v1:0 qwen.qwen3-coder-480b-a35b-v1:0 R
openai.gpt-oss-120b-1:0 openai.gpt-oss-120b-1:0 R
anthropic.claude-sonnet-4-20250514-v1:0 global.anthropic.claude-sonnet-4-20250514-v1:0 -
anthropic.claude-3-7-sonnet-20250219-v1:0 us.anthropic.claude-3-7-sonnet-20250219-v1:0 -
anthropic.claude-3-5-sonnet-20241022-v2:0 us.anthropic.claude-3-5-sonnet-20241022-v2:0 -
anthropic.claude-3-5-sonnet-20240620-v1:0 anthropic.claude-3-5-sonnet-20240620-v1:0 -
anthropic.claude-opus-4-1-20250805-v1:0 us.anthropic.claude-opus-4-1-20250805-v1:0 -
anthropic.claude-opus-4-20250514-v1:0 us.anthropic.claude-opus-4-20250514-v1:0 -
anthropic.claude-3-5-haiku-20241022-v1:0 us.anthropic.claude-3-5-haiku-20241022-v1:0 -
anthropic.claude-3-haiku-20240307-v1:0 anthropic.claude-3-haiku-20240307-v1:0 -
meta.llama4-maverick-17b-instruct-v1:0 us.meta.llama4-maverick-17b-instruct-v1:0 -
meta.llama3-70b-instruct-v1:0 meta.llama3-70b-instruct-v1:0 -
meta.llama3-8b-instruct-v1:0 meta.llama3-8b-instruct-v1:0 -
meta.llama3-3-70b-instruct-v1:0 us.meta.llama3-3-70b-instruct-v1:0 -
meta.llama3-2-90b-instruct-v1:0 us.meta.llama3-2-90b-instruct-v1:0 -
meta.llama3-2-11b-instruct-v1:0 us.meta.llama3-2-11b-instruct-v1:0 -
meta.llama3-2-3b-instruct-v1:0 us.meta.llama3-2-3b-instruct-v1:0 -
meta.llama3-2-1b-instruct-v1:0 us.meta.llama3-2-1b-instruct-v1:0 -
meta.llama3-1-405b-instruct-v1:0 meta.llama3-1-405b-instruct-v1:0 -
meta.llama3-1-70b-instruct-v1:0 us.meta.llama3-1-70b-instruct-v1:0 -
meta.llama3-1-8b-instruct-v1:0 us.meta.llama3-1-8b-instruct-v1:0 -
mistral.mistral-large-2407-v1:0 mistral.mistral-large-2407-v1:0 -
mistral.mistral-large-2402-v1:0 mistral.mistral-large-2402-v1:0 -
mistral.mistral-small-2402-v1:0 mistral.mistral-small-2402-v1:0 -
mistral.mixtral-8x7b-instruct-v0:1 mistral.mixtral-8x7b-instruct-v0:1 -
mistral.mistral-7b-instruct-v0:2 mistral.mistral-7b-instruct-v0:2 -
deepseek.r1-v1:0 us.deepseek.r1-v1:0 -
qwen.qwen3-235b-a22b-2507-v1:0 qwen.qwen3-235b-a22b-2507-v1:0 -
qwen.qwen3-32b-v1:0 qwen.qwen3-32b-v1:0 -
qwen.qwen3-coder-30b-a3b-v1:0 qwen.qwen3-coder-30b-a3b-v1:0 -
openai.gpt-oss-20b-1:0 openai.gpt-oss-20b-1:0 -
writer.palmyra-x5-v1:0 us.writer.palmyra-x5-v1:0 -
writer.palmyra-x4-v1:0 us.writer.palmyra-x4-v1:0 -
ai21.jamba-1-5-mini-v1:0 ai21.jamba-1-5-mini-v1:0 -
amazon.nova-lite-v1:0 amazon.nova-lite-v1:0 -
amazon.nova-micro-v1:0 amazon.nova-micro-v1:0 -
amazon.nova-premier-v1:0 us.amazon.nova-premier-v1:0 -
amazon.titan-text-express-v1 amazon.titan-text-express-v1 -
amazon.titan-text-lite-v1 amazon.titan-text-lite-v1 -
cohere.command-r-v1:0 cohere.command-r-v1:0 -
cohere.command-r-plus-v1:0 cohere.command-r-plus-v1:0 -
""",
    ]

    /// `RecencyComparer` keys: the version numbers, the release date and the revision read from each id, and the family.
    static let recencyKeys: [(id: String, version: [Int64], date: Int64, revision: Int64, family: String?)] = [
        ("anthropic.claude-3-haiku-20240307-v1:0", [3], 20240307, 1, "Claude Haiku"),
        ("anthropic.claude-3-sonnet-20240229-v1:0", [3], 20240229, 1, "Claude Sonnet"),
        ("anthropic.claude-3-opus-20240229-v1:0", [3], 20240229, 1, "Claude Opus"),
        ("anthropic.claude-3-5-sonnet-20240620-v1:0", [3, 5], 20240620, 1, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-v2:0", [3, 5], 20241022, 2, "Claude Sonnet"),
        ("anthropic.claude-3-5-haiku-20241022-v1:0", [3, 5], 20241022, 1, "Claude Haiku"),
        ("anthropic.claude-3-7-sonnet-20250219-v1:0", [3, 7], 20250219, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-20250514-v1:0", [4], 20250514, 1, "Claude Sonnet"),
        ("anthropic.claude-opus-4-20250514-v1:0", [4], 20250514, 1, "Claude Opus"),
        ("anthropic.claude-opus-4-1-20250805-v1:0", [4, 1], 20250805, 1, "Claude Opus"),
        ("anthropic.claude-sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-haiku-4-5-20251001-v1:0", [4, 5], 20251001, 1, "Claude Haiku"),
        ("anthropic.claude-opus-4-5-20251101-v1:0", [4, 5], 20251101, 1, "Claude Opus"),
        ("anthropic.claude-v2:1", [], 0, 2, nil),
        ("anthropic.claude-v2", [], 0, 2, nil),
        ("anthropic.claude-v1", [], 0, 1, nil),
        ("anthropic.claude-instant-v1", [], 0, 1, nil),
        ("anthropic.claude-3-sonnet-20240229-v1:0:28k", [3], 20240229, 1, "Claude Sonnet"),
        ("anthropic.claude-3-sonnet-20240229-v1:0:200k", [3], 20240229, 1, "Claude Sonnet"),
        ("anthropic.claude-3-haiku-20240307-v1:0:48k", [3], 20240307, 1, "Claude Haiku"),
        ("anthropic.claude-sonnet-5-20260601-v1:0", [5], 20260601, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-5-5-20260901-v1:0", [5, 5], 20260901, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-10-20270101-v1:0", [10], 20270101, 1, "Claude Sonnet"),
        ("anthropic.claude-4-sonnet-v1:0", [4], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-v2:0", [4, 5], 0, 2, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v2:0", [4, 5], 20250929, 2, "Claude Sonnet"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, nil),
        ("eu.anthropic.claude-sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, nil),
        ("global.anthropic.claude-sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, nil),
        ("amazon.nova-pro-v1:0", [], 0, 1, "Amazon Nova Pro"),
        ("amazon.nova-lite-v1:0", [], 0, 1, nil),
        ("amazon.nova-micro-v1:0", [], 0, 1, nil),
        ("amazon.nova-premier-v1:0", [], 0, 1, nil),
        ("amazon.nova-2-pro-v1:0", [2], 0, 1, "Amazon Nova Pro"),
        ("amazon.nova-2-lite-v1:0", [2], 0, 1, nil),
        ("amazon.nova-pro", [], 0, 0, "Amazon Nova Pro"),
        ("amazon.novapro", [], 0, 0, nil),
        ("amazon.nova-canvas-v1:0", [], 0, 1, nil),
        ("amazon.titan-text-express-v1", [], 0, 1, nil),
        ("amazon.titan-text-lite-v1", [], 0, 1, nil),
        ("amazon.titan-embed-text-v2:0", [], 0, 2, nil),
        ("meta.llama3-8b-instruct-v1:0", [3, 8], 0, 1, "Llama"),
        ("meta.llama3-70b-instruct-v1:0", [3, 70], 0, 1, "Llama"),
        ("meta.llama3-1-8b-instruct-v1:0", [3, 1, 8], 0, 1, "Llama"),
        ("meta.llama3-1-70b-instruct-v1:0", [3, 1, 70], 0, 1, "Llama"),
        ("meta.llama3-1-405b-instruct-v1:0", [3, 1, 405], 0, 1, "Llama"),
        ("meta.llama3-2-1b-instruct-v1:0", [3, 2, 1], 0, 1, "Llama"),
        ("meta.llama3-2-3b-instruct-v1:0", [3, 2, 3], 0, 1, "Llama"),
        ("meta.llama3-2-11b-instruct-v1:0", [3, 2, 11], 0, 1, "Llama"),
        ("meta.llama3-2-90b-instruct-v1:0", [3, 2, 90], 0, 1, "Llama"),
        ("meta.llama3-3-70b-instruct-v1:0", [3, 3, 70], 0, 1, "Llama"),
        ("meta.llama4-scout-17b-instruct-v1:0", [4, 17], 0, 1, "Llama"),
        ("meta.llama4-maverick-17b-instruct-v1:0", [4, 17], 0, 1, "Llama"),
        ("meta.llama", [], 0, 0, "Llama"),
        ("mistral.mistral-7b-instruct-v0:2", [7], 0, 0, "Mistral"),
        ("mistral.mixtral-8x7b-instruct-v0:1", [8, 7], 0, 0, "Mistral"),
        ("mistral.mistral-large-2402-v1:0", [2402], 0, 1, "Mistral"),
        ("mistral.mistral-large-2407-v1:0", [2407], 0, 1, "Mistral"),
        ("mistral.mistral-small-2402-v1:0", [2402], 0, 1, "Mistral"),
        ("mistral.pixtral-large-2502-v1:0", [2502], 0, 1, "Mistral"),
        ("mistral.magistral-small-2509", [], 0, 2509, "Mistral"),
        ("mistral.ministral-3-8b-instruct", [3, 8], 0, 0, "Mistral"),
        ("mistral.devstral-2-123b", [2, 123], 0, 0, "Mistral"),
        ("mistral.", [], 0, 0, "Mistral"),
        ("deepseek.r1-v1:0", [1], 0, 1, "DeepSeek"),
        ("deepseek.v3-v1:0", [3], 0, 1, "DeepSeek"),
        ("deepseek.v3.1", [3, 1], 0, 0, "DeepSeek"),
        ("qwen.qwen3-coder-480b-a35b-v1:0", [3, 480, 35], 0, 1, "Qwen"),
        ("qwen.qwen3-235b-a22b-2507-v1:0", [3, 235, 22, 2507], 0, 1, "Qwen"),
        ("qwen.qwen3-32b-v1:0", [3, 32], 0, 1, "Qwen"),
        ("qwen.qwen3-coder-30b-a3b-v1:0", [3, 30, 3], 0, 1, "Qwen"),
        ("openai.gpt-oss-20b-1:0", [20], 0, 1, "gpt-oss"),
        ("openai.gpt-oss-120b-1:0", [120], 0, 1, "gpt-oss"),
        ("openai.gpt-oss-safeguard-20b", [20], 0, 0, "gpt-oss"),
        ("openai.gpt-oss", [], 0, 0, "gpt-oss"),
        ("cohere.command-r-plus-v1:0", [], 0, 1, nil),
        ("cohere.command-r-v1:0", [], 0, 1, nil),
        ("ai21.jamba-1-5-large-v1:0", [1, 5], 0, 1, nil),
        ("writer.palmyra-x4-v1:0", [4], 0, 1, nil),
        ("", [], 0, 0, nil),
        ("x", [], 0, 0, nil),
        ("1", [1], 0, 0, nil),
        ("a.b.c", [], 0, 0, nil),
        ("20250101", [], 20250101, 0, nil),
        (".", [], 0, 0, nil),
        ("..", [], 0, 0, nil),
        (".x", [], 0, 0, nil),
        ("anthropic.claude-sonnet-99999999999999999999-v1:0", [], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v99999999999999999999:0", [4, 5], 20250929, 0, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v1:0:5", [4, 5], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v1:0:ab", [4, 5], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v1:0:AB", [4, 5], 20250929, 0, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-1:0", [4, 5], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-1", [4, 5], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929", [4, 5], 0, 20250929, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5", [4], 0, 5, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4", [], 0, 4, "Claude Sonnet"),
        ("anthropic.claude-sonnet", [], 0, 0, "Claude Sonnet"),
        ("anthropic.claude-sonnet-20250101-4-5", [], 20250101, 5, "Claude Sonnet"),
        ("anthropic.claude-sonnet-30000101-4-5-v1:0", [30000101, 4, 5], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-20250101-20260101-v1:0", [], 20260101, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-2025010-v1:0", [2025010], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-202501011-v1:0", [202501011], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-\u{664}-\u{665}-v1:0", [], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-\u{665}-20250929-v1:0", [4], 20250929, 1, "Claude Sonnet"),
        ("anthropic.claude-sonnet-4-5-20250929-v\u{661}:0", [4, 5], 20250929, 0, "Claude Sonnet"),
        ("anthropic.claude-Sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, nil),
        ("Anthropic.claude-sonnet-4-5-20250929-v1:0", [4, 5], 20250929, 1, nil),
        ("anthropic.Claude-sonnet-4", [], 0, 4, nil),
        ("anthropic.claude-1-2-3-4-5-6-7-8-sonnet-v1:0", [1, 2, 3, 4, 5, 6, 7, 8], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-3-sonnet-v1:0", [3], 0, 1, "Claude Sonnet"),
        ("anthropic.claude-3--sonnet", [3], 0, 0, "Claude Sonnet"),
        ("anthropic.claude--sonnet", [], 0, 0, nil),
        ("anthropic.claude-3-", [3], 0, 0, nil),
        ("anthropic.claude-3-5-", [3, 5], 0, 0, nil),
        ("anthropic.claude-3-5", [3], 0, 5, nil),
        ("anthropic.claude--3-sonnet", [3], 0, 0, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-v2:0", [3, 5], 20241022, 2, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-v2", [3, 5], 20241022, 2, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-v", [3, 5], 20241022, 0, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-v:0", [3, 5], 20241022, 0, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-:0", [3, 5], 20241022, 0, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022-0", [3, 5], 20241022, 0, "Claude Sonnet"),
        ("anthropic.claude-3-5-sonnet-20241022v1:0", [3, 5], 20241022, 0, "Claude Sonnet"),
        ("amazon.nova-pro-v1:0:300k", [], 0, 1, "Amazon Nova Pro"),
        ("amazon.nova-lite-v1:0:300k", [], 0, 1, nil),
        ("amazon.nova-5-pro-v1:0", [5], 0, 1, "Amazon Nova Pro"),
        ("amazon.nova-12-pro-v1:0", [12], 0, 1, "Amazon Nova Pro"),
        ("amazon.nova-pro-v2:0", [], 0, 2, "Amazon Nova Pro"),
    ]

    /// The ids above put in order oldest to newest (equal ones keep their place), as the C# comparer orders them.
    static let recencyAscending: [String] = [
        "amazon.nova-pro",
        "amazon.novapro",
        "meta.llama",
        "mistral.",
        "openai.gpt-oss",
        "",
        "x",
        "a.b.c",
        ".",
        "..",
        ".x",
        "anthropic.claude-sonnet",
        "anthropic.claude--sonnet",
        "anthropic.claude-v1",
        "anthropic.claude-instant-v1",
        "amazon.nova-pro-v1:0",
        "amazon.nova-lite-v1:0",
        "amazon.nova-micro-v1:0",
        "amazon.nova-premier-v1:0",
        "amazon.nova-canvas-v1:0",
        "amazon.titan-text-express-v1",
        "amazon.titan-text-lite-v1",
        "cohere.command-r-plus-v1:0",
        "cohere.command-r-v1:0",
        "anthropic.claude-sonnet-99999999999999999999-v1:0",
        "anthropic.claude-sonnet-\u{664}-\u{665}-v1:0",
        "amazon.nova-pro-v1:0:300k",
        "amazon.nova-lite-v1:0:300k",
        "anthropic.claude-v2:1",
        "anthropic.claude-v2",
        "amazon.titan-embed-text-v2:0",
        "amazon.nova-pro-v2:0",
        "anthropic.claude-sonnet-4",
        "anthropic.Claude-sonnet-4",
        "mistral.magistral-small-2509",
        "20250101",
        "anthropic.claude-sonnet-20250101-4-5",
        "anthropic.claude-sonnet-20250101-20260101-v1:0",
        "1",
        "deepseek.r1-v1:0",
        "anthropic.claude-1-2-3-4-5-6-7-8-sonnet-v1:0",
        "ai21.jamba-1-5-large-v1:0",
        "amazon.nova-2-pro-v1:0",
        "amazon.nova-2-lite-v1:0",
        "mistral.devstral-2-123b",
        "anthropic.claude-3--sonnet",
        "anthropic.claude-3-",
        "anthropic.claude--3-sonnet",
        "deepseek.v3-v1:0",
        "anthropic.claude-3-sonnet-v1:0",
        "anthropic.claude-3-5",
        "anthropic.claude-3-sonnet-20240229-v1:0",
        "anthropic.claude-3-opus-20240229-v1:0",
        "anthropic.claude-3-sonnet-20240229-v1:0:28k",
        "anthropic.claude-3-sonnet-20240229-v1:0:200k",
        "anthropic.claude-3-haiku-20240307-v1:0",
        "anthropic.claude-3-haiku-20240307-v1:0:48k",
        "deepseek.v3.1",
        "meta.llama3-1-8b-instruct-v1:0",
        "meta.llama3-1-70b-instruct-v1:0",
        "meta.llama3-1-405b-instruct-v1:0",
        "meta.llama3-2-1b-instruct-v1:0",
        "meta.llama3-2-3b-instruct-v1:0",
        "meta.llama3-2-11b-instruct-v1:0",
        "meta.llama3-2-90b-instruct-v1:0",
        "meta.llama3-3-70b-instruct-v1:0",
        "anthropic.claude-3-5-",
        "anthropic.claude-3-5-sonnet-20240620-v1:0",
        "anthropic.claude-3-5-sonnet-20241022-v",
        "anthropic.claude-3-5-sonnet-20241022-v:0",
        "anthropic.claude-3-5-sonnet-20241022-:0",
        "anthropic.claude-3-5-sonnet-20241022-0",
        "anthropic.claude-3-5-sonnet-20241022v1:0",
        "anthropic.claude-3-5-haiku-20241022-v1:0",
        "anthropic.claude-3-5-sonnet-20241022-v2:0",
        "anthropic.claude-3-5-sonnet-20241022-v2:0",
        "anthropic.claude-3-5-sonnet-20241022-v2",
        "anthropic.claude-3-7-sonnet-20250219-v1:0",
        "mistral.ministral-3-8b-instruct",
        "meta.llama3-8b-instruct-v1:0",
        "qwen.qwen3-coder-30b-a3b-v1:0",
        "qwen.qwen3-32b-v1:0",
        "meta.llama3-70b-instruct-v1:0",
        "qwen.qwen3-235b-a22b-2507-v1:0",
        "qwen.qwen3-coder-480b-a35b-v1:0",
        "anthropic.claude-4-sonnet-v1:0",
        "writer.palmyra-x4-v1:0",
        "anthropic.claude-sonnet-4-5",
        "anthropic.claude-sonnet-4-20250514-v1:0",
        "anthropic.claude-opus-4-20250514-v1:0",
        "anthropic.claude-sonnet-4-\u{665}-20250929-v1:0",
        "anthropic.claude-opus-4-1-20250805-v1:0",
        "anthropic.claude-sonnet-4-5-v2:0",
        "anthropic.claude-sonnet-4-5-20250929",
        "anthropic.claude-sonnet-4-5-20250929-v99999999999999999999:0",
        "anthropic.claude-sonnet-4-5-20250929-v1:0:AB",
        "anthropic.claude-sonnet-4-5-20250929-v\u{661}:0",
        "anthropic.claude-sonnet-4-5-20250929-v1:0",
        "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "anthropic.claude-sonnet-4-5-20250929-v1:0:5",
        "anthropic.claude-sonnet-4-5-20250929-v1:0:ab",
        "anthropic.claude-sonnet-4-5-20250929-1:0",
        "anthropic.claude-sonnet-4-5-20250929-1",
        "anthropic.claude-Sonnet-4-5-20250929-v1:0",
        "Anthropic.claude-sonnet-4-5-20250929-v1:0",
        "anthropic.claude-sonnet-4-5-20250929-v2:0",
        "anthropic.claude-haiku-4-5-20251001-v1:0",
        "anthropic.claude-opus-4-5-20251101-v1:0",
        "meta.llama4-scout-17b-instruct-v1:0",
        "meta.llama4-maverick-17b-instruct-v1:0",
        "amazon.nova-5-pro-v1:0",
        "anthropic.claude-sonnet-5-20260601-v1:0",
        "anthropic.claude-sonnet-5-5-20260901-v1:0",
        "mistral.mistral-7b-instruct-v0:2",
        "mistral.mixtral-8x7b-instruct-v0:1",
        "anthropic.claude-sonnet-10-20270101-v1:0",
        "amazon.nova-12-pro-v1:0",
        "openai.gpt-oss-safeguard-20b",
        "openai.gpt-oss-20b-1:0",
        "openai.gpt-oss-120b-1:0",
        "mistral.mistral-large-2402-v1:0",
        "mistral.mistral-small-2402-v1:0",
        "mistral.mistral-large-2407-v1:0",
        "mistral.pixtral-large-2502-v1:0",
        "anthropic.claude-sonnet-2025010-v1:0",
        "anthropic.claude-sonnet-30000101-4-5-v1:0",
        "anthropic.claude-sonnet-202501011-v1:0",
    ]

    /// FNV-1a (64 bit) of the comparison matrix of `recencyKeys` ids: row i is the sign (<, =, >) of comparing id i with each id j.
    static let recencyMatrixHash = "800fa933201772d4"
}
