import SwiftUI
import VisionHarnessCore

// MARK: - Connect

/// Saves the route and says hello through Bedrock. Once it answers, a newly added model can be given its
/// place in the fleet: the model you talk to, or a subagent server.
struct ConnectPage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "bolt.horizontal.circle")
            GuideHeading("Connect Vision to Bedrock")
            GuideLead("Vision saves the connection — \(guide.selected?.name ?? "your model") in \(BedrockRegions.name(of: guide.region)) — and sends a first message to check everything works.")
            if guide.connecting {
                GuideBusy("Sending a first message through Bedrock…")
            } else if guide.connected, let hello = guide.hello {
                GuideNote(.success, hello, title: "\(guide.selected?.name ?? "The model") answered")
                if guide.editing == nil, guide.hasOtherRoutes { rolePicker }
            } else if let error = guide.connectError {
                GuideNote(.error, error, title: "The first message didn't go through") {
                    Button("Try again") { guide.connect() }.buttonStyle(.borderedProminent)
                }
            }
            GuideAside("The saved connection holds the model, the Region and the name of your AWS CLI sign-in (\"\(guide.profileName)\") — no keys. Each request gets fresh, short-lived credentials from the AWS CLI.")
            GuideStuck("\"Access denied\" right after accepting a model's terms? AWS can take up to 15 minutes to finish a first subscription. Wait a little and press Try again.")
        }
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideSubheading("How should Vision use it?")
            GuideChoice(systemImage: "crown", title: "Main model",
                        detail: "The chat talks to it, and it hands out subagent tasks. Whatever led before keeps helping as a subagent server.",
                        selected: guide.role == .main) { guide.role = .main }
            GuideChoice(systemImage: "gearshape.2", title: "Subagent server",
                        detail: "The main model hands it side tasks that run in parallel. Tasks sent here are billed to your AWS account.",
                        selected: guide.role == .subagents) { guide.role = .subagents }
            GuideAside("You can change this any time: Settings › Models, or the model menu in the toolbar.")
        }
    }
}

// MARK: - Done

struct DonePage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "checkmark.circle")
            GuideHeading("You're all set")
            GuideLead(guide.role == .main || guide.editing != nil
                      ? "Chats now run on \(guide.selected?.name ?? "Bedrock") in your AWS account."
                      : "\(guide.selected?.name ?? "Bedrock") is ready to take subagent tasks from the main model.")
            GuideBullets(items: [
                ("bubble.left.and.bubble.right", "**Start chatting** — press the button below."),
                ("arrow.triangle.swap", "**Switch models** any time: the toolbar's model menu has *Choose a Bedrock Model…*, and Settings › Models has *Change…* on each Bedrock route."),
                ("arrow.clockwise", "**Sign-in**: when your AWS session ends, Vision says so and signs you in again with one click (the browser opens)."),
                ("info.circle", "**Costs** show up on your AWS bill, under Amazon Bedrock (and AWS Marketplace for Marketplace models). AWS Budgets can email you before you spend more than you planned."),
            ])
            apiKeys
            GuideAside("Nothing else was installed or changed: the AWS CLI, its sign-in profile, and (if you accepted any) the model's subscription in your AWS account. To remove the sign-in, run \"\(guide.cliCommand) logout --profile \(guide.profileName)\" in Terminal.")
        }
    }

    private var apiKeys: some View {
        DisclosureGroup("Need a Bedrock API key for another tool?") {
            VStack(alignment: .leading, spacing: 8) {
                GuideParagraph("Some tools (like Claude Code with Bedrock) take a Bedrock API key instead of an AWS sign-in. Vision can make one from your sign-in. It works for 12 hours (or until your sign-in ends).")
                if guide.mintingKey {
                    GuideBusy("Creating a key…")
                } else if let key = guide.apiKey {
                    GuideCopyable(text: key, caption: "Bedrock API key — treat it like a password")
                    Button("Save it in the Credentials Vault") { guide.saveKeyToVault() }
                } else if guide.savedKeyToVault {
                    GuideNote(.success, "Saved in the Credentials Vault as AWS_BEARER_TOKEN_BEDROCK. The agent can use it as {{vault:AWS_BEARER_TOKEN_BEDROCK}} without seeing it.")
                } else if guide.selected != nil {
                    Button("Create a Bedrock API key") { guide.createAPIKey() }
                }
                if let error = guide.apiKeyError { GuideNote(.error, error) }
            }
            .padding(.top, 6)
        }
    }
}
