//
//  ClaudeTaskProgress.swift
//  ThreadHelm
//
//  模块职责：Claude Code 任务进度读取——进程链活性检测、`claude agents`
//  快照解析、CLI 与 Claude Desktop 本地 Agent transcript 扫描、状态推断，
//  以及 Codex/Claude 双源进度的合并读取器。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct ClaudeAgentSnapshot: Equatable {
    let sessionID: String
    let title: String
    let workingDirectory: String
    let processID: Int32?
    let processStartIdentity: String?
    let kind: TaskProgressKind
    let startedAt: Date
    let statusOverride: String?
}

func claudeAgentRefreshInterval(agentCount: Int) -> TimeInterval {
    agentCount > 0 ? taskProgressRefreshInterval : 15
}

func shouldRefreshClaudeAgents(
    cachedAgentCount: Int,
    hasRecentlyModifiedTranscript: Bool
) -> Bool {
    cachedAgentCount > 0 || hasRecentlyModifiedTranscript
}

func claudeTaskProgressLaunchEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let standardPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")
    environment["PATH"] = "\(standardPath):\(environment["PATH"] ?? "")"
    environment["DISABLE_AUTOUPDATER"] = "1"
    return environment
}

func captureClaudeAgentsJSON(
    executableURL: URL,
    timeout: TimeInterval = 2,
    terminationGracePeriod: TimeInterval = 0.25
) -> Data? {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = executableURL
    process.arguments = ["agents", "--json"]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.environment = claudeTaskProgressLaunchEnvironment()
    do {
        try process.run()
    } catch {
        return nil
    }

    let capture = captureProcessOutput(
        process: process,
        output: stdout.fileHandleForReading,
        timeout: timeout,
        terminationGracePeriod: terminationGracePeriod,
        maximumOutputBytes: 1_048_576
    )
    guard capture.termination == .exited,
          process.terminationStatus == 0
    else {
        return nil
    }
    return capture.data
}

func isLiveProcess(_ processID: Int32) -> Bool {
    guard processID > 1 else { return false }
    if Darwin.kill(processID, 0) == 0 {
        return true
    }
    return errno == EPERM
}

func processStatusText(
    forProcessID processID: Int32,
    field: String
) -> String? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "\(field)="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    process.environment = environment
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )
    else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func currentProcessStartIdentity(
    forProcessID processID: Int32
) -> String? {
    processStatusText(forProcessID: processID, field: "lstart")
}

func processCommandLine(forProcessID processID: Int32) -> String? {
    processStatusText(forProcessID: processID, field: "command")
}

func isClaudeCodeCommandLine(_ value: String) -> Bool {
    let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }
    let executable = normalized
        .split(whereSeparator: \.isWhitespace)
        .first
        .map(String.init) ?? ""
    let executableName = URL(fileURLWithPath: executable).lastPathComponent
    return executableName == "claude"
        || executableName == "claude.exe"
        || executableName.hasPrefix("claude-")
        || normalized.contains("/@anthropic-ai/claude-code/")
}

func processChainContainsClaude(
    startingAt processID: Int32,
    commandLine: (Int32) -> String?,
    parentPID: (Int32) -> Int32?
) -> Bool {
    var candidate = processID
    var visited = Set<Int32>()
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let command = commandLine(candidate),
           isClaudeCodeCommandLine(command)
        {
            return true
        }
        guard let parent = parentPID(candidate) else { break }
        candidate = parent
    }
    return false
}

func isLiveClaudeProcess(_ processID: Int32) -> Bool {
    isLiveProcess(processID)
        && processChainContainsClaude(
            startingAt: processID,
            commandLine: { processCommandLine(forProcessID: $0) },
            parentPID: { parentProcessID(forProcessID: $0) }
        )
}

func claudeAgentActivityPriority(_ kind: TaskProgressKind) -> Int {
    switch kind {
    case .running:
        return 5
    case .waitingForInput:
        return 4
    case .reading:
        return 3
    case .completed:
        return 2
    case .failed:
        return 1
    case .idle:
        return 0
    }
}

func shouldPreferClaudeAgent(
    _ candidate: ClaudeAgentSnapshot,
    over existing: ClaudeAgentSnapshot
) -> Bool {
    let candidatePIDRank = candidate.processID == nil ? 0 : 1
    let existingPIDRank = existing.processID == nil ? 0 : 1
    if candidatePIDRank != existingPIDRank {
        return candidatePIDRank > existingPIDRank
    }

    let candidateActivity = claudeAgentActivityPriority(candidate.kind)
    let existingActivity = claudeAgentActivityPriority(existing.kind)
    if candidateActivity != existingActivity {
        return candidateActivity > existingActivity
    }
    if candidate.startedAt != existing.startedAt {
        return candidate.startedAt > existing.startedAt
    }
    if candidate.title != existing.title {
        return candidate.title < existing.title
    }
    if candidate.workingDirectory != existing.workingDirectory {
        return candidate.workingDirectory < existing.workingDirectory
    }
    if candidate.processID != existing.processID {
        return (candidate.processID ?? 0) < (existing.processID ?? 0)
    }
    let candidateStartIdentity = candidate.processStartIdentity ?? ""
    let existingStartIdentity = existing.processStartIdentity ?? ""
    if candidateStartIdentity != existingStartIdentity {
        return candidateStartIdentity < existingStartIdentity
    }
    let candidateStatus = candidate.statusOverride ?? ""
    let existingStatus = existing.statusOverride ?? ""
    if candidateStatus != existingStatus {
        return candidateStatus < existingStatus
    }
    return false
}

func claudeAgentsBySessionID(
    _ agents: [ClaudeAgentSnapshot],
    isProcessAlive: (Int32) -> Bool = isLiveClaudeProcess
) -> [String: ClaudeAgentSnapshot] {
    var result: [String: ClaudeAgentSnapshot] = [:]
    for agent in agents {
        let sessionID = agent.sessionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard UUID(uuidString: sessionID) != nil else { continue }
        let normalizedProcessStartIdentity = agent.processStartIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let liveProcessID = agent.processID.flatMap {
            $0 > 1
                && normalizedProcessStartIdentity?.isEmpty == false
                && isProcessAlive($0)
                ? $0
                : nil
        }
        let normalized = ClaudeAgentSnapshot(
            sessionID: sessionID,
            title: agent.title,
            workingDirectory: agent.workingDirectory,
            processID: liveProcessID,
            processStartIdentity: liveProcessID == nil
                ? nil
                : normalizedProcessStartIdentity,
            kind: agent.kind,
            startedAt: agent.startedAt,
            statusOverride: agent.statusOverride
        )
        guard let existing = result[sessionID] else {
            result[sessionID] = normalized
            continue
        }
        if shouldPreferClaudeAgent(
            normalized,
            over: existing
        ) {
            result[sessionID] = normalized
        }
    }
    return result
}

