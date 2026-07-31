//
//  QuotaClients.swift
//  ChatBirdQuotaPanel
//
//  模块职责：额度客户端与解析——Codex 快照选取与周窗口判定、额度失败
//  呈现文案、Claude 额度文本解析器，以及 Codex JSON-RPC stdio 客户端、
//  Codex 重置额度 HTTPS 客户端、Claude openpty 伪终端探针客户端。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func codexSnapshot(from response: RateLimitsResult) -> RateLimitSnapshot {
    if let snapshots = response.rateLimitsByLimitId {
        if let exactMatch = snapshots["codex"] {
            return exactMatch
        }
        if let idMatch = snapshots.values.first(where: { $0.limitId == "codex" }) {
            return idMatch
        }
    }
    return response.rateLimits
}

/// Codex currently exposes its weekly allowance as the only standard window,
/// while older builds exposed a short primary window plus a weekly secondary
/// window. Select by duration so the UI never falls back to the retired 5-hour
/// value when it encounters an older response shape.
func weeklyRateLimitWindow(from snapshot: RateLimitSnapshot) -> RateLimitWindow? {
    let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
    let minimumWeeklyDurationMins: Int64 = 6 * 24 * 60
    let explicitWeeklyWindows = windows.filter {
        ($0.windowDurationMins ?? 0) >= minimumWeeklyDurationMins
    }
    if let longestWeeklyWindow = explicitWeeklyWindows.max(by: {
        ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
    }) {
        return longestWeeklyWindow
    }

    // Duration-free windows cannot be proven to be weekly. Refuse them rather
    // than presenting a retired short allowance as a weekly percentage.
    return nil
}

enum QuotaClientError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case noResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 本机服务"
        case .launchFailed(let detail):
            return "无法启动 Codex 本机服务：\(detail)"
        case .noResponse:
            return "Codex 暂未返回额度数据"
        case .server(let detail):
            return detail
        }
    }
}

struct QuotaFailurePresentation: Equatable {
    let errorText: String?
    let statusText: String
}

func quotaFailurePresentation(
    for error: Error,
    hasExistingRows: Bool,
    provider: QuotaProvider = .codex
) -> QuotaFailurePresentation {
    let displayError: String
    var statusText = "1 分钟后自动重试"
    if provider == .claudeCode, let quotaError = error as? ClaudeQuotaError {
        switch quotaError {
        case .claudeNotFound:
            displayError = "未找到 Claude Code"
            statusText = "安装后自动显示"
        case .authenticationRequired:
            displayError = "请先登录 Claude Code"
            statusText = "登录后点击刷新"
        case .launchFailed:
            displayError = "Claude Code 启动失败"
        case .captureFailed:
            displayError = "Claude 额度读取失败"
        case .parseFailed:
            displayError = "无法识别 Claude 额度"
        }
    } else if let quotaError = error as? QuotaClientError {
        switch quotaError {
        case .codexNotFound:
            displayError = "未找到 Codex"
        case .launchFailed:
            displayError = "无法读取 Codex 额度"
        case .noResponse, .server:
            displayError = "额度服务暂不可用"
        }
    } else {
        displayError = "额度暂不可用"
    }
    return QuotaFailurePresentation(
        errorText: hasExistingRows ? nil : displayError,
        statusText: statusText
    )
}

enum ClaudeQuotaError: LocalizedError {
    case claudeNotFound
    case authenticationRequired
    case launchFailed
    case captureFailed
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "没有找到 Claude Code"
        case .authenticationRequired:
            return "Claude Code 尚未登录"
        case .launchFailed:
            return "无法启动 Claude Code"
        case .captureFailed:
            return "Claude Code 暂未返回额度"
        case .parseFailed:
            return "无法识别 Claude Code 额度"
        }
    }
}

struct ClaudeQuotaSnapshot: Equatable {
    let rows: [QuotaRow]
}

