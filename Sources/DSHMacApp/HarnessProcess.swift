import Foundation

/// Supervises a `dsh web` child process.
///
/// The app can either attach to a harness the user already runs, or start one
/// itself. A started harness is bound to the app's lifetime: `stop()` runs on
/// termination so quitting never strands a listening server.
@MainActor
final class HarnessProcess {
    enum State: Equatable {
        case idle
        case starting
        case running(pid: Int32, url: URL)
        case exited(code: Int32)
    }

    private(set) var state: State = .idle
    private var process: Process?
    private(set) var log: [String] = []

    enum Failure: Error, LocalizedError {
        case noEntrypoint(String)
        case didNotListen(String)

        var errorDescription: String? {
            switch self {
            case .noEntrypoint(let path):
                return "No harness entrypoint at \(path). Build it with `pnpm run build`, or point the app at a running server instead."
            case .didNotListen(let tail):
                return "The harness started but never listened.\n\(tail)"
            }
        }
    }

    /// Launch `dsh web` from a repository checkout and wait for it to listen.
    func start(repoPath: String, port: Int) async throws -> URL {
        stop()
        state = .starting
        log = []

        let bin = URL(fileURLWithPath: repoPath).appendingPathComponent("apps/cli/lib/bin.js")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            state = .idle
            throw Failure.noEntrypoint(bin.path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", bin.path, "web", "--port", String(port)]
        proc.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Drain continuously; a filled pipe buffer would otherwise stall the child.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.log.append(line)
                if self?.log.count ?? 0 > 400 { self?.log.removeFirst(200) }
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.state = .exited(code: p.terminationStatus)
                self?.process = nil
            }
        }

        try proc.run()
        process = proc

        let url = URL(string: "http://127.0.0.1:\(port)")!
        // Poll the carrier rather than scraping stdout: listening is the fact
        // that matters, and the URL line belongs to the shell, not the server.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !proc.isRunning { break }
            if await Self.isListening(url) {
                state = .running(pid: proc.processIdentifier, url: url)
                return url
            }
        }
        let tail = log.suffix(6).joined()
        stop()
        throw Failure.didNotListen(tail)
    }

    func stop() {
        guard let proc = process, proc.isRunning else { process = nil; return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        proc.terminate()
        process = nil
        state = .idle
    }

    private static func isListening(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse) != nil
    }
}
