import Darwin
import Foundation

/// A short-lived, serial JSON-RPC connection. Used only on the provider's utility task.
/// No model requests, auth-file parsing, shell execution, or background daemon.
final class RPCSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let deadline: TimeInterval
    private var closed = false
    private var started = false

    init(executable: URL, timeout: TimeInterval = 20) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        // Discard server diagnostics: these may contain account or local configuration data.
        process.standardError = FileHandle.nullDevice
        try process.run()
        started = true
        // A broken child pipe should report an error, never terminate the menu app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    func initialize() throws {
        let _: EmptyResult = try request("initialize", params: [
            "clientInfo": ["name": "cocount", "title": "Co-Count", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true],
        ])
        try send(["method": "initialized", "params": [:]])
    }

    func request<T: Decodable>(_ method: String, params: [String: Any] = [:]) throws -> T {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        while true {
            try Task.checkCancellation()
            let line = try readLine()
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageError.invalidResponse
            }
            // Ignore notifications, but explicitly refuse unexpected server-initiated requests.
            if message["method"] != nil {
                if let serverID = message["id"] {
                    try send(["id": serverID, "error": ["code": -32601, "message": "Read-only client"]])
                }
                continue
            }
            guard (message["id"] as? Int) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw UsageError.server(error["code"] as? Int ?? -1)
            }
            guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
                throw UsageError.invalidResponse
            }
            do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result)) }
            catch { throw UsageError.invalidResponse }
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw UsageError.disconnected }
    }

    private func readLine() throws -> Data {
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageError.timeout }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            guard buffer.count < 4 * 1_024 * 1_024 else { throw UsageError.invalidResponse }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw UsageError.disconnected
            }
            guard result > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.disconnected }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        guard started else { return }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    deinit { close() }
}

private struct EmptyResult: Decodable {}