enum ClaudeQuotaParser {
    static func requiresAuthentication(_ rawText: String) -> Bool {
        let clean = stripTerminalControlSequences(rawText).lowercased()
        return [
            "not logged in",
            "not signed in",
            "please log in",
            "please login",
            "authentication required",
            "login required",
            "run /login",
        ].contains(where: clean.contains)
    }

    static func parse(_ rawText: String) throws -> ClaudeQuotaSnapshot {
        let clean = stripTerminalControlSequences(rawText)
        guard !clean.isEmpty else { throw ClaudeQuotaError.parseFailed }

        guard let session = quotaRow(
            labelPattern: #"current\s*session"#,
            name: "5 小时",
            in: clean
        ) else {
            throw ClaudeQuotaError.parseFailed
        }

        var rows = [session]
        if let weekly = quotaRow(
            labelPattern: #"current\s*week\s*\(\s*all\s*models\s*\)"#,
            name: "周额度",
            in: clean
        ) {
            rows.append(weekly)
        }
        if let fable = quotaRow(
            labelPattern: #"current\s*week\s*\(\s*fable\s*\)"#,
            name: "Fable",
            in: clean
        ) {
            rows.append(fable)
        }
        return ClaudeQuotaSnapshot(rows: rows)
    }

    static func stripTerminalControlSequences(_ text: String) -> String {
        var clean = text
        let patterns = [
            #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
            #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            #"\u001B[@-_]"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            clean = expression.stringByReplacingMatches(
                in: clean,
                range: NSRange(clean.startIndex..<clean.endIndex, in: clean),
                withTemplate: ""
            )
        }

        var output = ""
        for character in clean.replacingOccurrences(of: "\r", with: "\n") {
            if character == "\u{8}" {
                if !output.isEmpty { output.removeLast() }
            } else if character == "\n" || character == "\t"
                        || character.unicodeScalars.allSatisfy({
                            $0.value >= 0x20 && $0.value != 0x7F
                        }) {
                output.append(character)
            }
        }
        return output
    }

    private static func quotaRow(
        labelPattern: String,
        name: String,
        in text: String
    ) -> QuotaRow? {
        guard let labelRange = lastMatchRange(
            pattern: labelPattern,
            in: text
        ) else { return nil }

        let afterLabel = text[labelRange.upperBound...]
        let boundary = afterLabel.range(
            of: #"(?i)current\s*(?:session|week)"#,
            options: .regularExpression
        )?.lowerBound
        let sectionEnd = boundary ?? afterLabel.endIndex
        let section = String(afterLabel[..<sectionEnd].prefix(1_200))

        guard let percentage = percentage(from: section) else { return nil }
        let resetDescription = resetDescription(from: section)
        let resetsAt = resetDescription.flatMap { resetDate(from: $0) }
        return QuotaRow(
            name: name,
            remainingPercent: percentage,
            resetsAt: resetsAt,
            resetDescription: resetsAt == nil ? resetDescription : nil
        )
    }

    private static func lastMatchRange(
        pattern: String,
        in text: String
    ) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(
            in: text,
            range: searchRange
        ).last else { return nil }
        return Range(match.range, in: text)
    }

    private static func percentage(from text: String) -> Int? {
        let patterns = [
            #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(left|remaining|available|used)?"#,
            #"(left|remaining|available|used)\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range) else {
                continue
            }
            let valueGroup = index == 0 ? 1 : 2
            let qualifierGroup = index == 0 ? 2 : 1
            guard let valueRange = Range(match.range(at: valueGroup), in: text),
                  let value = Double(text[valueRange])
            else { continue }
            let qualifier = Range(match.range(at: qualifierGroup), in: text)
                .map { String(text[$0]).lowercased() } ?? ""
            let rounded = Int(value.rounded())
            let remaining = qualifier == "used" ? 100 - rounded : rounded
            return max(0, min(100, remaining))
        }
        return nil
    }

    private static func resetDescription(from text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"resets?\s*([^\n\r]+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        var value = String(text[valueRange])
            .replacingOccurrences(
                of: #"\s*\([^)]*\)\s*"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: " at ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if value.count > 36 {
            value = String(value.prefix(36))
        }
        return value.isEmpty ? nil : value
    }

    private static func resetDate(from rawValue: String, now: Date = Date()) -> Date? {
        let value = rawValue
            .lowercased()
            .replacingOccurrences(of: " at ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let expression = try? NSRegularExpression(
            pattern: #"^(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\s+([0-9]{1,2})\s+)?([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)$"#,
            options: [.caseInsensitive]
        )
        guard let expression,
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let hourRange = Range(match.range(at: 3), in: value),
              let meridiemRange = Range(match.range(at: 5), in: value),
              let rawHour = Int(value[hourRange])
        else { return nil }

        let minute = Range(match.range(at: 4), in: value)
            .flatMap { Int(value[$0]) } ?? 0
        guard (1...12).contains(rawHour), (0...59).contains(minute) else {
            return nil
        }
        let meridiem = String(value[meridiemRange]).lowercased()
        let hour = (rawHour % 12) + (meridiem == "pm" ? 12 : 0)
        let calendar = Calendar.current

        if let monthRange = Range(match.range(at: 1), in: value),
           let dayRange = Range(match.range(at: 2), in: value),
           let day = Int(value[dayRange])
        {
            let months = [
                "jan": 1, "feb": 2, "mar": 3, "apr": 4,
                "may": 5, "jun": 6, "jul": 7, "aug": 8,
                "sep": 9, "oct": 10, "nov": 11, "dec": 12,
            ]
            guard let month = months[String(value[monthRange]).lowercased()] else {
                return nil
            }
            let currentYear = calendar.component(.year, from: now)
            var components = DateComponents(
                year: currentYear,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
            guard var candidate = calendar.date(from: components) else { return nil }
            if candidate < now {
                components.year = currentYear + 1
                guard let nextYear = calendar.date(from: components) else { return nil }
                candidate = nextYear
            }
            return candidate
        }

        let startOfToday = calendar.startOfDay(for: now)
        guard var candidate = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: startOfToday
        ) else { return nil }
        if candidate <= now {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate)
            else { return nil }
            candidate = tomorrow
        }
        return candidate
    }
}

