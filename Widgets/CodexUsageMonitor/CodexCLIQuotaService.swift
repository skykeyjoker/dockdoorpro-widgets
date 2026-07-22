import Foundation

/// Reads Codex quota windows from the local Codex CLI app-server.
/// The protocol and field compatibility follow CodexBar's MIT-licensed implementation.
struct CodexCLIQuotaService {
    enum CLIError: LocalizedError {
        case notInstalled
        case startFailed(String)
        case timeout(String)
        case requestFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return CodexLocalization.text(
                    "未找到 Codex CLI，请先安装 Codex，或将额度来源改为 OAuth API。",
                    "Codex CLI was not found. Install Codex or switch the quota source to OAuth API."
                )
            case let .startFailed(message):
                return CodexLocalization.text(
                    "无法启动 Codex CLI：\(message)",
                    "Unable to start Codex CLI: \(message)"
                )
            case let .timeout(method):
                return CodexLocalization.text(
                    "Codex CLI 请求超时（\(method)）。",
                    "Codex CLI request timed out (\(method))."
                )
            case let .requestFailed(message):
                return CodexLocalization.text(
                    "Codex CLI 请求失败：\(message)",
                    "Codex CLI request failed: \(message)"
                )
            case .invalidResponse:
                return CodexLocalization.text(
                    "Codex CLI 返回了无法识别的额度数据。",
                    "Codex CLI returned unrecognized quota data."
                )
            }
        }
    }

    private struct AccountResponse: Decodable {
        let account: Account?
    }

    private enum Account: Decodable {
        case apiKey
        case chatgpt(email: String?, planType: String?)

        private enum CodingKeys: String, CodingKey {
            case type, email, planType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type).lowercased() {
            case "apikey":
                self = .apiKey
            case "chatgpt":
                self = .chatgpt(
                    email: try container.decodeIfPresent(String.self, forKey: .email),
                    planType: try container.decodeIfPresent(String.self, forKey: .planType)
                )
            default:
                self = .apiKey
            }
        }
    }

    private struct RateLimitsResponse: Decodable {
        let rateLimits: RateLimitSnapshot
        let rateLimitsByLimitId: [String: RateLimitSnapshot]?

        private enum CodingKeys: String, CodingKey {
            case rateLimits
            case rateLimitsByLimitId
            case rateLimitsByLimitIdSnake = "rate_limits_by_limit_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rateLimits = try container.decode(RateLimitSnapshot.self, forKey: .rateLimits)
            rateLimitsByLimitId = (try? container.decodeIfPresent(
                [String: RateLimitSnapshot].self,
                forKey: .rateLimitsByLimitId
            )) ?? (try? container.decodeIfPresent(
                [String: RateLimitSnapshot].self,
                forKey: .rateLimitsByLimitIdSnake
            ))
        }
    }

    private struct RateLimitSnapshot: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let credits: Credits?
        let planType: String?

        private enum CodingKeys: String, CodingKey {
            case limitId
            case limitIdSnake = "limit_id"
            case limitName
            case limitNameSnake = "limit_name"
            case primary, secondary, credits, planType
            case planTypeSnake = "plan_type"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitId = (try? container.decodeIfPresent(String.self, forKey: .limitId))
                ?? (try? container.decodeIfPresent(String.self, forKey: .limitIdSnake))
            limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName))
                ?? (try? container.decodeIfPresent(String.self, forKey: .limitNameSnake))
            primary = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .primary)
            secondary = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)
            credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
            planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
                ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
        }
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    private struct Credits: Decodable {
        let balance: String?
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        let rpc = try CodexQuotaRPCClient()
        defer { rpc.shutdown() }

        try await rpc.initialize()
        let limits: RateLimitsResponse = try await rpc.requestDecoded(method: "account/rateLimits/read")
        let account: AccountResponse? = try? await rpc.requestDecoded(method: "account/read")
        return try makeSnapshot(limits: limits, account: account)
    }

    private func makeSnapshot(
        limits response: RateLimitsResponse,
        account responseAccount: AccountResponse?
    ) throws -> CodexUsageSnapshot {
        let limits = response.rateLimits
        let mainWindows = [
            makeWindow(
                limits.primary,
                id: "session",
                title: CodexLocalization.text("短周期", "Session")
            ),
            makeWindow(
                limits.secondary,
                id: "weekly",
                title: CodexLocalization.text("每周", "Weekly")
            ),
        ].compactMap { $0 }

        guard !mainWindows.isEmpty || limits.credits?.balance != nil else {
            throw CLIError.invalidResponse
        }

        let weekly = mainWindows
            .filter { $0.durationSeconds >= 2 * 24 * 60 * 60 }
            .max { $0.durationSeconds < $1.durationSeconds }
        let session = mainWindows
            .filter { $0.durationSeconds < 2 * 24 * 60 * 60 }
            .min { $0.durationSeconds < $1.durationSeconds }

        let extras = (response.rateLimitsByLimitId ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { key, value -> CodexQuotaWindow? in
                guard value.limitId != limits.limitId else { return nil }
                return makeWindow(
                    value.secondary ?? value.primary,
                    id: "extra-\(value.limitId ?? key)",
                    title: value.limitName ?? value.limitId ?? key
                )
            }

        let identity: (email: String?, plan: String?) = {
            guard case let .chatgpt(email, plan)? = responseAccount?.account else {
                return (nil, nil)
            }
            return (email, plan)
        }()

        return CodexUsageSnapshot(
            accountEmail: identity.email,
            plan: identity.plan ?? limits.planType,
            sessionWindow: session,
            weeklyWindow: weekly ?? mainWindows.max { $0.durationSeconds < $1.durationSeconds },
            extraWindows: extras,
            creditsBalance: limits.credits?.balance.flatMap(Double.init),
            resetCreditsAvailable: nil,
            resetCreditsExpiresAt: nil,
            fetchedAt: Date()
        )
    }

    private func makeWindow(
        _ window: RateLimitWindow?,
        id: String,
        title: String
    ) -> CodexQuotaWindow? {
        guard let window,
              let minutes = window.windowDurationMins,
              minutes > 0
        else { return nil }
        return CodexQuotaWindow(
            id: id,
            title: title,
            usedPercent: max(0, min(100, window.usedPercent)),
            resetAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationSeconds: minutes * 60
        )
    }
}

