import Foundation
import CryptoKit

public protocol UsageProvider: Sendable {
    func fetch(includeTokens: Bool) async throws -> UsageSnapshot
}

public enum UsageError: LocalizedError, Equatable {
    case codexNotFound
    case signInRequired
    case unsupportedAccount
    case noLimits
    case timeout
    case disconnected
    case invalidResponse
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound: "Codex 실행 파일을 찾지 못했어요. Codex CLI를 설치하거나 COCOUNT_CODEX_PATH를 지정해 주세요."
        case .signInRequired: "Codex 로그인이 필요해요. 터미널에서 codex login을 실행한 뒤 새로고침해 주세요."
        case .unsupportedAccount: "ChatGPT 계정으로 Codex에 로그인해 주세요. API 키 계정에는 구독 한도가 없어요."
        case .noLimits: "이 계정에서 Codex 한도 정보를 받지 못했어요."
        case .timeout: "응답 시간이 초과됐어요. 연결 상태를 확인하고 다시 시도해 주세요."
        case .disconnected: "Codex 연결이 종료됐어요. 다시 새로고침해 주세요."
        case .invalidResponse: "Codex 응답을 읽지 못했어요. Codex CLI 버전을 확인해 주세요."
        case .server(let code): "사용량을 가져오지 못했어요 (\(code)). Codex 로그인과 연결 상태를 확인해 주세요."
        }
    }
}

public enum CodexExecutable {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let fm = FileManager.default
        if let override = environment["COCOUNT_CODEX_PATH"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else { throw UsageError.codexNotFound }
            return URL(fileURLWithPath: path)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        let candidates = pathCandidates + [
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw UsageError.codexNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

public struct AppServerUsageProvider: UsageProvider {
    private let executable: URL?
    public init(executable: URL? = nil) { self.executable = executable }

    public func fetch(includeTokens: Bool = true) async throws -> UsageSnapshot {
        let work = Task.detached(priority: .utility) {
            let session = try RPCSession(executable: executable ?? CodexExecutable.locate())
            defer { session.close() }
            try session.initialize()
            let account: AccountResponse = try session.request("account/read", params: ["refreshToken": false])
            guard let account = account.account else { throw UsageError.signInRequired }
            guard account.type == "chatgpt" || account.type == "chatgptAuthTokens" else {
                throw UsageError.unsupportedAccount
            }
            let response: RateLimitsResponse = try session.request("account/rateLimits/read")
            guard let limits = response.codex, !limits.windows.isEmpty else { throw UsageError.noLimits }
            var tokens: TokenUsage?
            var tokenIssue: String?
            if includeTokens {
                do { tokens = try session.request("account/usage/read") }
                catch { tokenIssue = "토큰 요약을 받지 못했어요. 한도 정보는 정상 갱신됐어요." }
            }
            let historyKey = account.email.map {
                // Separate local history by login, plan, and Codex configuration; never persist email.
                let identity = "\($0.lowercased())|\(limits.planType ?? "")|\(ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "default")"
                return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            return UsageSnapshot(limits: limits, tokens: tokens, fetchedAt: .now, tokenIssue: tokenIssue,
                                 resetCredits: response.rateLimitResetCredits, historyKey: historyKey,
                                 syncAccountKey: account.email.map {
                                     usageSyncDigest("cocount-sync-v1|\($0.lowercased())|\(limits.planType ?? "")")
                                 })
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

private struct AccountResponse: Decodable {
    struct Account: Decodable {
        let type: String
        let email: String?
    }
    let account: Account?
}
