import XCTest
@testable import VisionHarnessCore

final class FileToolsTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-filetools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func context(_ root: URL) -> ToolContext {
        ToolContext(workspace: root,
                    policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                    client: ScriptedClient(turns: []),
                    registry: ToolRegistry(tools: []))
    }

    private func files(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    func testManyEditsToOneFileAtTheSameTimeAllLand() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let edits = 24
        let body = (0..<edits).map { String(format: "slot-%02d: open", $0) }.joined(separator: "\n")
        try body.write(to: root.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        let ctx = context(root)

        let results = await withTaskGroup(of: ToolResult.self) { group in
            for i in 0..<edits {
                let args = String(format: #"{"file_path":"shared.txt","old_string":"slot-%02d: open","new_string":"slot-%02d: taken"}"#, i, i)
                group.addTask {
                    await EditTool().execute(args: JSONString(args), in: ctx)
                }
            }
            var out: [ToolResult] = []
            for await result in group { out.append(result) }
            return out
        }

        for result in results {
            XCTAssertTrue(result.output.hasPrefix("Edited shared.txt"), result.output)
        }
        let text = try String(contentsOf: root.appendingPathComponent("shared.txt"), encoding: .utf8)
        XCTAssertFalse(text.contains("open"), text)
        XCTAssertEqual(text.components(separatedBy: "taken").count - 1, edits)
        let leftovers = try files(in: root)
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasSuffix(".vision-tmp") })
    }

    func testEditMatchesACrlfFileInLfFormAndWritesCrlfBack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("win.txt")
        try Data("alpha\r\nbeta\r\n".utf8).write(to: url)
        let ctx = context(root)

        let read = await ReadFileTool().execute(args: JSONString(#"{"file_path":"win.txt"}"#), in: ctx)
        XCTAssertTrue(read.output.contains("1 | alpha"), read.output)
        XCTAssertTrue(read.output.contains("2 | beta"), read.output)
        XCTAssertFalse(read.output.contains("\r"))

        let edited = await EditTool().execute(
            args: JSONString(#"{"file_path":"win.txt","old_string":"beta","new_string":"gamma"}"#), in: ctx)
        XCTAssertTrue(edited.output.hasPrefix("Edited"), edited.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha\r\ngamma\r\n")
    }

    func testEditKeepsABom() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bom.txt")
        var original = Data([0xEF, 0xBB, 0xBF])
        original.append(Data("hello\n".utf8))
        try original.write(to: url)

        let edited = await EditTool().execute(
            args: JSONString(#"{"file_path":"bom.txt","old_string":"hello","new_string":"hi"}"#), in: context(root))
        XCTAssertTrue(edited.output.hasPrefix("Edited"), edited.output)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: bytes.dropFirst(3), as: UTF8.self), "hi\n")
    }

    func testABinaryFileIsNotOverwrittenByAnEdit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin.dat")
        let original = Data([0x00, 0x01, 0x02])
        try original.write(to: url)

        let result = await EditTool().execute(
            args: JSONString(#"{"file_path":"bin.dat","old_string":"x","new_string":"y"}"#), in: context(root))
        XCTAssertTrue(result.output.contains("not a UTF-8"), result.output)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTheLocksDoNotGrowWithTheNumberOfFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = FileText.lock(for: root.appendingPathComponent("a.txt").path)
        let spelled = FileText.lock(for: root.appendingPathComponent("sub/../a.txt").path)
        XCTAssertTrue(a === spelled)
        var seen = Set<ObjectIdentifier>()
        for i in 0..<5_000 {
            seen.insert(ObjectIdentifier(FileText.lock(for: root.appendingPathComponent("f\(i).txt").path)))
        }
        XCTAssertGreaterThanOrEqual(seen.count, 2)
        XCTAssertLessThanOrEqual(seen.count, 64)
    }

    func testATempFileLeftByAWriteThatDiedIsReusedNotAccumulated() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: path)
        try Data("half a write".utf8).write(to: URL(fileURLWithPath: path.path + ".vision-tmp"))

        try FileText.write(to: path, text: "new text", format: .default)

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "new text")
        let leftovers = try files(in: root)
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasSuffix(".vision-tmp") })
    }

    /// Legacy: a build from before the rename named its temp file `*.dsh-tmp`; one it left goes with the next write.
    func testATempFileLeftByABuildFromBeforeTheRenameGoesWithTheNextWrite() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.txt")
        try Data("old".utf8).write(to: path)
        try Data("half a write".utf8).write(to: URL(fileURLWithPath: path.path + FileText.legacyTempSuffix))
        XCTAssertEqual(FileText.legacyTempSuffix, ".dsh-tmp")

        try FileText.write(to: path, text: "new text", format: .default)

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "new text")
        XCTAssertEqual(try files(in: root).map(\.lastPathComponent), ["a.txt"])
    }

    func testAWriteThatCannotBeFinishedLeavesNoTempFileBehind() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FileText.write(to: folder, text: "text", format: .default))
        let leftovers = try files(in: root)
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasSuffix(".vision-tmp") })
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testWriteKeepsAnExistingFilesLineEndings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("keep.txt")
        try Data("old\r\n".utf8).write(to: url)

        let wrote = await WriteFileTool().execute(
            args: JSONString(#"{"file_path":"keep.txt","content":"new\nline"}"#), in: context(root))
        XCTAssertTrue(wrote.output.hasPrefix("Wrote"), wrote.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\r\nline")
    }
}
