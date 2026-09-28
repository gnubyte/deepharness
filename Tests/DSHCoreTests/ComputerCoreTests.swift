import XCTest
import CoreGraphics
import ImageIO
@testable import DSHCore

/// Encode a flat-colour image, for header/size tests.
func makeTestImage(width: Int, height: Int, jpeg: Bool = false,
                   color: (CGFloat, CGFloat, CGFloat) = (0.2, 0.4, 0.8)) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let type = (jpeg ? "public.jpeg" : "public.png") as CFString
    let dest = CGImageDestinationCreateWithData(data, type, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// A stub "screenshot" tool that returns an image.
struct FakeShotTool: ToolExecutor {
    static let name = "screenshot"
    static let spec = ToolSpec(name: name, description: "fake", parameters: "{}")
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        ToolResult(output: "Screenshot 64x48",
                   images: [MessageAttachment(kind: .image, name: "shot.png", data: makeTestImage(width: 64, height: 48))])
    }
}

final class ImageSizeTests: XCTestCase {
    func testPNGAndJPEGDimensionsFromHeader() {
        XCTAssertEqual(ImageSize.dimensions(of: makeTestImage(width: 320, height: 200))?.width, 320)
        XCTAssertEqual(ImageSize.dimensions(of: makeTestImage(width: 320, height: 200))?.height, 200)
        let jpeg = makeTestImage(width: 411, height: 97, jpeg: true)
        XCTAssertEqual(ImageSize.dimensions(of: jpeg)?.width, 411)
        XCTAssertEqual(ImageSize.dimensions(of: jpeg)?.height, 97)
        XCTAssertNil(ImageSize.dimensions(of: Data([1, 2, 3])))
    }

    func testTokenCostFollowsPixelsNotBytes() {
        let shot = makeTestImage(width: 1400, height: 900)
        // 50 x 33 patches of 28px.
        XCTAssertEqual(ImageSize.tokens(for: shot), 50 * 33)
        XCTAssertEqual(ImageSize.tokens(for: Data([9, 9, 9])), 1_500)
        // The estimator must not count base64 length for an image.
        let msg = LLMMessage.user("look", attachments: [MessageAttachment(kind: .image, name: "a.png", data: shot)])
        XCTAssertLessThan(TokenEstimate.message(msg), 3_000)
    }
}