private final class CodexQuotaRPCClient: @unchecked Sendable {
    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lines: AsyncStream<Data>
    private let lineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1

    init() throws {
        var continuation: AsyncStream<Data>.Continuation!
        lines = AsyncStream<Data> { continuation = $0 }
        lineContinuation = continuation

        guard let executable = Self.resolveExecutable() else {
            throw CodexCLIQuotaService.CLIError.notInstalled
        }

        var environment = ProcessInfo.processInfo.environment
        let supportPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (supportPaths + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexCLIQuotaService.CLIError.startFailed(error.localizedDescription)
        }

        let lineBuffer = CodexRPCLineBuffer()
        let streamContinuation = lineContinuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                streamContinuation.finish()
                return
            }
            guard let drained = lineBuffer.appendAndDrain(data) else {
                handle.readabilityHandler = nil
                process?.terminate()
                streamContinuation.finish()
                return
            }
            drained.forEach { streamContinuation.yield($0) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "dockdoor-codex-usage", "version": "1.0"]],
            timeout: 8
        )
        try sendPayload(["method": "initialized", "params": [:]])
    }

    func requestDecoded<T: Decodable>(method: String) async throws -> T {
        let message = try await request(method: method, timeout: 3)
        guard let result = message["result"] else {
            throw CodexCLIQuotaService.CLIError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CodexCLIQuotaService.CLIError.invalidResponse
        }
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        lineContinuation.finish()
        if process.isRunning { process.terminate() }
    }

    private func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try sendPayload(["id": id, "method": method, "params": params])

        let message = try await withThrowingTaskGroup(of: SendableMessage.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CodexCLIQuotaService.CLIError.invalidResponse }
                while true {
                    let value = try await self.readNextMessage()
                    if value["id"] == nil { continue }
                    guard self.integerID(value["id"]) == id else { continue }
                    if let error = value["error"] as? [String: Any] {
                        let text = error["message"] as? String
                            ?? CodexLocalization.text("未知错误", "Unknown error")
                        throw CodexCLIQuotaService.CLIError.requestFailed(text)
                    }
                    return SendableMessage(value: value)
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.terminateForTimeout()
                throw CodexCLIQuotaService.CLIError.timeout(method)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CodexCLIQuotaService.CLIError.timeout(method)
            }
            return first
        }
        return message.value
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        } catch {
            throw CodexCLIQuotaService.CLIError.requestFailed(error.localizedDescription)
        }
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in lines {
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            return json
        }
        throw CodexCLIQuotaService.CLIError.invalidResponse
    }

    private func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func terminateForTimeout() {
        if process.isRunning { process.terminate() }
        lineContinuation.finish()
    }

    private static func resolveExecutable() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_CLI_PATH", "CODEX_BIN"] {
            if let path = environment[key], FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".npm-global/bin/codex").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private final class CodexRPCLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maximumBytes = 1_048_576

    func appendAndDrain(_ data: Data) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= maximumBytes else { return nil }

        var output: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            output.append(line)
        }
        return output
    }
}
