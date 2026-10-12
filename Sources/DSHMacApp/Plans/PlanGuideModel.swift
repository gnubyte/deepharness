import Foundation
import Observation
import DSHCore

/// The pages of the "Connect a subscription plan" guide, in order.
enum PlanPage: Int, CaseIterable, Comparable {
    case plan, key, paste, check, model, use, done

    static func < (a: PlanPage, b: PlanPage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .plan: "Which plan?"
        case .key: "Get your key"
        case .paste: "Paste your key"
        case .check: "Check it"
        case .model: "Pick the model"
        case .use: "How DSH uses it"
        case .done: "Done"
        }
    }
}

/// How a plan's model is used. Like `ModelRole`, plus leaving it in the list for later.
enum PlanRole: String, CaseIterable, Identifiable {
    case primary, subagent, backup, justAdd
    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Primary"
        case .subagent: "Subagent"
        case .backup: "Backup"
        case .justAdd: "Just add it"
        }
    }

    var detail: String {
        switch self {
        case .primary: "Answers you, and hands out side tasks. Whatever led before keeps helping as a subagent server."
        case .subagent: "Takes side tasks from the primary, in parallel. They count against the plan."
        case .backup: "Takes over a turn when the primary stops answering."
        case .justAdd: "Keep it in Settings ▸ AI Models, to use when you choose it."
        }
    }

    var icon: String {
        switch self {
        case .primary: "crown"
        case .subagent: "gearshape.2"
        case .backup: "arrow.triangle.branch"
        case .justAdd: "plus.circle"
        }
    }
}

struct PlanGuideRequest: Identifiable {
    let id = UUID()
}

/// What the guide does outside: the plan's API, and the browser.
@MainActor
protocol PlanGuideBackend: AnyObject {
    /// `GET <base>/models`.
    func listModels(route: ProviderProfile) async throws -> [String]
    /// A 1-token chat completion with `model` — for plans whose `/models` doesn't answer.
    func ping(route: ProviderProfile, model: String) async throws
    func sayHello(route: ProviderProfile) async throws -> String
    func open(_ url: URL)
}

/// The "Connect a subscription plan" guide: pick the plan and region, get the key (steps, the key page, the
/// plan's terms), paste it (to the Keychain), check it, pick the model, choose how DSH uses it — the route is not
/// private, so DSH masks sensitive details before sending — then save it and say hello.
@MainActor
@Observable
final class PlanGuideModel {
    @ObservationIgnored let backend: any PlanGuideBackend
    @ObservationIgnored let config: AppConfig
    @ObservationIgnored var onSaved: (ProviderProfile) -> Void = { _ in }
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onLeave: () -> Void = {}

    private(set) var page: PlanPage = .plan
    var title: String { "Connect a subscription plan · \(page.title)" }
    var stepText: String { "Step \(page.rawValue + 1) of \(PlanPage.allCases.count)" }

    // MARK: Choices

    private(set) var planID: String?
    var regionID = "international" {
        didSet { if regionID != oldValue { resetCheck() } }
    }
    var key = "" {
        didSet { if key != oldValue { resetCheck() } }
    }

    var plan: SubscriptionPlan? { planID.flatMap(PlanCatalog.plan) }
    var region: SubscriptionPlan.Region? { plan?.region(regionID) }
    var keyProblem: String? { plan.flatMap { PlanCatalog.keyProblem(key, plan: $0) } }

    // MARK: Checking

    private(set) var checking = false
    private(set) var checked = false
    private(set) var checkError: String?
    /// What `/models` listed (nil when it wasn't asked or didn't answer).
    private(set) var listed: [String]?

    // MARK: The model and how it's used

    private(set) var selectedModel: String?
    var role: PlanRole
    var isPrivate = false

    // MARK: Saving

    private(set) var saving = false
    private(set) var saved: ProviderProfile?
    private(set) var hello: String?
    private(set) var helloError: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(backend: any PlanGuideBackend, config: AppConfig) {
        self.backend = backend
        self.config = config
        role = config.mainRoute == nil ? .primary : .justAdd
    }

    func dispose() { task?.cancel() }

    func choose(_ id: String) {
        guard id != planID, let chosen = PlanCatalog.plan(id) else { return }
        planID = id
        if !chosen.regions.contains(where: { $0.id == regionID }) { regionID = chosen.regions[0].id }
        resetCheck()
        // Every plan is an online service: not private unless the user says so.
        isPrivate = RoutePrivacy.isPrivateAddress(chosen.region(regionID).baseURL)
    }

    private func resetCheck() {
        checked = false
        checkError = nil
        listed = nil
        selectedModel = nil
        saved = nil
        hello = nil
        helloError = nil
    }

    // MARK: Navigation

    var nextLabel: String {
        switch page {
        case .use: "Save and Say Hello"
        case .done: "Start Chatting"
        default: "Next"
        }
    }