final class ToolImageEngineTests: XCTestCase {
    private func engine(_ client: ScriptedClient, preset: PermissionPreset = .fullAccess,
                        vision: Bool = true, keep: Int = 3,
                        gate: @escaping @Sendable (String, String, String) async -> Bool = { _, _, _ in true },
                        grants: ComputerGrants = ComputerGrants()) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        return Engine(client: client, registry: ToolRegistry(tools: [FakeShotTool(), EchoTool()]),
                      systemPrompt: "s",
                      config: .init(maxIterations: 8, toolTimeout: 5, model: "t",
                                    maxToolImageMessages: keep, visionEnabled: vision),
                      workspace: root, policy: PermissionPolicy(preset: preset, workspaceRoot: root),
                      permissionGate: gate, computerGrants: grants)
    }

    func testToolImagesReachTheModelOnAFollowUpUserMessage() async throws {
        let shot = ToolCall(id: "c1", name: "screenshot", arguments: "{}")
        let client = ScriptedClient(turns: [.init(text: "looking", calls: [shot]), .init(text: "I see a blue box")])
        let result = try await engine(client).run(messages: [], userText: "what's on screen?", sink: { _ in })
        // Second request: assistant call, its tool result, THEN the image message.
        let second = client.requests[1].messages
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertEqual(second.last?.attachments?.count, 1)
        XCTAssertEqual(second.last?.imageSource, "screenshot")
        XCTAssertEqual(result.finalText, "I see a blue box")
    }

    func testOldToolImagesArePrunedButNewestKept() async throws {
        var turns: [ScriptedClient.Turn] = []
        for i in 0..<5 { turns.append(.init(text: "s\(i)", calls: [ToolCall(id: "c\(i)", name: "screenshot", arguments: "{}")])) }
        turns.append(.init(text: "done"))
        let client = ScriptedClient(turns: turns)
        let result = try await engine(client, keep: 2).run(messages: [], userText: "go", sink: { _ in })
        let images = result.messages.filter { $0.imageSource != nil }
        XCTAssertEqual(images.count, 5)
        XCTAssertEqual(images.filter { $0.attachments?.isEmpty == false }.count, 2, "only the newest 2 keep pixels")
        XCTAssertTrue(images.first?.content?.contains("removed to save context") ?? false)
        // A user's own attachment is never pruned.
        var msgs: [LLMMessage] = [.user("mine", attachments: [MessageAttachment(kind: .image, name: "x.png", data: Data([1]))])]
        Engine.pruneToolImages(&msgs, keep: 0)
        XCTAssertEqual(msgs[0].attachments?.count, 1)
    }

    func testNoVisionModelGetsTextInsteadOfImages() async throws {
        let client = ScriptedClient(turns: [.init(text: "", calls: [ToolCall(id: "c1", name: "screenshot", arguments: "{}")]), .init(text: "ok")])
        let result = try await engine(client, vision: false).run(messages: [], userText: "look", sink: { _ in })
        XCTAssertNil(result.messages.first { $0.imageSource != nil })
        let tool = result.messages.first { $0.role == .tool }
        XCTAssertTrue(tool?.content?.contains("can't take images") ?? false)
    }

    func testFirstScreenshotAsksOnceThenHoldsForTheChat() async throws {
        let asked = LockedList()
        let grants = ComputerGrants()
        let calls = (0..<3).map { ToolCall(id: "c\($0)", name: "screenshot", arguments: "{}") }
        let client = ScriptedClient(turns: [.init(text: "", calls: calls), .init(text: "done")])
        _ = try await engine(client, preset: .workspaceWrite,
                             gate: { _, name, detail in asked.add("\(name): \(detail)"); return true },
                             grants: grants).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(asked.items.count, 1)
        XCTAssertTrue(asked.items[0].contains("Screen access"))
        XCTAssertTrue(grants.has(.observe))
        XCTAssertFalse(grants.has(.control))
    }

    func testDeclinedScreenAccessReturnsDenial() async throws {
        let client = ScriptedClient(turns: [.init(text: "", calls: [ToolCall(id: "c1", name: "screenshot", arguments: "{}")]), .init(text: "ok")])
        let result = try await engine(client, preset: .workspaceWrite, gate: { _, _, _ in false })
            .run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.deniedCount, 1)
        XCTAssertNil(result.messages.first { $0.imageSource != nil })
    }

    func testPlanModeNeverDrivesTheMachine() async throws {
        struct FakeMouse: ToolExecutor {
            static let name = "mouse"
            static let spec = ToolSpec(name: name, description: "", parameters: "{}")
            func execute(args: JSONString, in context: ToolContext) async -> ToolResult { ToolResult(output: "clicked") }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let client = ScriptedClient(turns: [.init(text: "", calls: [ToolCall(id: "c1", name: "mouse", arguments: "{}")]), .init(text: "ok")])
        let e = Engine(client: client, registry: ToolRegistry(tools: [FakeMouse()]), systemPrompt: "s",
                       config: .init(model: "t"), workspace: root,
                       policy: PermissionPolicy(preset: .plan, workspaceRoot: root),
                       permissionGate: { _, _, _ in true })
        let result = try await e.run(messages: [], userText: "click", sink: { _ in })
        XCTAssertEqual(result.deniedCount, 1)
        XCTAssertTrue(result.messages.first { $0.role == .tool }?.content?.contains("Plan mode") ?? false)
    }

    func testBackgroundProcessStartIsGatedLikeShell() async throws {
        struct FakeStart: ToolExecutor {
            static let name = "process_start"
            static let spec = ToolSpec(name: name, description: "", parameters: "{}")
            func execute(args: JSONString, in context: ToolContext) async -> ToolResult { ToolResult(output: "started") }
        }
        let asked = LockedList()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let calls = [ToolCall(id: "a", name: "process_start", arguments: #"{"command":"godot --path ."}"#),
                     ToolCall(id: "b", name: "process_start", arguments: #"{"command":"rm -rf build"}"#)]
        let client = ScriptedClient(turns: [.init(text: "", calls: calls), .init(text: "ok")])
        let e = Engine(client: client, registry: ToolRegistry(tools: [FakeStart()]), systemPrompt: "s",
                       config: .init(model: "t"), workspace: root,
                       policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                       permissionGate: { _, _, detail in asked.add(detail); return false })
        _ = try await e.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(asked.items.count, 1, "the harmless command runs; the rm asks")
        XCTAssertTrue(asked.items[0].contains("rm -rf build"))
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
