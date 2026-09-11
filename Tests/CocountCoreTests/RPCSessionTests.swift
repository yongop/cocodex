import Foundation

struct RPCSessionTests {
    private struct Value: Decodable { let value: Int }

    private func withServer<T>(_ script: String, body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fake-codex")
        try ("#!/bin/bash\n" + script).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return try body(file)
    }

    func fragmentedResponseAndNotification() throws {
        try withServer("""
        IFS= read -r request
        printf '%s\\n' '{"method":"account/updated","params":{}}'
        printf '%s' '{"id":1,"result":'
        printf '%s\\n' '{"value":42}}'
        IFS= read -r end
        """) { executable in
            let session = try RPCSession(executable: executable)
            defer { session.close() }
            let value: Value = try session.request("test")
            try expect(value.value == 42)
        }
    }

    func serverErrorIsSanitized() throws {
        try withServer("""
        IFS= read -r request
        printf '%s\\n' '{"id":1,"error":{"code":401,"message":"sensitive server diagnostic"}}'
        IFS= read -r end
        """) { executable in
            let session = try RPCSession(executable: executable)
            defer { session.close() }
            try expectThrows( UsageError.server(401)) {
                let _: Value = try session.request("test")
            }
        }
    }

    func unresponsiveProcessTimesOut() throws {
        try withServer("while IFS= read -r request; do :; done\n") { executable in
            let session = try RPCSession(executable: executable, timeout: 0.2)
            defer { session.close() }
            try expectThrows( UsageError.timeout) {
                let _: Value = try session.request("test")
            }
        }
    }

    func unexpectedEOFIsHandled() throws {
        try withServer("IFS= read -r request\nexit 0\n") { executable in
            let session = try RPCSession(executable: executable)
            defer { session.close() }
            try expectThrows( UsageError.disconnected) {
                let _: Value = try session.request("test")
            }
        }
    }

    func initializationAndReadOnlyRejection() throws {
        try withServer("""
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r request
        printf '%s\\n' '{"id":99,"method":"attestation/generate","params":{}}'
        IFS= read -r refusal
        case "$refusal" in
          *'Read-only client'*) printf '%s\\n' '{"id":2,"result":{"value":7}}' ;;
          *) exit 1 ;;
        esac
        IFS= read -r end
        """) { executable in
            let session = try RPCSession(executable: executable)
            defer { session.close() }
            try session.initialize()
            let value: Value = try session.request("test")
            try expect(value.value == 7)
        }
    }
}