final class CodexQuotaClient {
    private let decoder = JSONDecoder()
    private let executableLocator: () -> URL?
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let maximumOutputBytes = 1_048_576

    init(
        executableLocator: @escaping () -> URL? = {
            locateCodexExecutable()
        },
        timeout: TimeInterval = 15,
        terminationGracePeriod: TimeInterval = 0.25
    ) {
        self.executableLocator = executableLocator
        self.timeout = max(0.01, timeout)
        self.terminationGracePeriod = max(0.01, terminationGracePeriod)
    }

    func fetch(completion: @escaping (Result<RateLimitsResult, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously() -> Result<RateLimitsResult, Error> {
        guard let codexURL = executableLocator() else {
            return .failure(QuotaClientError.codexNotFound)
        }

        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = codexURL
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return .failure(QuotaClientError.launchFailed(error.localizedDescription))
        }
        defer { try? stdin.fileHandleForWriting.close() }

        func writeLines(_ lines: [String]) -> Bool {
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else { return false }
            do {
                try stdin.fileHandleForWriting.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }

        guard writeLines([
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"chatbird-quota-panel\",\"version\":\"\(panelVersion)\"},\"capabilities\":{\"experimentalApi\":true}}}",
        ]) else {
            _ = stopProcess(process, gracePeriod: terminationGracePeriod)
            return .failure(QuotaClientError.noResponse)
        }

        var buffer = Data()
        var didSendReadRequest = false
        var finalResponse: RPCResponse?
        _ = captureProcessOutput(
            process: process,
            output: stdout.fileHandleForReading,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            maximumOutputBytes: maximumOutputBytes
        ) { chunk in
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int
                else { continue }

                if id == 1 && !didSendReadRequest {
                    didSendReadRequest = true
                    guard writeLines([
                        #"{"jsonrpc":"2.0","method":"initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#,
                    ]) else {
                        return false
                    }
                    continue
                }

                if id == 2 {
                    finalResponse = try? self.decoder.decode(
                        RPCResponse.self,
                        from: line
                    )
                    return false
                }
            }
            return true
        }

        if let result = finalResponse?.result {
            return .success(result)
        }
        if let error = finalResponse?.error {
            return .failure(QuotaClientError.server(error.message))
        }

        return .failure(QuotaClientError.noResponse)
    }
}

final class ClaudeQuotaClient {
    private static let timeout: TimeInterval = 24
    private static let maximumOutputBytes = 1_048_576
    static let probeSessionID =
        UUID(uuidString: "7ea8629d-a05f-4dc2-a0e1-b9cf8e81e407")!

