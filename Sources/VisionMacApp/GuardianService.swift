import Foundation
import VisionHarnessCore

// MARK: - The harness's Guardian connection
//
// One per app. Holds the client and the session, persists the session token
// in the Keychain (under the app's own service, like every other secret),
// and does the work the harness needs: sign in/out, sync prompts up, and the
// settings page's actions (pull skills, export/import chats, upload projects).

@MainActor
public final class GuardianService: ObservableObject {
    /// Where the deployment lives (the wizard's address field).
    public static let defaultURL = "https://guardian.503cm.com"

    @Published public private(set) var client: GuardianClient?
    /// The signed-in user for the UI ("Signed in as …").
    @Published public private(set) var accountEmail: String?
    @Published public private(set) var lastError: String?

    /// Prompts already pushed, so a prompt is never synced twice.
    private var pushedPromptIDs: Set<String> = []
    private let pushedFile: URL

    public init(appSupport: URL, secrets: any SecretStore = AppSecrets.keychain) {
        pushedFile = appSupport.appendingPathComponent("guardian-pushed-prompts.json")
        let address = secrets.read(service: AppIdentity.KeychainService.guardian, account: "address")
            ?? Self.defaultURL
        if let token = secrets.read(service: AppIdentity.KeychainService.guardian, account: "token"), !token.isEmpty {
            let email = secrets.read(service: AppIdentity.KeychainService.guardian, account: "email") ?? ""
            client = try? GuardianClient(baseURL: address.isEmpty ? Self.defaultURL : address,
                                         session: GuardianSession(userID: email, email: email, name: nil, token: token))
            accountEmail = email.isEmpty ? nil : email
        }
        if let data = try? Data(contentsOf: pushedFile),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            pushedPromptIDs = Set(ids)
        }
    }

    public var isSignedIn: Bool { client != nil && accountEmail != nil }

    /// Sign in with the Guardian login and remember the session.
    public func signIn(address: String, email: String, password: String,
                       secrets: any SecretStore = AppSecrets.keychain) async -> Bool {
        lastError = nil
        do {
            let guardian = try GuardianClient(baseURL: address)
            let session = try await guardian.signIn(email: email, password: password)
            secrets.write(session.token, service: AppIdentity.KeychainService.guardian, account: "token")
            secrets.write(session.email, service: AppIdentity.KeychainService.guardian, account: "email")
            secrets.write(address, service: AppIdentity.KeychainService.guardian, account: "address")
            client = guardian
            accountEmail = session.email
            return true
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    public func signOut(secrets: any SecretStore = AppSecrets.keychain) {
        secrets.write(nil, service: AppIdentity.KeychainService.guardian, account: "token")
        secrets.write(nil, service: AppIdentity.KeychainService.guardian, account: "email")
        client = nil
        accountEmail = nil
    }

    // MARK: Prompt sync (item 4)

    /// Push the chat's prompt history up to Guardian's notebook. Idempotent:
    /// each prompt text+time pair is pushed once. Called after a send when
    /// the user is signed in, and from Settings ("Sync now").
    /// - Returns: how many prompts went up on this call.
    @discardableResult
    public func syncPrompts(_ records: [SessionVMPrompt]) async -> Int {
        guard let client else { return 0 }
        let pending = records.filter { !pushedPromptIDs.contains($0.id) }
        guard !pending.isEmpty else { return 0 }
        let prompts = pending.map {
            GuardianPrompt(text: $0.text, at: $0.at, outcome: $0.outcome, source: $0.chatID)
        }
        do {
            let accepted = try await client.pushPrompts(prompts)
            for record in pending { pushedPromptIDs.insert(record.id) }
            persistPushed()
            return accepted
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return 0
        }
    }

    /// The prompt rows the harness hands the service (decoded from the
    /// SessionVM's own type, which VisionHarnessCore cannot see).
    public struct SessionVMPrompt: Sendable {
        public var id: String
        public var text: String
        public var at: Date
        public var outcome: String?
        public var chatID: String
        public init(id: String, text: String, at: Date, outcome: String?, chatID: String) {
            self.id = id
            self.text = text
            self.at = at
            self.outcome = outcome
            self.chatID = chatID
        }
    }

    private func persistPushed() {
        if let data = try? JSONEncoder().encode(Array(pushedPromptIDs)) {
            try? data.write(to: pushedFile, options: .atomic)
        }
    }
}