final class ClaudeTaskProgressReader {

    private struct TranscriptCandidate {
        let url: URL
        let modificationDate: Date
        let sessionID: String
        let allowsAgentOpen: Bool
    }

    private struct TranscriptRoot {
        let url: URL
        let allowsAgentOpen: Bool
    }

    private struct ColdScanRecord {
        let line: String
        let location: TranscriptRecordLocation
    }

    private struct ParsedCacheEntry {
        var modificationDate: Date
        var activeKind: TaskProgressKind?
        var activeTitle: String
        var activeProcessID: Int32?
        var activeProcessStartIdentity: String?
        var allowsAgentOpen: Bool
        var inferredActivityExpiresAt: Date?
        var item: TaskProgressItem?
        var reader: TranscriptEventReader?
        var reducer: ClaudeReducerState
        var descriptors: [TranscriptRecordLocation] = []
        var backscanContinuation: UInt64?
        var backscanBytes: Int = 0
        var snapshotEOF: UInt64 = 0
    }

    /// 增量 reducer 状态：只 apply 新 records，不保存原始历史行。
    /// events 限制为最近 32 条（AC-15）。
    struct ClaudeReducerState {
        var latestUserTitle: String?
        var detectedWorkingDirectory: String?
        var publicActivity = ""
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var activeToolSourceKeys: [String: String] = [:]
        var pendingUserInputCalls = Set<String>()
        var lastUpdatedAt: Date
        var lastStopReason: String?
        var lastMeaningfulRole: String?
        var failed = false
        var events: [TaskActivityEvent] = []
        var publicMessages: [AgentActivityEntry] = []
        var terminalSourceKey: String?

        init(modificationDate: Date) {
            lastUpdatedAt = modificationDate
        }

        @discardableResult
        mutating func apply(
            _ line: String,
            modificationDate: Date,
            location: TranscriptRecordLocation? = nil,
            sessionKey: String = ""
        ) -> TranscriptIndexedEventClass? {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let timestamp = ClaudeTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
            lastUpdatedAt = max(lastUpdatedAt, timestamp)
            if let cwd = record["cwd"] as? String, cwd.hasPrefix("/") {
                detectedWorkingDirectory = cwd
            }
            let type = (record["type"] as? String)?.lowercased()
            if type == "user",
               let message = record["message"] as? [String: Any] {
                if let content = message["content"] as? String,
                   let title = ClaudeTaskProgressReader.taskTitle(from: content) {
                    latestUserTitle = title
                    lastMeaningfulRole = "user"
                } else if let content = message["content"] as? [[String: Any]] {
                    var containsToolResult = false
                    for block in content {
                        let blockType = (block["type"] as? String)?.lowercased()
                        if blockType == "tool_result" {
                            containsToolResult = true
                            if let toolUseID = block["tool_use_id"] as? String {
                                activeTools.removeValue(forKey: toolUseID)
                                activeToolSourceKeys.removeValue(forKey: toolUseID)
                                pendingUserInputCalls.remove(toolUseID)
                            }
                        }
                    }
                    if !containsToolResult,
                       let title = ClaudeTaskProgressReader.taskTitle(from: content.compactMap({
                           ($0["type"] as? String) == "text" ? $0["text"] as? String : nil
                       }).joined(separator: " ")) {
                        latestUserTitle = title
                        lastMeaningfulRole = "user"
                    }
                    if containsToolResult { return .currentTool }
                }
                return .metadata
            }
            if type == "assistant",
               let message = record["message"] as? [String: Any] {
                lastMeaningfulRole = "assistant"
                lastStopReason = message["stop_reason"] as? String
                if message["error"] != nil || record["error"] != nil {
                    failed = true
                    terminalSourceKey = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "terminal"
                }
                guard let content = message["content"] as? [[String: Any]]
                else { return nil }
                var emittedClass: TranscriptIndexedEventClass?
                for block in content {
                    let blockType = (block["type"] as? String)?.lowercased()
                    if blockType == "text",
                       let text = block["text"] as? String,
                       let paragraph = safePublicActivityParagraph(from: text) {
                        publicActivity = ClaudeTaskProgressReader.budgetedPublicActivityText(
                            appendingTaskActivityParagraph(paragraph, to: publicActivity)
                        )
                        let sourceOrder = location?.sourceOrder
                            ?? UInt64(publicMessages.count)
                        let stableKey = location.map {
                            "bytes-\($0.startOffset)-\($0.byteCount)"
                        } ?? "commentary-\(publicMessages.count)"
                        publicMessages.append(AgentActivityEntry(
                            id: AgentActivityEventID(
                                source: .claudeCode,
                                sessionKey: sessionKey.lowercased(),
                                stableSourceKey: stableKey
                            ),
                            occurredAt: timestamp,
                            sourceOrder: sourceOrder,
                            text: paragraph
                        ))
                        trimPublicMessages()
                        events = appendingTaskActivityEvent(
                            TaskActivityEvent(kind: .commentary, occurredAt: timestamp, text: paragraph),
                            to: events
                        )
                        trimEvents()
                        emittedClass = .publicMessage
                    } else if blockType == "tool_use",
                              let name = block["name"] as? String {
                        let callID = block["id"] as? String ?? UUID().uuidString
                        if ClaudeTaskProgressReader.isUserInputTool(name) {
                            pendingUserInputCalls.insert(callID)
                            activeToolSourceKeys.removeValue(forKey: callID)
                            events = appendingTaskActivityEvent(
                                TaskActivityEvent(kind: .lifecycle, occurredAt: timestamp, text: "等待输入"),
                                to: events
                            )
                            trimEvents()
                            emittedClass = emittedClass ?? .metadata
                        } else {
                            let toolActivity = ClaudeTaskProgressReader.safeToolActivity(name: name)
                            activeTools[callID] = (toolActivity, timestamp)
                            activeToolSourceKeys[callID] = location.map {
                                "bytes-\($0.startOffset)-\($0.byteCount)"
                            } ?? "active-tool-\(callID)"
                            trimActiveTools()
                            events = appendingTaskActivityEvent(
                                TaskActivityEvent(kind: .tool, occurredAt: timestamp, text: toolActivity),
                                to: events
                            )
                            trimEvents()
                            emittedClass = emittedClass ?? .currentTool
                        }
                    }
                }
                if emittedClass == nil, lastStopReason == "end_turn" {
                    terminalSourceKey = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "terminal"
                    return .terminal
                }
                return emittedClass
            }
            if type == "system",
               let subtype = (record["subtype"] as? String)?.lowercased(),
               subtype.contains("error") {
                failed = true
                terminalSourceKey = location.map {
                    "bytes-\($0.startOffset)-\($0.byteCount)"
                } ?? "terminal"
                return .terminal
            }
            return nil
        }