    var canAdvance: Bool {
        switch page {
        case .plan: return plan != nil
        case .key: return true
        case .paste: return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .check: return checked && !checking
        case .model: return selectedModel != nil
        case .use: return true
        case .done: return saved != nil && !saving
        }
    }

    func next() {
        guard canAdvance else { return }
        if page == .done { onFinish(); return }
        if let following = PlanPage(rawValue: page.rawValue + 1) { go(following) }
    }

    func back() {
        if page == .plan { onLeave(); return }
        go(PlanPage(rawValue: page.rawValue - 1) ?? .plan)
    }

    func go(_ target: PlanPage) {
        page = target
        switch target {
        case .check where !checked && !checking: runCheck()
        case .model where selectedModel == nil: selectedModel = models.first?.id
        case .done where saved == nil && !saving: saveAndSayHello()
        default: break
        }
    }

    // MARK: The route

    /// The key as pasted, minus the spaces around it.
    private var cleanKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The route this guide makes: OpenAI-compatible (OpenAI's own for OpenAI), at the region's address, the
    /// privacy the user chose (stored only when it differs from the default), interactive-only when the plan says.
    func route(model: String) -> ProviderProfile? {
        guard let plan, let region else { return nil }
        let name = plan.regions.count > 1 && region.id != "international" ? "\(plan.routeName) (\(region.name.components(separatedBy: " (").first ?? region.name))" : plan.routeName
        let defaultPrivacy = RoutePrivacy.isPrivateAddress(region.baseURL)
        return ProviderProfile(kind: plan.id == "openai" ? .openAI : .openAICompat, name: name, baseURL: region.baseURL,
                               apiKey: cleanKey.isEmpty ? nil : cleanKey, model: model,
                               isPrivate: isPrivate == defaultPrivacy ? nil : isPrivate,
                               interactiveOnly: plan.interactiveOnly ? true : nil)
    }

    // MARK: Checking

    /// `GET /models` for a plan that lists them (a 404 or 405 falls back to a 1-token reply), else a 1-token
    /// reply from the recommended model.
    func runCheck() {
        guard let plan, let region, let probe = route(model: plan.recommended?.id ?? "") else { return }
        checking = true
        checkError = nil
        task?.cancel()
        task = Task {
            defer { checking = false }
            do {
                if plan.listsModels {
                    do {
                        listed = try await backend.listModels(route: probe)
                    } catch let error where Self.notListed(error) {
                        guard let model = plan.recommended?.id else { throw error }
                        try await backend.ping(route: probe, model: model)
                    }
                } else if let model = plan.recommended?.id {
                    try await backend.ping(route: probe, model: model)
                }
                checked = true
                selectedModel = models.first?.id
            } catch is CancellationError {
            } catch {
                checkError = PlanCatalog.explain(error, plan: plan, region: region)
            }
        }
    }

    /// `/models` isn't there (404, 405): the key may still be fine.
    private static func notListed(_ error: Error) -> Bool {
        if case LLMError.http(let status, _) = error { return status == 404 || status == 405 }
        return false
    }

    // MARK: Models

    /// What `/models` listed (for a plan that lists them), else the plan's own; recommended first.
    var models: [SubscriptionPlan.Model] {
        guard let plan else { return [] }
        return PlanCatalog.models(for: plan, listed: listed)
    }

    func pick(_ id: String) { selectedModel = id }

    /// The context window, when known ("1M context").
    func contextText(_ model: SubscriptionPlan.Model) -> String? {
        let window = model.contextWindow ?? FallbackContextWindow.limit(for: model.id)
        return window.map { "\(ModelSizes.short($0)) context" }
    }

    // MARK: Saving

    private func saveAndSayHello() {
        guard let model = selectedModel, var route = route(model: model) else { return }
        saving = true
        let key = route.apiKey ?? ""
        route.apiKey = nil
        switch role {
        case .primary:
            config.store(route)
            config.makeMain(route.routeID)
        case .subagent:
            route.subagentWorker = true
            config.store(route)
        case .backup:
            route.backup = true
            config.store(route)
        case .justAdd:
            config.store(route)
        }
        if config.mainRoute == nil { config.makeMain(route.routeID) }
        config.setAPIKey(key, for: route)
        saved = route
        onSaved(route)
        sayHello()
    }

    func sayHello() {
        guard var route = saved else { return }
        route.apiKey = cleanKey
        saving = true
        helloError = nil
        task?.cancel()
        task = Task {
            defer { saving = false }
            do {
                hello = try await backend.sayHello(route: route)
            } catch is CancellationError {
            } catch {
                if let plan, let region {
                    helloError = PlanCatalog.explain(error, plan: plan, region: region)
                } else {
                    helloError = error.localizedDescription
                }
            }
        }
    }

    func openKeyPage() {
        if let region { backend.open(region.keyPage) }
    }
}
