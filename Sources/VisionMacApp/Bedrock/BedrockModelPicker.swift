import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - Pick a model

/// The model page: the Region's chat models — recommended ones first, everything else one click away, a
/// search box, the Region switchable in place — each with a badge saying whether it is ready to use, needs
/// a one-time form, or has terms to accept. Picking a model shows what it needs in your account, right
/// under the list.
struct ModelPage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "square.grid.2x2")
            GuideHeading("Pick a model")
            GuideLead("These are the chat models Bedrock offers in \(BedrockRegions.name(of: guide.region)). The recommended ones are good at coding with tools; you can switch later.")
            controls
            content
            if guide.selected != nil { AccessSummary(guide: guide) }
            GuideAside("Each model is billed by AWS per use (per thousand words or so, in and out). Claude models are made by Anthropic; Amazon Nova by Amazon; Llama by Meta. Some models are only reachable through a \"cross-Region inference profile\" — AWS runs them in several nearby Regions for capacity; Vision picks the right one for you.")
            GuideStuck("The model you want isn't listed? It may not be offered in this Region: pick another one above (the model list changes with the Region).")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            RegionPicker(guide: guide)
            Button {
                guide.loadModels()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Ask AWS for the list again")
            .disabled(guide.loadingModels)
            TextField("Search models", text: $guide.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private var content: some View {
        if guide.loadingModels && guide.models == nil {
            GuideBusy("Asking AWS which models this Region has…")
        } else if let error = guide.modelsError {
            GuideNote(.error, error, title: "Couldn't list the models") {
                Button("Try again") { guide.loadModels() }.controlSize(.small)
            }
            PermissionsHelp()
        } else if (guide.models ?? []).filter(\.canInvoke).isEmpty {
            if guide.models != nil {
                GuideNote(.warning, "AWS lists no chat models Vision can use in \(BedrockRegions.name(of: guide.region)). Pick another Region above — US East (N. Virginia) or US West (Oregon) have the most.")
            }
        } else if !guide.search.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults
        } else {
            list
        }
    }

    private var searchResults: some View {
        let matches = guide.visibleModels
        return VStack(alignment: .leading, spacing: 8) {
            if matches.isEmpty {
                GuideNote(.info, "No model matches “\(guide.search)”. Clear the search to see them all.")
            }
            ForEach(matches) { card($0) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(guide.recommendedModels) { card($0) }
            let others = guide.otherModels
            if !others.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { guide.showAll || (guide.selected.map { picked in others.contains { $0.modelID == picked.modelID } } ?? false) },
                    set: { guide.showAll = $0 })) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(others) { card($0) }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("More models in this Region (\(others.count))")
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
    }

    private func card(_ model: BedrockModel) -> some View {
        BedrockModelCard(model: model,
                         selected: guide.selected?.modelID == model.modelID,
                         access: guide.selected?.modelID == model.modelID && guide.access != nil ? guide.access : guide.readiness[model.modelID],
                         checking: guide.selected?.modelID == model.modelID && guide.checking) {
            guide.choose(model)
        }
    }
}