        private mutating func trimActiveTools() {
            guard activeTools.count > 32 else { return }
            let sortedKeys = activeTools.sorted {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt < $1.value.updatedAt
                }
                return $0.key < $1.key
            }.map(\.key)
            for key in sortedKeys.prefix(activeTools.count - 32) {
                activeTools.removeValue(forKey: key)
                activeToolSourceKeys.removeValue(forKey: key)
            }
        }

        func buildItem(
            sessionID: String, fallbackTitle: String, workingDirectory: String,
            processID: Int32?, processStartIdentity: String?,
            activeKind: TaskProgressKind?, startedAt: Date,
            modificationDate: Date, now: Date,
            statusOverride: String?, allowsAgentOpen: Bool
        ) -> TaskProgressItem? {
            let kind: TaskProgressKind
            if failed {
                kind = .failed
            } else if !pendingUserInputCalls.isEmpty {
                kind = .waitingForInput
            } else if let activeKind {
                if activeKind == .waitingForInput,
                   lastStopReason == "end_turn",
                   lastMeaningfulRole == "assistant" {
                    kind = .completed
                } else {
                    kind = activeKind
                }
            } else if lastStopReason == "end_turn" {
                kind = .completed
            } else if (!activeTools.isEmpty || lastStopReason == "tool_use"),
                      now.timeIntervalSince(modificationDate) <= 30 {
                kind = .running
            } else {
                return nil
            }
            let activeTool = activeTools.values.max {
                $0.updatedAt < $1.updatedAt
            }?.text
            let activityText: String?
            if kind == .running {
                let sections = [activeTool, publicActivity.isEmpty ? nil : publicActivity].compactMap { $0 }
                activityText = sections.isEmpty ? "正在思考" : sections.joined(separator: " · ")
            } else {
                activityText = nil
            }
            let normalizedFallback = ClaudeTaskProgressReader.taskTitle(from: fallbackTitle)
            let title = normalizedFallback == "Claude 会话"
                ? (latestUserTitle ?? "Claude 会话")
                : (normalizedFallback ?? latestUserTitle ?? "Claude 会话")
            let cwd = workingDirectory.hasPrefix("/") ? workingDirectory : (detectedWorkingDirectory ?? "")
            let activeToolEntry = activeTools.max {
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt < $1.value.updatedAt }
                return $0.key < $1.key
            }.map { callID, entry in
                AgentActivityEntry(
                    id: AgentActivityEventID(source: .claudeCode, sessionKey: sessionID.lowercased(),
                        stableSourceKey: activeToolSourceKeys[callID]
                            ?? "active-tool-\(callID)"),
                    occurredAt: entry.updatedAt, sourceOrder: 0, text: entry.text
                )
            }
            let terminalEvent: AgentActivityEntry?
            if kind == .completed || kind == .failed {
                terminalEvent = events.last(where: { $0.kind == .lifecycle }).map {
                    AgentActivityEntry(
                        id: AgentActivityEventID(source: .claudeCode, sessionKey: sessionID.lowercased(),
                            stableSourceKey: terminalSourceKey ?? "terminal"),
                        occurredAt: $0.occurredAt, sourceOrder: 0, text: $0.text
                    )
                }
            } else { terminalEvent = nil }
            let projection = AgentActivityProjection(
                publicMessages: publicMessages,
                currentToolStatus: activeToolEntry,
                terminalEvent: terminalEvent
            )
            return TaskProgressItem(
                title: title, kind: kind, startedAt: startedAt, updatedAt: lastUpdatedAt,
                source: .claudeCode, activityText: activityText, statusOverride: statusOverride,
                sessionID: sessionID.lowercased(),
                workingDirectory: cwd.isEmpty ? nil : cwd,
                processID: processID, processStartIdentity: processStartIdentity,
                projection: projection, allowsAgentOpen: allowsAgentOpen
            )
        }

        private mutating func trimPublicMessages() {
            publicMessages.sort {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.sourceOrder > $1.sourceOrder
            }
            if publicMessages.count > AgentActivityBudget.maximumPublicMessages {
                publicMessages = Array(publicMessages.prefix(
                    AgentActivityBudget.maximumPublicMessages
                ))
            }
        }

        private mutating func trimEvents() {
            if events.count > 32 {
                events = Array(events.suffix(32))
            }
        }
    }

    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let indexRootDirectory: URL
    private let environment: [String: String]
    private let claudeExecutable: () -> URL?
    private let nowProvider: () -> Date
    private let transcriptRescanInterval: TimeInterval = 5
    private let completedTaskVisibility = completedTaskPanelRetention
    private var cachedCandidates: [TranscriptCandidate] = []
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var nextTranscriptScanAt = Date.distantPast
    private var cachedAgents: [ClaudeAgentSnapshot] = []
    private var nextAgentRefreshAt = Date.distantPast

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        indexRootDirectory: URL = TranscriptIndexStore.defaultRootDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        claudeExecutable: (() -> URL?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.indexRootDirectory = indexRootDirectory
        self.environment = environment
        self.claudeExecutable = claudeExecutable ?? {
            locateClaudeExecutable(
                environment: environment,
                homeDirectory: homeDirectory
            )
        }
        nowProvider = now
    }

    func readCollection() -> TaskProgressCollectionSnapshot {
        let now = nowProvider()
        let cachedActiveSessionIDs = Set(
            cachedAgents.map { $0.sessionID.lowercased() }
        )
        var candidates = recentTranscripts(
            now: now,
            activeSessionIDs: cachedActiveSessionIDs
        )
        let hasRecentlyModifiedTranscript = candidates.contains {
            now.timeIntervalSince($0.modificationDate) <= 30
        }
        let agentSnapshots = shouldRefreshClaudeAgents(
            cachedAgentCount: cachedAgents.count,
            hasRecentlyModifiedTranscript: hasRecentlyModifiedTranscript
        ) ? recentAgents(now: now) : cachedAgents
        let agentsBySessionID = claudeAgentsBySessionID(
            agentSnapshots
        )
        let agents = agentsBySessionID.values.sorted {
            $0.sessionID < $1.sessionID
        }
        let activeSessionIDs = Set(agentsBySessionID.keys)
        let locatedSessionIDs = Set(candidates.map(\.sessionID))
        if !activeSessionIDs.isSubset(of: locatedSessionIDs) {
            nextTranscriptScanAt = .distantPast
            candidates = recentTranscripts(
                now: now,
                activeSessionIDs: activeSessionIDs
            )
        }

        var items: [TaskProgressItem] = []
        var parsedSessionIDs = Set<String>()
        for candidate in candidates {
            let agent = agentsBySessionID[candidate.sessionID]
            if agent == nil,
               now.timeIntervalSince(candidate.modificationDate)
                    > completedTaskVisibility {
                continue
            }
            let cacheKey = candidate.url.path
            // mtime/size can remain unchanged across an atomic replace.  A
            // cache hit is valid only while the underlying transcript identity
            // still matches the reader that produced the projection.
            let candidateIdentity = TranscriptEventReader.make(
                at: candidate.url
            )?.identity
            let item: TaskProgressItem?
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate,
               cached.activeKind == agent?.kind,
               cached.activeTitle == (agent?.title ?? ""),
               cached.activeProcessID == agent?.processID,
               cached.activeProcessStartIdentity
                    == agent?.processStartIdentity,
               cached.allowsAgentOpen == candidate.allowsAgentOpen,
               cached.inferredActivityExpiresAt.map({ now <= $0 }) ?? true,
               let cachedReader = cached.reader,
               cachedReader.identity == candidateIdentity,
               cachedReader.scanHead
                    >= ((try? fileManager.attributesOfItem(
                        atPath: candidate.url.path
                    )[.size] as? NSNumber)?.uint64Value ?? 0),
               (cached.backscanContinuation == nil
                    || cached.backscanBytes >= TranscriptReadBudget
                        .transcriptEvents.maximumAutomaticBackscanBytes)
            {
                item = cached.item
            } else {
                // 增量 reducer：有持久 reader 时做前向 pass，只 apply 新
                // records 到持久 reducer 状态（不保存原始行，AC-15）。
                // 无则冷启动回扫后 apply 全部回扫记录。
                var reader: TranscriptEventReader?
                var reducer: ClaudeReducerState
                var descriptors: [TranscriptRecordLocation] = []
                var backscanCont: UInt64?
                var backscanBytes = 0
                var snapEOF: UInt64 = 0
                let sessionKey = candidate.sessionID
                let indexStore = TranscriptIndexStore(
                    rootDirectory: indexRootDirectory,
                    fileManager: fileManager
                )
                if let cached = parsedCache[cacheKey],
                   let cachedReader = cached.reader
                {
                    let bytesBeforeForward = cachedReader.diagnostics.bytesRead
                    let result = cachedReader.readForwardPass()
                    let forwardBytes = max(
                        0,
                        cachedReader.diagnostics.bytesRead - bytesBeforeForward
                    )
                    if case .success(let records) = result {
                        reducer = cached.reducer
                        // 链式保持：从持久 descriptors 种子继续。
                        descriptors = cached.descriptors
                        backscanCont = cached.backscanContinuation
                        backscanBytes = cached.backscanBytes
                        for record in records {
                            if let line = String(
                                data: record.data, encoding: .utf8
                            ) {
                                if let eventClass = reducer.apply(
                                    line,
                                    modificationDate: candidate.modificationDate,
                                    location: Self.descriptor(
                                        from: record,
                                        eventClass: .publicMessage
                                    ),
                                    sessionKey: sessionKey
                                ), eventClass == .publicMessage {
                                    descriptors.append(Self.descriptor(
                                        from: record,
                                        eventClass: eventClass
                                    ))
                                }
                            }
                        }
                        reader = cachedReader
                        descriptors = Array(descriptors.suffix(
                            TranscriptIndexStore.maximumPublicMessages
                        ))
                        snapEOF = cachedReader.scanHead
                        let remainingReadBudget = max(
                            0,
                            TranscriptReadBudget.transcriptEvents
                                .maximumBytesPerPass - forwardBytes
                        )
                        if let continuation = backscanCont,
                           backscanBytes < TranscriptReadBudget.transcriptEvents
                                .maximumAutomaticBackscanBytes,
                           remainingReadBudget > 0 {
                            let historical = coldScan(
                                reader: cachedReader,
                                url: candidate.url,
                                fromEnd: continuation,
                                maximumBytes: remainingReadBudget
                            )
                            for record in historical.lines {
                                if let line = Self.historicalColdRecordLineToApply(
                                    record.line
                                ) {
                                    reducer.apply(
                                        line,
                                        modificationDate: candidate.modificationDate,
                                        location: record.location,
                                        sessionKey: sessionKey
                                    )
                                }
                            }
                            descriptors = Array((historical.descriptors + descriptors)
                                .suffix(TranscriptIndexStore.maximumPublicMessages))
                            backscanCont = historical.backscanContinuation
                            backscanBytes += historical.scannedBytes
                        }
                    } else {
                        // identity 变化：冷启动。
                        guard let newReader = TranscriptEventReader.make(
                            at: candidate.url
                        ) else { continue }
                        reader = newReader
                        reducer = ClaudeReducerState(
                            modificationDate: candidate.modificationDate
                        )
                        let cold = coldScan(reader: newReader, url: candidate.url)
                        for record in cold.lines {
                            reducer.apply(
                                record.line,
                                modificationDate: candidate.modificationDate,
                                location: record.location,
                                sessionKey: sessionKey
                            )
                        }
                        descriptors = cold.descriptors
                        backscanCont = cold.backscanContinuation
                        backscanBytes = cold.scannedBytes
                        snapEOF = cold.snapshotEOF
                    }
                } else {
                    // 无缓存：先查 sidecar index（§4.2）。
                    let checkpoint = indexStore.load(
                        agentID: .claudeCode, sessionKey: sessionKey
                    )
                    let probeReader = TranscriptEventReader.make(
                        at: candidate.url
                    )
                    if let checkpoint = checkpoint,
                       let probeReader = probeReader,
                       checkpoint.sourceIdentity == probeReader.identity,
                       checkpoint.committedOffset <= probeReader.snapshotEOF
                    {
                        // Index-hit：从 checkpoint descriptors 种子重建，
                        // 避免第二次重启链被清空。
                        descriptors = checkpoint.publicMessageDescriptors
                        reducer = ClaudeReducerState(
                            modificationDate: candidate.modificationDate
                        )
                        var remainingReadBudget = TranscriptReadBudget
                            .transcriptEvents.maximumBytesPerPass
                        var restoredRecords: [(
                            descriptor: TranscriptRecordLocation,
                            line: String
                        )] = []
                        for descriptor in checkpoint.publicMessageDescriptors
                            .sorted(by: Self.newestDescriptorFirst)
                        {
                            let byteCount = Int(descriptor.byteCount)
                            guard byteCount <= remainingReadBudget else {
                                continue
                            }
                            let bytesBefore = probeReader.diagnostics.bytesRead
                            guard let data = probeReader.readRange(
                                descriptor,
                                maximumBytes: remainingReadBudget
                            ),
                                  let line = String(data: data, encoding: .utf8)
                            else { continue }
                            let bytesRead = max(
                                0,
                                probeReader.diagnostics.bytesRead - bytesBefore
                            )
                            guard bytesRead <= remainingReadBudget else { break }
                            remainingReadBudget -= bytesRead
                            restoredRecords.append((descriptor, line))
                        }
                        for restored in restoredRecords.sorted(by: {
                            Self.oldestDescriptorFirst(
                                $0.descriptor,
                                $1.descriptor
                            )
                        }) {
                            reducer.apply(
                                restored.line,
                                modificationDate: candidate.modificationDate,
                                location: restored.descriptor,
                                sessionKey: sessionKey
                            )
                        }
                        probeReader.setCommittedOffset(checkpoint.committedOffset)
                        // Index-hit 后从旧 committedOffset 做 forward-tail，
                        // 读取 checkpoint 到当前 EOF 之间的追加字节（§4.2）。
                        let bytesBeforeForward = probeReader.diagnostics.bytesRead
                        let forwardResult = probeReader.readForwardPass(
                            maximumBytes: remainingReadBudget
                        )
                        let forwardBytes = max(
                            0,
                            probeReader.diagnostics.bytesRead - bytesBeforeForward
                        )
                        if case .success(let forwardRecords) = forwardResult {
                            for record in forwardRecords {
                                if let line = String(
                                    data: record.data, encoding: .utf8
                                ),
                                   let eventClass = reducer.apply(
                                    line,
                                    modificationDate: candidate.modificationDate,
                                    location: Self.descriptor(
                                        from: record,
                                        eventClass: .publicMessage
                                    ),
                                    sessionKey: sessionKey
                                ),
                                eventClass == .publicMessage {
                                    descriptors.append(Self.descriptor(
                                        from: record,
                                        eventClass: eventClass
                                    ))
                                }
                            }
                        }
                        reader = probeReader
                        descriptors = Array(descriptors.suffix(
                            TranscriptIndexStore.maximumPublicMessages
                        ))
                        backscanCont = checkpoint.backscanContinuationOffset
                        backscanBytes = 0
                        snapEOF = probeReader.scanHead
                        remainingReadBudget = max(
                            0,
                            remainingReadBudget - forwardBytes
                        )
                        if let continuation = backscanCont,
                           backscanBytes < TranscriptReadBudget.transcriptEvents
                                .maximumAutomaticBackscanBytes,
                           remainingReadBudget > 0 {
                            let historical = coldScan(
                                reader: probeReader,
                                url: candidate.url,
                                fromEnd: continuation,
                                maximumBytes: remainingReadBudget
                            )
                            for record in historical.lines {
                                if let line = Self.historicalColdRecordLineToApply(
                                    record.line
                                ) {
                                    reducer.apply(
                                        line,
                                        modificationDate: candidate.modificationDate,
                                        location: record.location,
                                        sessionKey: sessionKey
                                    )
                                }
                            }
                            descriptors = Array((historical.descriptors + descriptors)
                                .suffix(TranscriptIndexStore.maximumPublicMessages))
                            backscanCont = historical.backscanContinuation
                            backscanBytes += historical.scannedBytes
                        }
                    } else {
                        guard let newReader = TranscriptEventReader.make(
                            at: candidate.url
                        ) else { continue }
                        reader = newReader
                        reducer = ClaudeReducerState(
                            modificationDate: candidate.modificationDate
                        )
                        let cold = coldScan(reader: newReader, url: candidate.url)
                        for record in cold.lines {
                            reducer.apply(
                                record.line,
                                modificationDate: candidate.modificationDate,
                                location: record.location,
                                sessionKey: sessionKey
                            )
                        }
                        descriptors = cold.descriptors
                        backscanCont = cold.backscanContinuation
                        backscanBytes = cold.scannedBytes
                        snapEOF = cold.snapshotEOF
                    }
                }
                item = reducer.buildItem(
                    sessionID: candidate.sessionID,
                    fallbackTitle: agent?.title ?? "Claude 会话",
                    workingDirectory: agent?.workingDirectory ?? "",
                    processID: agent?.processID,
                    processStartIdentity: agent?.processStartIdentity,
                    activeKind: agent?.kind,
                    startedAt: agent?.startedAt ?? candidate.modificationDate,
                    modificationDate: candidate.modificationDate,
                    now: now,
                    statusOverride: agent?.statusOverride,
                    allowsAgentOpen: candidate.allowsAgentOpen
                )
                let previousBackscanCont = parsedCache[cacheKey]?
                    .backscanContinuation
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    activeKind: agent?.kind,
                    activeTitle: agent?.title ?? "",
                    activeProcessID: agent?.processID,
                    activeProcessStartIdentity: agent?.processStartIdentity,
                    allowsAgentOpen: candidate.allowsAgentOpen,
                    inferredActivityExpiresAt:
                        agent == nil && item?.kind == .running
                            ? candidate.modificationDate.addingTimeInterval(30)
                            : nil,
                    item: item,
                    reader: reader,
                    reducer: reducer,
                    descriptors: descriptors,
                    backscanContinuation: backscanCont,
                    backscanBytes: backscanBytes,
                    snapshotEOF: snapEOF
                )
                // §4.2: 保存 checkpoint sidecar（metadata-only）。
                if let reader = reader {
                    let mtime = (try? fileManager.attributesOfItem(
                        atPath: candidate.url.path
                    )[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let cpDescriptors = Array(descriptors.suffix(
                        TranscriptIndexStore.maximumPublicMessages
                    ))
                    let checkpoint = TranscriptIndexStore.Checkpoint(
                        schemaVersion: TranscriptIndexStore.schemaVersion,
                        agentID: .claudeCode,
                        // `TranscriptIndexStore.save` replaces this placeholder
                        // with the deterministic SHA-256 digest before encoding.
                        sessionKeyDigest: "",
                        sourceIdentity: reader.identity,
                        observedSize: snapEOF,
                        observedMTime: UInt64(mtime),
                        committedOffset: reader.committedOffset,
                        backscanContinuationOffset: backscanCont,
                        publicMessageDescriptors: cpDescriptors,
                        currentToolDescriptor: nil,
                        terminalDescriptor: nil,
                        metadataDescriptor: nil,
                        oversizedRecords: 0
                    )
                    let terminal = item.map {
                        $0.kind == .completed || $0.kind == .failed
                    } ?? false
                    let continuationChanged = backscanCont
                        != previousBackscanCont
                    if terminal || continuationChanged {
                        try? indexStore.flush(
                            checkpoint,
                            agentID: .claudeCode,
                            sessionKey: sessionKey
                        )
                    } else {
                        try? indexStore.save(
                            checkpoint,
                            agentID: .claudeCode,
                            sessionKey: sessionKey
                        )
                    }
                }
            }
            if let item,
               taskIsWithinTerminalPanelRetention(
                   kind: item.kind,
                   updatedAt: item.updatedAt,
                   now: now,
                   retention: completedTaskVisibility
               )
            {
                items.append(item)
                parsedSessionIDs.insert(candidate.sessionID)
            }
        }

        for agent in agents where !parsedSessionIDs.contains(agent.sessionID) {
            let item = TaskProgressItem(
                title: agent.title,
                kind: agent.kind,
                startedAt: agent.startedAt,
                updatedAt: agent.startedAt,
                source: .claudeCode,
                activityText: agent.kind == .running ? "正在思考" : nil,
                statusOverride: agent.statusOverride,
                sessionID: agent.sessionID,
                workingDirectory: agent.workingDirectory,
                processID: agent.processID,
                processStartIdentity: agent.processStartIdentity
            )
            if taskIsWithinTerminalPanelRetention(
                kind: item.kind,
                updatedAt: item.updatedAt,
                now: now,
                retention: completedTaskVisibility
            ) {
                items.append(item)
            }
        }

        return .displaying(items)
    }

    func read() -> TaskProgressSnapshot {
        readCollection().compactProjection()
    }

    private func recentAgents(now: Date) -> [ClaudeAgentSnapshot] {
        if now < nextAgentRefreshAt {
            return cachedAgents
        }
        cachedAgents = readAgents()
        nextAgentRefreshAt = now.addingTimeInterval(
            claudeAgentRefreshInterval(agentCount: cachedAgents.count)
        )
        return cachedAgents
    }

    static func parseTranscript(
        lines: [String],
        sessionID: String,
        fallbackTitle: String,
        workingDirectory: String,
        processID: Int32? = nil,
        processStartIdentity: String? = nil,
        activeKind: TaskProgressKind?,
        startedAt: Date,
        modificationDate: Date,
        statusOverride: String? = nil,
        allowsAgentOpen: Bool = true,
        now: Date = Date()
    ) -> TaskProgressItem? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        var reducer = ClaudeReducerState(modificationDate: modificationDate)
        for line in lines {
            reducer.apply(
                line,
                modificationDate: modificationDate,
                sessionKey: sessionID
            )
        }
        return reducer.buildItem(
            sessionID: sessionID,
            fallbackTitle: fallbackTitle,
            workingDirectory: workingDirectory,
            processID: processID,
            processStartIdentity: processStartIdentity,
            activeKind: activeKind,
            startedAt: startedAt,
            modificationDate: modificationDate,
            now: now,
            statusOverride: statusOverride,
            allowsAgentOpen: allowsAgentOpen
        )
    }

    private func readAgents() -> [ClaudeAgentSnapshot] {
        guard let claudeURL = claudeExecutable(),
              let data = captureClaudeAgentsJSON(executableURL: claudeURL)
        else {
            return []
        }
        guard let values = try? JSONSerialization.jsonObject(with: data)
            as? [[String: Any]]
        else { return [] }

        let fallbackStartedMilliseconds = Date().timeIntervalSince1970 * 1_000
        return values.compactMap { value in
            guard let rawSessionID = value["sessionId"] as? String,
                  UUID(uuidString: rawSessionID) != nil,
                  rawSessionID.lowercased()
                    != ClaudeQuotaClient.probeSessionID.uuidString.lowercased(),
                  let cwd = value["cwd"] as? String,
                  cwd.hasPrefix("/"),
                  // 额度探测的 /usage 会以随机会话号出现，只能按工作目录排除，
                  // 否则它会冒充成一条用户任务显示在面板上。
                  cwd != ClaudeQuotaClient.probeWorkingDirectoryPath
            else { return nil }
            let rawStatus = (
                value["status"] as? String
                    ?? value["state"] as? String
                    ?? "busy"
            ).lowercased()
            let kind: TaskProgressKind
            let statusOverride: String?
            switch rawStatus {
            case "failed", "error", "crashed":
                kind = .failed
                statusOverride = nil
            case "completed", "complete", "done":
                kind = .completed
                statusOverride = nil
            case "blocked":
                kind = .waitingForInput
                statusOverride = "已阻塞"
            case "waiting", "idle":
                kind = .waitingForInput
                statusOverride = "等待中"
            default:
                kind = .running
                statusOverride = nil
            }
            let rawTitle = value["name"] as? String ?? "Claude 会话"
            let title = Self.taskTitle(from: rawTitle) ?? "Claude 会话"
            let rawProcessID = value["pid"] as? Int
                ?? (value["pid"] as? NSNumber)?.intValue
            let processID = rawProcessID.flatMap(Int32.init(exactly:))
                .flatMap { $0 > 1 ? $0 : nil }
            let processStartIdentity = processID.flatMap(
                currentProcessStartIdentity(forProcessID:)
            )
            let startedMilliseconds = value["startedAt"] as? Double
                ?? (value["startedAt"] as? NSNumber)?.doubleValue
                ?? fallbackStartedMilliseconds
            return ClaudeAgentSnapshot(
                sessionID: rawSessionID.lowercased(),
                title: title,
                workingDirectory: cwd,
                processID: processID,
                processStartIdentity: processStartIdentity,
                kind: kind,
                startedAt: Date(
                    timeIntervalSince1970: startedMilliseconds / 1_000
                ),
                statusOverride: statusOverride
            )
        }
    }

    private func recentTranscripts(
        now: Date,
        activeSessionIDs: Set<String>
    ) -> [TranscriptCandidate] {
        if now < nextTranscriptScanAt {
            return cachedCandidates.filter {
                activeSessionIDs.contains($0.sessionID)
                    || now.timeIntervalSince($0.modificationDate)
                        <= completedTaskVisibility
            }
        }
        nextTranscriptScanAt = now.addingTimeInterval(transcriptRescanInterval)
        var roots = [
            environment["CLAUDE_CONFIG_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("projects", isDirectory: true)
            },
            homeDirectory.appendingPathComponent(
                ".config/claude/projects",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(
                ".claude/projects",
                isDirectory: true
            ),
        ].compactMap { $0 }.map {
            TranscriptRoot(url: $0, allowsAgentOpen: true)
        }
        roots.append(contentsOf: claudeDesktopTranscriptRoots(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ).map {
            TranscriptRoot(url: $0, allowsAgentOpen: true)
        })

        var byPath: [String: TranscriptCandidate] = [:]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      !url.path.contains("/subagents/"),
                      let sessionID = Self.sessionID(from: url),
                      sessionID
                        != ClaudeQuotaClient.probeSessionID.uuidString.lowercased(),
                      // 同上：探测项目目录下的记录一律不算用户任务。
                      url.deletingLastPathComponent().lastPathComponent
                        != ClaudeQuotaClient.probeProjectDirectoryName,
                      let values = try? url.resourceValues(
                          forKeys: [
                              .contentModificationDateKey,
                              .isRegularFileKey,
                          ]
                      ),
                      values.isRegularFile == true,
                      let modificationDate = values.contentModificationDate,
                      activeSessionIDs.contains(sessionID)
                        || now.timeIntervalSince(modificationDate)
                            <= completedTaskVisibility
                else { continue }
                byPath[url.path] = TranscriptCandidate(
                    url: url,
                    modificationDate: modificationDate,
                    sessionID: sessionID,
                    allowsAgentOpen: root.allowsAgentOpen
                )
            }
        }
        cachedCandidates = byPath.values.sorted {
            $0.modificationDate > $1.modificationDate
        }
        let activePaths = Set(cachedCandidates.map(\.url.path))
        let indexStore = TranscriptIndexStore(
            rootDirectory: indexRootDirectory,
            fileManager: fileManager
        )
        for stalePath in parsedCache.keys where !activePaths.contains(stalePath) {
            let staleURL = URL(fileURLWithPath: stalePath)
            if let sessionID = Self.sessionID(from: staleURL) {
                indexStore.delete(agentID: .claudeCode, sessionKey: sessionID)
            }
        }
        let referencedSessionKeys = Set(cachedCandidates.map(\.sessionID))
        indexStore.purgeOrphans(
            agentID: .claudeCode,
            referencedSessionKeys: referencedSessionKeys,
            now: now
        )
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedCandidates
    }

    private struct ColdScanResult {
        let lines: [ColdScanRecord]
        let descriptors: [TranscriptRecordLocation]
        let backscanContinuation: UInt64?
        let snapshotEOF: UInt64
        /// 冷扫描后应持久化的前向 committedOffset：
        /// 触及文件尾且末尾未完成行时停在最后完整 LF 后（≤ fileSize）。
        let committedOffset: UInt64
        let scannedBytes: Int
    }

    private func coldScan(
        reader: TranscriptEventReader,
        url: URL,
        fromEnd requestedEndOffset: UInt64? = nil,
        maximumBytes: Int = TranscriptReadBudget.transcriptEvents
            .maximumBytesPerPass
    ) -> ColdScanResult {
        let fileSize = (try? fileManager.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        reader.setCommittedOffset(fileSize)
        let endOffset = requestedEndOffset ?? fileSize
        var lines: [ColdScanRecord] = []
        var descriptors: [TranscriptRecordLocation] = []
        var committedAfterScan = fileSize
        var nextContinuation: UInt64?
        var scannedBytes = 0
        if endOffset > 0, maximumBytes > 0 {
            let passBytes = min(
                maximumBytes,
                TranscriptReadBudget.transcriptEvents.maximumBytesPerPass
            )
            let bytesBefore = reader.diagnostics.bytesRead
            let result = reader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            scannedBytes = max(
                0,
                reader.diagnostics.bytesRead - bytesBefore
            )
            guard case .success(let (records, cont, trailingPartial)) = result
            else { return ColdScanResult(
                lines: [],
                descriptors: [],
                backscanContinuation: nil,
                snapshotEOF: fileSize,
                committedOffset: fileSize,
                scannedBytes: 0
            ) }
            if let trailingPartial, trailingPartial < committedAfterScan {
                committedAfterScan = trailingPartial
            }
            for record in records {
                if let line = String(data: record.data, encoding: .utf8) {
                    let location = Self.descriptor(
                        from: record,
                        eventClass: .publicMessage
                    )
                    lines.append(ColdScanRecord(
                        line: line,
                        location: location
                    ))
                    if Self.isPublicMessageRecord(line) {
                        descriptors.append(location)
                    }
                }
            }
            nextContinuation = cont
        }
        if committedAfterScan < fileSize {
            reader.setCommittedOffset(committedAfterScan)
        }
        return ColdScanResult(
            lines: lines,
            descriptors: descriptors,
            backscanContinuation: nextContinuation,
            snapshotEOF: fileSize,
            committedOffset: committedAfterScan,
            scannedBytes: scannedBytes
        )
    }

    private static func historicalColdRecordLineToApply(_ line: String) -> String? {
        if line.contains(#""type":"user""#) || line.contains(#""cwd""#) {
            return line
        }
        guard line.contains(#""type":"assistant""#),
              line.contains(#""type":"text""#),
              let data = line.data(using: .utf8),
              var record = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              var message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }
        let publicContent = content.filter {
            ($0["type"] as? String)?.lowercased() == "text"
        }
        guard !publicContent.isEmpty else { return nil }
        message["content"] = publicContent
        record["message"] = message
        guard let rewritten = try? JSONSerialization.data(
            withJSONObject: record,
            options: []
        ) else { return nil }
        return String(data: rewritten, encoding: .utf8)
    }

    private static func sessionID(from url: URL) -> String? {
        let value = url.deletingPathExtension().lastPathComponent.lowercased()
        return UUID(uuidString: value) == nil ? nil : value
    }

    private static func isUserInputTool(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("askuserquestion")
            || normalized.contains("request_user_input")
    }

    private static func safeToolActivity(name: String) -> String {
        let normalized = name.lowercased()
        if normalized.contains("bash") || normalized.contains("command") {
            return "正在运行命令"
        }
        if normalized.contains("edit")
            || normalized.contains("write")
            || normalized.contains("patch") {
            return "正在编辑文件"
        }
        if normalized.contains("read")
            || normalized.contains("grep")
            || normalized.contains("glob") {
            return "正在检查文件"
        }
        if normalized.contains("web") || normalized.contains("search") {
            return "正在搜索或检查网页"
        }
        return "正在使用工具"
    }

    private static func taskTitle(from rawText: String) -> String? {
        let text = rawText
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[`*_>#~-]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(80))
    }

    private static func descriptor(
        from record: TranscriptRecordRange,
        eventClass: TranscriptIndexedEventClass
    ) -> TranscriptRecordLocation {
        TranscriptRecordLocation(
            startOffset: record.startOffset,
            byteCount: UInt32(record.byteCount),
            sourceOrder: record.sourceOrder,
            eventClass: eventClass,
            occurredAt: nil
        )
    }

    private static func newestDescriptorFirst(
        _ lhs: TranscriptRecordLocation,
        _ rhs: TranscriptRecordLocation
    ) -> Bool {
        if lhs.startOffset != rhs.startOffset {
            return lhs.startOffset > rhs.startOffset
        }
        return lhs.byteCount > rhs.byteCount
    }

    private static func oldestDescriptorFirst(
        _ lhs: TranscriptRecordLocation,
        _ rhs: TranscriptRecordLocation
    ) -> Bool {
        if lhs.startOffset != rhs.startOffset {
            return lhs.startOffset < rhs.startOffset
        }
        return lhs.byteCount < rhs.byteCount
    }

    private static func budgetedPublicActivityText(_ text: String) -> String {
        safeUTF8Truncated(
            text,
            to: AgentActivityBudget.maximumPublicMessagesTotalBytes
        )
    }

    private static func isPublicMessageRecord(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (record["type"] as? String)?.lowercased() == "assistant",
              let message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else {
            return false
        }
        return content.contains { block in
            (block["type"] as? String)?.lowercased() == "text"
                && (block["text"] as? String).flatMap {
                    safePublicActivityParagraph(from: $0)
                } != nil
        }
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}

func claudeDesktopTranscriptRoots(
    homeDirectory: URL,
    fileManager: FileManager = .default
) -> [URL] {
    let sessionsDirectory = homeDirectory.appendingPathComponent(
        "Library/Application Support/Claude/local-agent-mode-sessions",
        isDirectory: true
    )
    var searchDirectories = [sessionsDirectory]
    var roots: [URL] = []
    for _ in 0..<3 {
        var nextDirectories: [URL] = []
        for directory in searchDirectories {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                else { continue }
                let name = child.lastPathComponent
                if name.hasPrefix("local_"),
                   UUID(uuidString: String(name.dropFirst("local_".count))) != nil
                {
                    let projects = child.appendingPathComponent(
                        ".claude/projects",
                        isDirectory: true
                    )
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(
                        atPath: projects.path,
                        isDirectory: &isDirectory
                    ), isDirectory.boolValue {
                        roots.append(projects)
                    }
                } else if name != "skills-plugin" {
                    nextDirectories.append(child)
                }
            }
        }
        searchDirectories = nextDirectories
    }
    return Dictionary(grouping: roots, by: \.path)
        .compactMap { $0.value.first }
        .sorted { $0.path < $1.path }
}

func combinedTaskProgressItems(
    codexItems: [TaskProgressItem],
    claudeItems: [TaskProgressItem],
    enabledAgentIDs: Set<AgentID>
) -> [TaskProgressItem] {
    (enabledAgentIDs.contains(.codex) ? codexItems : [])
        + (enabledAgentIDs.contains(.claudeCode) ? claudeItems : [])
}

final class CombinedTaskProgressReader {
    private let registry: AgentTaskProgressRegistry

    init(
        registry: AgentTaskProgressRegistry = AgentTaskProgressRegistry(
            sources: defaultAgentTaskProgressSources()
        )
    ) {
        self.registry = registry
    }

    func readCollection() -> TaskProgressCollectionSnapshot {
        registry.readCollection()
    }

    func read() -> TaskProgressSnapshot {
        readCollection().compactProjection()
    }
}