    func fetch(completion: @escaping (Result<ClaudeQuotaSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.fetchSynchronously())
        }
    }

    private func fetchSynchronously() -> Result<ClaudeQuotaSnapshot, Error> {
        guard let claudeURL = locateClaudeExecutable() else {
            return .failure(ClaudeQuotaError.claudeNotFound)
        }
        do {
            let rawText = try captureUsage(from: claudeURL)
            if ClaudeQuotaParser.requiresAuthentication(rawText) {
                return .failure(ClaudeQuotaError.authenticationRequired)
            }
            return .success(try ClaudeQuotaParser.parse(rawText))
        } catch let error as ClaudeQuotaError {
            return .failure(error)
        } catch {
            return .failure(ClaudeQuotaError.captureFailed)
        }
    }

    private func captureUsage(from executableURL: URL) throws -> String {
        let workingDirectory = try prepareProbeWorkingDirectory()
        cleanupProbeTranscripts()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(
            ws_row: 50,
            ws_col: 160,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(
            &primaryFD,
            &secondaryFD,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw ClaudeQuotaError.launchFailed
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let secondaryHandle = FileHandle(
            fileDescriptor: secondaryFD,
            closeOnDealloc: true
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--allowed-tools",
            "",
            "--session-id",
            Self.probeSessionID.uuidString.lowercased(),
        ]
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        process.currentDirectoryURL = workingDirectory
        process.environment = launchEnvironment(workingDirectory: workingDirectory)

        do {
            try process.run()
        } catch {
            Darwin.close(primaryFD)
            try? secondaryHandle.close()
            throw ClaudeQuotaError.launchFailed
        }
        try? secondaryHandle.close()

        defer {
            _ = Self.write(Data("/exit\r".utf8), to: primaryFD)
            if process.isRunning {
                process.terminate()
            }
            let gracefulDeadline = Date().addingTimeInterval(0.8)
            while process.isRunning, Date() < gracefulDeadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            Darwin.close(primaryFD)
            cleanupProbeTranscripts()
        }

        var output = Data()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.timeout)
        var lastEnterAt = Date.distantPast
        var lastPromptResponseAt = Date.distantPast
        var usageSent = false
        var baseQuotaObservedAt: Date?
        var successObservedAt: Date?
        var respondedPrompts = Set<String>()
        let promptResponses: [(String, String)] = [
            ("doyoutrustthefilesinthisfolder", "y\r"),
            ("quicksafetycheck", "\r"),
            ("yesitrustthisfolder", "\r"),
            ("readytocodehere", "\r"),
            ("pressentertocontinue", "\r"),
            ("showplanusagelimits", "\r"),
            ("showplan", "\r"),
        ]

        while Date() < deadline {
            let chunk = Self.readAvailable(from: primaryFD)
            if !chunk.isEmpty {
                guard output.count + chunk.count <= Self.maximumOutputBytes else {
                    throw ClaudeQuotaError.captureFailed
                }
                output.append(chunk)

                if chunk.range(of: Data([0x1B, 0x5B, 0x36, 0x6E])) != nil {
                    _ = Self.write(Data("\u{1b}[1;1R".utf8), to: primaryFD)
                }

                let scanData = output.suffix(196_608)
                if let scanText = String(data: scanData, encoding: .utf8) {
                    let clean = ClaudeQuotaParser.stripTerminalControlSequences(scanText)
                    let normalized = Self.normalizedForPromptSearch(clean)
                    for (needle, response) in promptResponses
                        where normalized.contains(needle)
                            && !respondedPrompts.contains(needle)
                    {
                        _ = Self.write(Data(response.utf8), to: primaryFD)
                        respondedPrompts.insert(needle)
                        lastPromptResponseAt = Date()
                    }

                    if usageSent,
                       let rowCount = (try? ClaudeQuotaParser.parse(clean))?.rows.count {
                        if rowCount >= 2, baseQuotaObservedAt == nil {
                            baseQuotaObservedAt = Date()
                        }
                        if rowCount >= 3, successObservedAt == nil {
                            successObservedAt = Date()
                        }
                    }
                }
            }

            let now = Date()
            let readyAfterLaunch = now.timeIntervalSince(startedAt) >= 2
            let readyAfterPrompt = now.timeIntervalSince(lastPromptResponseAt) >= 0.8
            if !usageSent, readyAfterLaunch, readyAfterPrompt {
                guard Self.write(Data("/usage\r".utf8), to: primaryFD) else {
                    throw ClaudeQuotaError.captureFailed
                }
                usageSent = true
                lastEnterAt = now
            } else if usageSent, now.timeIntervalSince(lastEnterAt) >= 0.8 {
                let navigationKey = baseQuotaObservedAt == nil
                    ? "\r"
                    : "\u{1b}[B"
                _ = Self.write(Data(navigationKey.utf8), to: primaryFD)
                lastEnterAt = now
            }

            if let successObservedAt,
               now.timeIntervalSince(successObservedAt) >= 1.2 {
                break
            }
            if successObservedAt == nil,
               let baseQuotaObservedAt,
               now.timeIntervalSince(baseQuotaObservedAt) >= 3 {
                break
            }
            if !process.isRunning { break }
            usleep(60_000)
        }

        guard !output.isEmpty,
              let text = String(data: output, encoding: .utf8)
        else {
            throw ClaudeQuotaError.captureFailed
        }
        return text
    }

    private func prepareProbeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(
                "dev.chatbird.codex-quota-panel",
                isDirectory: true
            )
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        let settingsDirectory = directory
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let settingsURL = settingsDirectory
            .appendingPathComponent("settings.local.json")
        let data = try JSONSerialization.data(
            withJSONObject: ["disableDeepLinkRegistration": "disable"],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
        return directory
    }

    private func launchEnvironment(workingDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let standardPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = existingPath.isEmpty
            ? standardPath
            : "\(standardPath):\(existingPath)"
        environment["PWD"] = workingDirectory.path
        environment["TERM"] = "xterm-256color"
        environment["DISABLE_AUTOUPDATER"] = "1"
        for key in [
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CODEX_COMPANION_SESSION_ID",
            "CODEX_COMPANION_TRANSCRIPT_PATH",
            "CLAUDE_PLUGIN_DATA",
        ] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private func cleanupProbeTranscripts() {
        let fileName = "\(Self.probeSessionID.uuidString.lowercased()).jsonl"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(
                ".config/claude/projects",
                isDirectory: true
            ),
        ]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator
                where url.lastPathComponent == fileName
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func normalizedForPromptSearch(_ text: String) -> String {
        String(text.lowercased().filter {
            $0.isLetter || $0.isNumber || $0 == "%"
        })
    }

    private static func readAvailable(from fileDescriptor: Int32) -> Data {
        var result = Data()
        while true {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                result.append(contentsOf: bytes.prefix(count))
                continue
            }
            break
        }
        return result
    }

    @discardableResult
    private static func write(_ data: Data, to fileDescriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let address = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    fileDescriptor,
                    address.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10_000)
                continue
            }
            return false
        }
        return true
    }
}