/// One model as a card: who makes it, what it can do, and whether this account can use it yet.
struct BedrockModelCard: View {
    let model: BedrockModel
    let selected: Bool
    let access: ModelAccess?
    let checking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderMonogram(provider: model.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if checking {
                    ProgressView().controlSize(.small)
                } else if let access {
                    ReadinessBadge(state: access.state)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Theme.hairline)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(selected ? Color.accentColor.opacity(0.55) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var details: String {
        var parts = [model.provider]
        if model.acceptsImages { parts.append("reads images") }
        if model.usesInferenceProfile { parts.append("cross-Region") }
        if model.recommended { parts.append("recommended") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A round-cornered initial in the maker's colour, so a list of models is scannable by who made them.
struct ProviderMonogram: View {
    let provider: String

    var body: some View {
        Text(String(provider.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch provider.lowercased() {
        case let name where name.contains("anthropic"): Color(red: 0.80, green: 0.42, blue: 0.30)
        case let name where name.contains("amazon"): Color(red: 0.14, green: 0.20, blue: 0.28)
        case let name where name.contains("meta"): Color(red: 0.13, green: 0.44, blue: 0.86)
        case let name where name.contains("mistral"): Color(red: 0.94, green: 0.36, blue: 0.16)
        case let name where name.contains("deepseek"): Color(red: 0.24, green: 0.36, blue: 0.85)
        case let name where name.contains("cohere"): Color(red: 0.42, green: 0.28, blue: 0.70)
        case let name where name.contains("openai"): Color(red: 0.10, green: 0.55, blue: 0.45)
        case let name where name.contains("qwen"): Color(red: 0.42, green: 0.25, blue: 0.78)
        default:
            // Any other maker gets a steady colour of its own.
            Color(hue: Double(abs(provider.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) }) % 360) / 360,
                  saturation: 0.45, brightness: 0.68)
        }
    }
}

/// "Ready", "One short form", "Terms to accept" … as a small coloured badge.
struct ReadinessBadge: View {
    let state: ModelAccessState

    var body: some View {
        let (text, symbol, tint) = look
        Label(text, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.13), in: Capsule())
    }

    private var look: (String, String, Color) {
        switch state {
        case .ready: ("Ready", "checkmark", Theme.successTint)
        case .needsUseCaseForm: ("One short form", "doc.text", .accentColor)
        case .needsAgreement: ("Terms to accept", "signature", .accentColor)
        case .pending: ("Setting up", "hourglass", Theme.noticeTint)
        case .notInRegion: ("Not offered here", "nosign", .secondary)
        case .notAuthorized: ("Needs permission", "lock", Theme.errorTint)
        case .error: ("Couldn't check", "questionmark", .secondary)
        }
    }
}

/// What the chosen model needs in your account, under the list.
struct AccessSummary: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        if let model = guide.selected {
            if guide.checking {
                GuideBusy("Checking what \(model.name) needs in your account…")
            } else if let access = guide.access {
                switch access.state {
                case .ready:
                    GuideNote(.success, access.message, title: "Ready to use")
                case .needsUseCaseForm:
                    GuideNote(.info, "Anthropic asks every AWS account a few short questions once before its first use of Claude. The next page fills them in with you.", title: "One short form first")
                case .needsAgreement:
                    GuideNote(.info, "This model is sold through AWS Marketplace. The next page shows its price and licence for you to accept.", title: "Terms to accept")
                case .pending:
                    GuideNote(.info, access.message, title: "AWS is still setting it up")
                case .notInRegion:
                    GuideNote(.warning, access.message, title: "Not offered here")
                case .notAuthorized:
                    GuideNote(.error, access.message + ((access.missingPermissions ?? []).isEmpty ? "" : " Missing: \((access.missingPermissions ?? []).joined(separator: ", ")).")
                              , title: "Your AWS user isn't allowed yet")
                    PermissionsHelp()
                case .error:
                    GuideNote(.error, access.message, title: "Couldn't check this model") {
                        Button("Check again") { guide.recheckSelected() }.controlSize(.small)
                    }
                }
            } else if !model.canInvoke {
                GuideNote(.warning, "This model can't be called in this Region.")
            }
        }
    }
}

/// The IAM policy to hand an administrator.
struct PermissionsHelp: View {
    var body: some View {
        DisclosureGroup("What to ask your AWS administrator for") {
            VStack(alignment: .leading, spacing: 8) {
                GuideParagraph(BedrockPermissions.explanation, secondary: true)
                GuideCopyable(text: BedrockPermissions.policyJSON, caption: "Policy")
            }
            .padding(.top, 6)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Enabling the chosen model

/// The page between choosing a model and connecting: whatever the model needs before its first use.
struct AccessPage: View {
    @Bindable var guide: BedrockGuideModel

    var body: some View {
        if let model = guide.selected, let access = guide.access {
            if access.isReady {
                VStack(alignment: .leading, spacing: 14) {
                    GuideIcon(systemName: "checkmark.seal")
                    GuideHeading("\(model.name) is ready")
                    GuideNote(.success, "Your AWS account can use \(model.name) now.")
                    GuideLead("Next, Vision saves the connection and sends a first message.")
                }
            } else {
                switch access.state {
                case .needsUseCaseForm: UseCasePage(guide: guide, model: model)
                case .needsAgreement: TermsPage(guide: guide, model: model, access: access)
                default: WaitPage(guide: guide, model: model, access: access)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                GuideHeading("Pick a model first")
                GuideLead("Go back and choose a model.")
            }
        }
    }
}

private struct UseCasePage: View {
    @Bindable var guide: BedrockGuideModel
    let model: BedrockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "doc.text")
            GuideHeading("A few questions from Anthropic, once")
            GuideLead("Before an AWS account first uses Claude, Anthropic asks what it's for. AWS passes your answers on. It takes a minute, and covers every Claude model — you won't see it again.")
            GuideField(label: "Company or organization", hint: "Using it on your own? Your name is fine.") {
                TextField("Your company, or your own name", text: $guide.answers.company).textFieldStyle(.roundedBorder)
            }
            GuideField(label: "Website", hint: "Your company's site. On your own? A personal site or profile page works.") {
                TextField("https://example.com", text: $guide.answers.website).textFieldStyle(.roundedBorder)
            }
            GuideField(label: "Industry") {
                Picker("", selection: $guide.answers.industry) {
                    ForEach(UseCaseForm.industries, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 300, alignment: .leading)
            }
            if guide.answers.industry == "Other" {
                GuideField(label: "Your industry") {
                    TextField("Your industry", text: $guide.answers.otherIndustry).textFieldStyle(.roundedBorder)
                }
            }
            GuideField(label: "Who will use it") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(UseCaseAnswers.Audience.allCases, id: \.self) { audience in
                        Button {
                            guide.answers.audience = audience
                        } label: {
                            Label(audience.label, systemImage: guide.answers.audience == audience ? "largecircle.fill.circle" : "circle")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            GuideField(label: "What you'll use it for") {
                TextEditor(text: $guide.answers.useCases)
                    .font(.callout)
                    .frame(minHeight: 70)
                    .padding(4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            }
            if guide.working {
                GuideBusy(guide.workStatus ?? "Working…")
            } else {
                Button("Send") { guide.submitUseCase() }.buttonStyle(.borderedProminent)
            }
            if let error = guide.workError, !guide.working { GuideNote(.error, error) }
            GuideAside("This is Anthropic's \"first time use\" form, the same one the AWS console shows. It's stored for your AWS account (or your whole organization) and can't be changed later, so answer as you would on the website.")
            GuideStuck("Rather fill it in on the AWS website? Open Amazon Bedrock in the AWS console, choose any Claude model in the Model catalog and submit the form there — then come back and press Check again.")
            if !guide.working { GuideLink("Check again") { guide.waitForAccess() } }
        }
    }
}

private struct TermsPage: View {
    @Bindable var guide: BedrockGuideModel
    let model: BedrockModel
    let access: ModelAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "signature")
            GuideHeading("\(model.name) has terms to accept")
            GuideLead("\(model.provider) sells this model through AWS Marketplace. Accepting its terms subscribes your AWS account to it; you pay only for what you use, on your AWS bill.")
            if let offer = access.offer {
                VStack(alignment: .leading, spacing: 8) {
                    GuideSubheading("Price")
                    if offer.prices.isEmpty { GuideParagraph(offer.pricingSummary) }
                    ForEach(offer.prices, id: \.self) { price in GuideParagraph("• " + price.display) }
                    if let duration = offer.durationText { GuideParagraph("Agreement length: \(duration)", secondary: true) }
                    if let refund = offer.refundPolicy, !refund.isEmpty { GuideParagraph("Refunds: \(refund)", secondary: true) }
                    GuideSubheading("Licence")
                    if let url = offer.legalTermsURL.flatMap(URL.init(string:)) {
                        GuideLink("Read the model's licence (EULA) in your browser") { guide.backend.open(url) }
                    } else {
                        GuideParagraph("The offer doesn't link a licence; see the model's page in the AWS console.")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                Toggle("I have read and accept these terms for my AWS account", isOn: $guide.acceptTerms)
                    .toggleStyle(.checkbox)
                    .disabled(guide.working)
                if guide.working {
                    GuideBusy(guide.workStatus ?? "Working…")
                } else {
                    Button("Accept and enable") { guide.acceptAgreement() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!guide.acceptTerms)
                }
            } else {
                GuideNote(.info, access.message)
            }
            if let error = guide.workError, !guide.working {
                GuideNote(.error, error) { Button("Check again") { guide.waitForAccess() }.controlSize(.small) }
            }
            GuideAside("Models from other companies are sold on AWS Marketplace. Accepting creates a subscription in your AWS account (you'll see it under AWS Marketplace › Manage subscriptions). There's no monthly fee for Bedrock's on-demand models — only what you use.")
            GuideStuck("It says your user can't subscribe? Accepting needs AWS Marketplace permissions; the \"What to ask your AWS administrator for\" section on the model page has the exact policy.")
        }
    }
}

private struct WaitPage: View {
    @Bindable var guide: BedrockGuideModel
    let model: BedrockModel
    let access: ModelAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideIcon(systemName: "hourglass")
            GuideHeading("Getting \(model.name) ready")
            if guide.working {
                GuideBusy(guide.workStatus ?? access.message)
            } else {
                GuideNote(access.state == .pending ? .info : .warning, guide.workError ?? access.message) {
                    Button("Check again") { guide.waitForAccess() }.controlSize(.small)
                }
            }
            if access.state == .notAuthorized { PermissionsHelp() }
            GuideAside("The first time an AWS account uses a model sold on AWS Marketplace, AWS sets up a subscription in the background. It usually takes a minute or two and at most about 15.")
        }
    }
}
