//
//  CodexTaskProgress.swift
//  ThreadHelm
//
//  模块职责：扫描 Codex sessions 目录的 rollout jsonl，解析任务生命周期
//  事件（开始/完成/失败/等待输入/工具调用），结合标题索引与未读状态
//  产出 Codex 任务进度快照。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class CodexTaskProgressReader {
    struct UnreadThreadState {
        let ids: Set<String>
        let explicitlyVisibleIDs: Set<String>
        let isAvailable: Bool

        init(
            ids: Set<String>,
            explicitlyVisibleIDs: Set<String> = [],
            isAvailable: Bool
        ) {
            self.ids = ids
            self.explicitlyVisibleIDs = explicitlyVisibleIDs
            self.isAvailable = isAvailable
        }

        /// 未读集合里最新的 thread。thread id 是 UUIDv7，前 48 bit 是毫秒
        /// 时间戳，因此字典序即时间序。
        var newestKnownThreadID: String? {
            ids.max()
        }

        /// 未读信号是否覆盖到这个会话。Codex 在某个版本后不再往
        /// `unread-thread-ids-by-host-v1` 写新会话，集合就此定格；此后创建
        /// 的会话既不在集合里、也从未被它记录过，用「不在集合里」推断
        /// 「已读」会把它们全部误判掉，已完成的任务再也不会出现。
        func covers(threadID: String) -> Bool {
            guard isAvailable else { return false }
            guard let newest = newestKnownThreadID else {
                // 空集合有歧义：可能是全部已读，也可能是信号从未记录。
                // 无从分辨时保持原语义——不在集合里即视为已读。
                return true
            }
            return threadID.lowercased() <= newest
        }
    }

    private struct RolloutCandidate {
        let url: URL
        let modificationDate: Date
    }

    private struct ParsedCacheEntry {
        let modificationDate: Date
        let snapshot: TaskProgressSnapshot
        var reader: TranscriptEventReader?
        var reducer: CodexReducerState
        var descriptors: [TranscriptRecordLocation] = []
        var backscanContinuation: UInt64?
        var backscanBytes: Int = 0
        var snapshotEOF: UInt64 = 0
    }

    /// 增量 reducer 状态：只 apply 新 records，不保存原始历史行。
    /// events 限制为最近 32 条（AC-15）。
    struct CodexReducerState {
        var lifecycle: TaskProgressKind?
        var pendingUserInputCalls = Set<String>()
        var activeTools: [String: (text: String, updatedAt: Date)] = [:]
        var activeToolSourceKeys: [String: String] = [:]
        var latestUserTitle: String?
        var activeTaskTitle: String?
        var publicCommentaryText = ""
        var latestPublicCommentary: String?
        var workingDirectory: String?
        var events: [TaskActivityEvent] = []
        var publicMessages: [AgentActivityEntry] = []
        var terminalSourceKey: String?
        var taskStartedAt: Date
        var lastUpdatedAt: Date

        init(modificationDate: Date) {
            taskStartedAt = modificationDate
            lastUpdatedAt = modificationDate
        }

        @discardableResult
        mutating func apply(
            _ line: String,
            location: TranscriptRecordLocation? = nil,
            sessionKey: String = ""
        ) -> TranscriptIndexedEventClass? {
            guard line.contains("task_started")
                || line.contains("task_complete")
                || line.contains("task_failed")
                || line.contains("turn_aborted")
                || line.contains(#""type":"error""#)
                || line.contains("user_message")
                || line.contains("agent_message")
                || line.contains("request_user_input")
                || line.contains("function_call")
                || line.contains("custom_tool_call")
                || line.contains("function_call_output")
                || line.contains("custom_tool_call_output")
                || line.contains("session_meta")
                // Codex 0.147 起改用 item_completed 承载消息与工具；只放行
                // 需要的 item 类型，thinking 与压缩记录仍不进解析。
                || line.contains(#""AgentMessage""#)
                || line.contains(#""UserMessage""#)
                || line.contains(#""CommandExecution""#)
                || line.contains(#""McpToolCall""#)
            else { return nil }
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var payload = record["payload"] as? [String: Any]
            else { return nil }
            // 新格式归一化回既有 payload 语义：下游分支与 81 条真值夹具都
            // 保持原样，旧 rollout 仍走原路径。
            if record["type"] as? String == "event_msg",
               payload["type"] as? String == "item_completed" {
                guard let mapped = CodexTaskProgressReader
                    .normalizedCompletedItemPayload(payload)
                else { return nil }
                payload = mapped
            }
            if record["type"] as? String == "session_meta",
               let rawCwd = payload["cwd"] as? String,
               let cwd = normalizedAbsolutePath(rawCwd) {
                workingDirectory = cwd
                return .metadata
            }
            guard let payloadType = payload["type"] as? String else { return nil }
            if record["type"] as? String == "event_msg" {
                let eventDate = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                if payloadType == "user_message",
                   let message = payload["message"] as? String,
                   let title = CodexTaskProgressReader.taskTitle(from: message) {
                    latestUserTitle = title
                    return .metadata
                } else if payloadType == "task_started" {
                    lifecycle = .running
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    activeToolSourceKeys.removeAll()
                    publicCommentaryText = ""
                    latestPublicCommentary = nil
                    publicMessages.removeAll(keepingCapacity: true)
                    terminalSourceKey = nil
                    activeTaskTitle = latestUserTitle ?? activeTaskTitle
                    taskStartedAt = eventDate
                    lastUpdatedAt = eventDate
                    events.removeAll(keepingCapacity: true)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务开始"),
                        to: events
                    )
                    trimEvents()
                    return .metadata
                } else if payloadType == "task_complete" {
                    lifecycle = .completed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    activeToolSourceKeys.removeAll()
                    lastUpdatedAt = eventDate
                    terminalSourceKey = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "terminal"
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务完成"),
                        to: events
                    )
                    trimEvents()
                    return .terminal
                } else if ["task_failed", "turn_aborted", "error"].contains(payloadType) {
                    lifecycle = .failed
                    pendingUserInputCalls.removeAll()
                    activeTools.removeAll()
                    activeToolSourceKeys.removeAll()
                    lastUpdatedAt = eventDate
                    terminalSourceKey = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "terminal"
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "任务失败"),
                        to: events
                    )
                    trimEvents()
                    return .terminal
                } else if payloadType == "agent_message",
                          ["commentary", "final_answer"].contains(
                              (payload["phase"] as? String)?.lowercased() ?? ""
                          ),
                          let message = payload["message"] as? String,
                          let commentary = CodexTaskProgressReader.sanitizedPublicCommentary(message) {
                    if latestPublicCommentary != commentary {
                        publicCommentaryText = CodexTaskProgressReader
                            .budgetedPublicActivityText(
                                appendingTaskActivityParagraph(
                                    commentary,
                                    to: publicCommentaryText
                                )
                            )
                    }
                    latestPublicCommentary = commentary
                    let sourceOrder = location?.sourceOrder
                        ?? UInt64(publicMessages.count)
                    let stableKey = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "commentary-\(publicMessages.count)"
                    publicMessages.append(AgentActivityEntry(
                        id: AgentActivityEventID(
                            source: .codex,
                            sessionKey: sessionKey.lowercased(),
                            stableSourceKey: stableKey
                        ),
                        occurredAt: eventDate,
                        sourceOrder: sourceOrder,
                        text: commentary
                    ))
                    trimPublicMessages()
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .commentary, occurredAt: eventDate, text: commentary),
                        to: events
                    )
                    trimEvents()
                    lastUpdatedAt = eventDate
                    return .publicMessage
                } else if payloadType == "tool_completed",
                          let activity = payload["activity"] as? String {
                    // 新格式只在工具结束后落盘，因此只记历史活动，不写
                    // activeTools——否则会把已结束的工具显示成“正在”。
                    lastUpdatedAt = eventDate
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .tool, occurredAt: eventDate, text: activity),
                        to: events
                    )
                    trimEvents()
                    return .currentTool
                }
                return nil
            }
            if ["function_call", "custom_tool_call"].contains(payloadType),
               let name = payload["name"] as? String,
               let callID = payload["call_id"] as? String {
                let eventDate = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                lastUpdatedAt = eventDate
                if name == "request_user_input" {
                    pendingUserInputCalls.insert(callID)
                    activeTools.removeValue(forKey: callID)
                    activeToolSourceKeys.removeValue(forKey: callID)
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .lifecycle, occurredAt: eventDate, text: "等待输入"),
                        to: events
                    )
                    trimEvents()
                    return .metadata
                } else {
                    let toolActivity = CodexTaskProgressReader.safeToolActivity(name: name)
                    activeTools[callID] = (text: toolActivity, updatedAt: eventDate)
                    activeToolSourceKeys[callID] = location.map {
                        "bytes-\($0.startOffset)-\($0.byteCount)"
                    } ?? "active-tool-\(callID)"
                    trimActiveTools()
                    events = appendingTaskActivityEvent(
                        TaskActivityEvent(kind: .tool, occurredAt: eventDate, text: toolActivity),
                        to: events
                    )
                    trimEvents()
                    return .currentTool
                }
            }
            if ["function_call_output", "custom_tool_call_output"].contains(payloadType),
               let callID = payload["call_id"] as? String {
                let wasPendingInput = pendingUserInputCalls.remove(callID) != nil
                let wasActiveTool = activeTools.removeValue(forKey: callID) != nil
                activeToolSourceKeys.removeValue(forKey: callID)
                if wasPendingInput || wasActiveTool {
                    lastUpdatedAt = CodexTaskProgressReader.timestamp(from: record) ?? lastUpdatedAt
                    return .currentTool
                }
            }
            return nil
        }

        func snapshot(
            modificationDate: Date,
            now: Date,
            sessionKey: String = ""
        ) -> TaskProgressSnapshot {
            let title = activeTaskTitle ?? latestUserTitle ?? "Codex 任务"
            let projection = buildProjection(sessionKey: sessionKey)
            if lifecycle == .running, !pendingUserInputCalls.isEmpty {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .waitingForInput,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    workingDirectory: workingDirectory,
                    projection: projection
                )])
            }
            if let lifecycle {
                let activityText: String?
                if lifecycle == .running {
                    activityText = CodexTaskProgressReader.runningActivityText(
                        activeTools: activeTools,
                        publicCommentaryText: publicCommentaryText
                    )
                } else { activityText = nil }
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: lifecycle,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    activityText: activityText,
                    workingDirectory: workingDirectory,
                    projection: projection
                )])
            }
            if !pendingUserInputCalls.isEmpty {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .waitingForInput,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    workingDirectory: workingDirectory,
                    projection: projection
                )])
            }
            if now.timeIntervalSince(modificationDate) <= 30 * 60 {
                return TaskProgressSnapshot(items: [TaskProgressItem(
                    title: title, kind: .running,
                    startedAt: taskStartedAt, updatedAt: lastUpdatedAt,
                    activityText: CodexTaskProgressReader.runningActivityText(
                        activeTools: activeTools,
                        publicCommentaryText: publicCommentaryText
                    ),
                    workingDirectory: workingDirectory,
                    projection: projection
                )])
            }
            return .idle
        }

        private func buildProjection(sessionKey: String) -> AgentActivityProjection {
            let activeToolEntry = activeTools.max {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt < $1.value.updatedAt
                }
                return $0.key < $1.key
            }.map { callID, entry in
                AgentActivityEntry(
                    id: AgentActivityEventID(
                        source: .codex,
                        sessionKey: sessionKey.lowercased(),
                        stableSourceKey: activeToolSourceKeys[callID]
                            ?? "active-tool-\(callID)"
                    ),
                    occurredAt: entry.updatedAt,
                    sourceOrder: UInt64.max,
                    text: entry.text
                )
            }
            let terminalEvent: AgentActivityEntry?
            if lifecycle == .completed || lifecycle == .failed {
                terminalEvent = events.last(where: { $0.kind == .lifecycle }).map {
                    AgentActivityEntry(
                        id: AgentActivityEventID(
                            source: .codex,
                            sessionKey: sessionKey.lowercased(),
                            stableSourceKey: terminalSourceKey ?? "terminal"
                        ),
                        occurredAt: $0.occurredAt,
                        sourceOrder: UInt64.max - 1,
                        text: $0.text
                    )
                }
            } else {
                terminalEvent = nil
            }
            return AgentActivityProjection(
                publicMessages: publicMessages,
                currentToolStatus: activeToolEntry,
                terminalEvent: terminalEvent
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

        private static func timestamp(from record: [String: Any]) -> Date? {
            CodexTaskProgressReader.timestamp(from: record)
        }
    }
    private struct RolloutSessionMetadata {
        let firstLine: String?
        let workingDirectory: String?
    }

    private struct CachedSessionMetadataEntry {
        let sourceIdentity: TranscriptSourceIdentity?
        let metadata: RolloutSessionMetadata
    }

    private struct CachedRolloutVisibilityEntry {
        let sourceIdentity: TranscriptSourceIdentity?
        let isVisible: Bool
    }

    private struct ColdScanRecord {
        let line: String
        let location: TranscriptRecordLocation
    }

    private let fileManager = FileManager.default
    private let indexRootDirectory: URL
    private let nowProvider: () -> Date
    private let rolloutRescanInterval: TimeInterval = codexTaskProgressRescanInterval
    private let activeTaskFreshness: TimeInterval = 30 * 60
    private let completedTaskVisibility = completedTaskPanelRetention
    private var cachedRollouts: [RolloutCandidate] = []
    private var cachedRolloutVisibility: [String: CachedRolloutVisibilityEntry] = [:]
    private var cachedSessionMetadata: [String: CachedSessionMetadataEntry] = [:]
    private var parsedCache: [String: ParsedCacheEntry] = [:]
    private var cachedThreadTitles: [String: String] = [:]
    private var cachedThreadIndexModificationDate: Date?
    private var cachedThreadTitleBackscanContinuation: UInt64?
    private var cachedThreadTitleBackscanBytes = 0
    private var cachedUnreadThreadIDs = Set<String>()
    private var cachedExplicitlyVisibleThreadIDs = Set<String>()
    private var cachedUnreadStateModificationDate: Date?
    private var hasCachedUnreadState = false
    private var nextRolloutScanAt = Date.distantPast
    private var rolloutDiscoveryUnavailable = false

    init(
        indexRootDirectory: URL = TranscriptIndexStore.defaultRootDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.indexRootDirectory = indexRootDirectory
        nowProvider = now
    }

    func readCollection() -> TaskProgressCollectionSnapshot {
        let now = nowProvider()
        let unreadState = readUnreadThreadState()
        let rolloutCandidates = recentRollouts(
            at: now,
            unreadThreadIDs: unreadState.ids,
            explicitlyVisibleThreadIDs: unreadState.explicitlyVisibleIDs
        )
        let threadTitles = readThreadTitleIndex(
            candidateThreadIDs: Set(rolloutCandidates.compactMap {
                Self.threadID(from: $0.url)
            })
        )
        var items: [TaskProgressItem] = []
        for candidate in rolloutCandidates {
            let cacheKey = candidate.url.path
            let candidateIdentity = TranscriptEventReader.make(
                at: candidate.url
            )?.identity
            let sessionMetadata = readSessionMetadata(
                from: candidate.url,
                sourceIdentity: candidateIdentity
            )
            let snapshot: TaskProgressSnapshot
            let candidateSize = (try? fileManager.attributesOfItem(
                atPath: candidate.url.path
            )[.size] as? NSNumber)?.uint64Value ?? 0
            if let cached = parsedCache[cacheKey],
               cached.modificationDate == candidate.modificationDate,
               let cachedReader = cached.reader,
               cachedReader.identity == candidateIdentity,
               cachedReader.scanHead >= candidateSize,
               (cached.backscanContinuation == nil
                    || cached.backscanBytes >= TranscriptReadBudget
                        .transcriptEvents.maximumAutomaticBackscanBytes)
            {
                snapshot = cached.snapshot
            } else {
                // 增量 reducer：有持久 reader 时做前向 pass，只 apply 新
                // records 到持久 reducer 状态（不保存原始行）。
                // 无则冷启动回扫后 apply 全部回扫记录。
                var reader: TranscriptEventReader?
                var reducer: CodexReducerState
                var descriptors: [TranscriptRecordLocation] = []
                var backscanCont: UInt64?
                var backscanBytes = 0
                var snapEOF: UInt64 = 0
                let sessionKey = Self.threadID(from: candidate.url)
                    ?? candidate.url.lastPathComponent
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
                        // 链式保持：从持久 descriptors 种子继续，避免
                        // 第二次重启只剩新尾部（§4.2 链）。
                        descriptors = cached.descriptors
                        backscanCont = cached.backscanContinuation
                        backscanBytes = cached.backscanBytes
                        for record in records {
                            if let line = String(
                                data: record.data, encoding: .utf8
                            ) {
                                if let eventClass = reducer.apply(
                                    line,
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
                            let historical = readTailLinesColdScan(
                                reader: cachedReader,
                                url: candidate.url,
                                fromEnd: continuation,
                                maximumBytes: remainingReadBudget
                            )
                            for record in historical.lines {
                                if Self.isHistoricalColdRecordSafeToApply(
                                    record.line
                                ) {
                                    reducer.apply(
                                        record.line,
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
                        reducer = CodexReducerState(modificationDate: candidate.modificationDate)
                        let cold = readTailLinesColdScan(
                            reader: newReader, url: candidate.url
                        )
                        for record in cold.lines {
                            reducer.apply(
                                record.line,
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
                        agentID: .codex, sessionKey: sessionKey
                    )
                    let probeReader = TranscriptEventReader.make(
                        at: candidate.url
                    )
                    if let checkpoint = checkpoint,
                       let probeReader = probeReader,
                       checkpoint.sourceIdentity == probeReader.identity,
                       checkpoint.committedOffset <= probeReader.snapshotEOF
                    {
                        // Index-hit：从 descriptor 回读 record data。
                        descriptors = checkpoint.publicMessageDescriptors
                        reducer = CodexReducerState(modificationDate: candidate.modificationDate)
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
                            let descriptor = restored.descriptor
                            let line = restored.line
                            reducer.apply(
                                line,
                                location: descriptor,
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
                            let historical = readTailLinesColdScan(
                                reader: probeReader,
                                url: candidate.url,
                                fromEnd: continuation,
                                maximumBytes: remainingReadBudget
                            )
                            for record in historical.lines {
                                if Self.isHistoricalColdRecordSafeToApply(
                                    record.line
                                ) {
                                    reducer.apply(
                                        record.line,
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
                        reducer = CodexReducerState(modificationDate: candidate.modificationDate)
                        let cold = readTailLinesColdScan(
                            reader: newReader, url: candidate.url
                        )
                        for record in cold.lines {
                            reducer.apply(
                                record.line,
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
                snapshot = reducer.snapshot(
                    modificationDate: candidate.modificationDate,
                    now: now,
                    sessionKey: sessionKey
                )
                let previousBackscanCont = parsedCache[cacheKey]?
                    .backscanContinuation
                parsedCache[cacheKey] = ParsedCacheEntry(
                    modificationDate: candidate.modificationDate,
                    snapshot: snapshot,
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
                        agentID: .codex,
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
                    let terminal = snapshot.items.first.map {
                        $0.kind == .completed || $0.kind == .failed
                    } ?? false
                    let continuationChanged = backscanCont
                        != previousBackscanCont
                    if terminal || continuationChanged {
                        try? indexStore.flush(
                            checkpoint, agentID: .codex, sessionKey: sessionKey
                        )
                    } else {
                        try? indexStore.save(
                            checkpoint, agentID: .codex, sessionKey: sessionKey
                        )
                    }
                }
            }
            guard var item = snapshot.items.first, item.kind != .idle else { continue }
            let resolvedTitle = Self.resolvedTitle(
                for: candidate.url,
                indexedTitles: threadTitles,
                fallback: item.title
            )
            let threadID = Self.threadID(from: candidate.url)
            item = TaskProgressItem(
                title: resolvedTitle,
                kind: item.kind,
                startedAt: item.startedAt,
                updatedAt: item.updatedAt,
                activityText: item.activityText,
                statusOverride: item.statusOverride,
                threadID: threadID,
                workingDirectory: item.workingDirectory
                    ?? sessionMetadata.workingDirectory,
                projection: item.projection
            )
            guard Self.shouldDisplay(
                kind: item.kind,
                threadID: threadID,
                modificationDate: candidate.modificationDate,
                now: now,
                unreadState: unreadState,
                fallbackVisibility: completedTaskVisibility,
                activeVisibility: activeTaskFreshness,
                terminalDate: item.updatedAt
            ) else { continue }
            items.append(item)
        }

        return .displaying(items)
    }

    func read() -> TaskProgressSnapshot {
        readCollection().compactProjection()
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

    private static func isPublicMessageLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "event_msg",
              var payload = record["payload"] as? [String: Any]
        else {
            return false
        }
        // 与 reducer 走同一套归一化，否则新格式的公开消息不会进冷扫描
        // 描述符，历史记录也不会被 apply。
        if payload["type"] as? String == "item_completed" {
            guard let mapped = normalizedCompletedItemPayload(payload) else {
                return false
            }
            payload = mapped
        }
        guard payload["type"] as? String == "agent_message",
              ["commentary", "final_answer"].contains(
                  (payload["phase"] as? String)?.lowercased() ?? ""
              ),
              let message = payload["message"] as? String,
              sanitizedPublicCommentary(message) != nil
        else {
            return false
        }
        return true
    }

    static func parse(
        lines: [String],
        modificationDate: Date,
        now: Date
    ) -> TaskProgressSnapshot {
        var reducer = CodexReducerState(modificationDate: modificationDate)
        for line in lines {
            reducer.apply(line)
        }
        return reducer.snapshot(modificationDate: modificationDate, now: now)
    }

    private static func runningActivityText(
        activeTools: [String: (text: String, updatedAt: Date)],
        publicCommentaryText: String
    ) -> String {
        let activeTool = activeTools.values.max {
            $0.updatedAt < $1.updatedAt
        }?.text
        let sections = [
            activeTool,
            publicCommentaryText.isEmpty ? nil : publicCommentaryText,
        ].compactMap { $0 }
        return sections.isEmpty
            ? "正在思考"
            : sections.joined(separator: " · ")
    }

    private static func safeToolActivity(name: String) -> String {
        switch name.lowercased() {
        case "exec_command":
            return "正在运行命令"
        case "apply_patch":
            return "正在编辑文件"
        case let value
            where value.contains("web")
                || value.contains("browser")
                || value.contains("search"):
            return "正在搜索或检查网页"
        default:
            return "正在使用工具"
        }
    }

    /// Codex 0.147 起把用户消息、助手消息和工具调用统一写成
    /// `event_msg/item_completed`，旧的 agent_message、user_message 与
    /// custom_tool_call 事件不再出现。这里映射回既有 payload 语义，
    /// 使下游 reducer 分支与真值夹具都不必改动。
    /// thinking（Reasoning）、上下文压缩和图片查看不属于公开活动，返回 nil。
    private static func normalizedCompletedItemPayload(
        _ payload: [String: Any]
    ) -> [String: Any]? {
        guard let item = payload["item"] as? [String: Any],
              let itemType = item["type"] as? String
        else { return nil }
        switch itemType {
        case "AgentMessage":
            guard let message = completedItemText(item) else { return nil }
            var mapped: [String: Any] = [
                "type": "agent_message",
                "message": message,
            ]
            if let phase = item["phase"] as? String {
                mapped["phase"] = phase
            }
            return mapped
        case "UserMessage":
            guard let message = completedItemText(item) else { return nil }
            return ["type": "user_message", "message": message]
        case "CommandExecution":
            // 命令内容一律不进事件文本，只保留固定的脱敏描述。
            return [
                "type": "tool_completed",
                "activity": safeToolActivity(name: "exec_command"),
            ]
        case "McpToolCall":
            return [
                "type": "tool_completed",
                "activity": safeToolActivity(name: item["tool"] as? String ?? ""),
            ]
        default:
            return nil
        }
    }

    /// 只取 item.content 里的文本分量：`local_image` 等非文本分量跳过。
    private static func completedItemText(_ item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { entry -> String? in
            guard (entry["type"] as? String)?.lowercased() == "text" else {
                return nil
            }
            return entry["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func budgetedPublicActivityText(_ text: String) -> String {
        safeUTF8Truncated(
            text,
            to: AgentActivityBudget.maximumPublicMessagesTotalBytes
        )
    }

    private static func sanitizedPublicCommentary(_ message: String) -> String? {
        let markdownPatterns: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]+\)"#, ""),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"[`*_>#~-]+"#, ""),
        ]
        var lines = message.components(separatedBy: .newlines).map {
            rawLine -> String in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for (pattern, replacement) in markdownPatterns {
                line = line.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
            line = line.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return line
        }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let joined = lines.joined(separator: " ")
        return safePublicActivityParagraph(from: joined)
    }

    private static func taskTitle(from rawMessage: String) -> String? {
        var value = rawMessage
        if let marker = value.range(
            of: "## My request for Codex:",
            options: [.caseInsensitive]
        ) {
            value = String(value[marker.upperBound...])
        }
        if let imageTag = value.range(of: "<image", options: [.caseInsensitive]) {
            value = String(value[..<imageTag.lowerBound])
        }

        let lines = value.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("## My request"),
                  !trimmed.hasPrefix("/")
            else { return nil }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#*- "))
        }
        let title = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    private static func timestamp(from record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    static func threadID(from rolloutURL: URL) -> String? {
        let filename = rolloutURL.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(filename[range]).lowercased()
    }

    static func resolvedTitle(
        for rolloutURL: URL,
        indexedTitles: [String: String],
        fallback: String
    ) -> String {
        guard let threadID = threadID(from: rolloutURL),
              let indexedTitle = indexedTitles[threadID],
              !indexedTitle.isEmpty
        else { return fallback }
        return indexedTitle
    }

    static func isUserVisibleSessionMetadata(
        line: String,
        explicitlyVisible: Bool = false
    ) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else {
            return true
        }

        let threadSource = (payload["thread_source"] as? String)?.lowercased()
        if threadSource == "automation" {
            return false
        }
        let isSubagent = threadSource == "subagent"
            || (payload["source"] as? [String: Any])?["subagent"] != nil
        if isSubagent {
            return explicitlyVisible
        }
        return true
    }

    static func workingDirectoryFromSessionMetadata(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let rawCwd = payload["cwd"] as? String
        else { return nil }
        return normalizedAbsolutePath(rawCwd)
    }

    static func shouldDisplay(
        kind: TaskProgressKind,
        threadID: String?,
        modificationDate: Date,
        now: Date,
        unreadState: UnreadThreadState,
        fallbackVisibility: TimeInterval = completedTaskPanelRetention,
        activeVisibility: TimeInterval = 30 * 60,
        terminalDate: Date? = nil
    ) -> Bool {
        if kind == .completed || kind == .failed {
            guard taskIsWithinTerminalPanelRetention(
                kind: kind,
                updatedAt: terminalDate ?? modificationDate,
                now: now,
                retention: fallbackVisibility
            ) else { return false }
            // 只有当未读信号确实覆盖到这个会话时，才用它判断是否已读。
            // 信号定格之后创建的会话一律不在集合里，那不代表用户读过。
            if unreadState.isAvailable,
               let threadID,
               unreadState.covers(threadID: threadID) {
                return unreadState.ids.contains(threadID)
            }
            return true
        }
        if kind == .running || kind == .waitingForInput || kind == .reading {
            if unreadState.isAvailable,
               let threadID,
               unreadState.ids.contains(threadID)
            {
                return true
            }
            return now.timeIntervalSince(modificationDate) <= activeVisibility
        }
        return true
    }

    private func codexHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func readThreadTitleIndex(
        candidateThreadIDs: Set<String>
    ) -> [String: String] {
        let indexURL = codexHomeURL().appendingPathComponent("session_index.jsonl")
        guard !candidateThreadIDs.isEmpty else { return cachedThreadTitles }
        guard let values = try? indexURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return cachedThreadTitles
        }

        if cachedThreadIndexModificationDate == modificationDate,
           candidateThreadIDs.isSubset(of: Set(cachedThreadTitles.keys)) {
            return cachedThreadTitles
        }

        var titles = cachedThreadIndexModificationDate == modificationDate
            ? cachedThreadTitles
            : [:]
        guard let reader = TranscriptEventReader.make(at: indexURL) else {
            return cachedThreadTitles
        }
        reader.setCommittedOffset(reader.snapshotEOF)
        if cachedThreadIndexModificationDate != modificationDate {
            cachedThreadTitleBackscanContinuation = reader.snapshotEOF
            cachedThreadTitleBackscanBytes = 0
        }
        if let endOffset = cachedThreadTitleBackscanContinuation,
           endOffset > 0,
           cachedThreadTitleBackscanBytes < TranscriptReadBudget
                .transcriptEvents.maximumAutomaticBackscanBytes,
           titles.count < candidateThreadIDs.count {
            let passBytes = TranscriptReadBudget.transcriptEvents
                .maximumBytesPerPass
            let bytesBefore = reader.diagnostics.bytesRead
            let result = reader.readBackwardPass(
                fromEnd: endOffset,
                maximumBytes: passBytes
            )
            let scannedBytes = max(
                0,
                reader.diagnostics.bytesRead - bytesBefore
            )
            if case .success(let (records, cont, _)) = result {
                for record in records.reversed() {
                    guard let line = String(data: record.data, encoding: .utf8),
                          let lineData = line.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let rawID = parsed["id"] as? String,
                          candidateThreadIDs.contains(rawID.lowercased()),
                          let rawTitle = parsed["thread_name"] as? String
                    else { continue }
                    if titles[rawID.lowercased()] != nil { continue }
                    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    titles[rawID.lowercased()] = String(title.prefix(80))
                }
                cachedThreadTitleBackscanContinuation = cont
                cachedThreadTitleBackscanBytes += scannedBytes
            } else {
                cachedThreadTitleBackscanContinuation = nil
            }
        }

        cachedThreadTitles = titles
        cachedThreadIndexModificationDate = modificationDate
        return titles
    }

    private func readUnreadThreadState() -> UnreadThreadState {
        let stateURL: URL
        if let override = ProcessInfo.processInfo.environment["THREADHELM_CODEX_STATE_FILE"],
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
        } else {
            stateURL = codexHomeURL().appendingPathComponent(".codex-global-state.json")
        }

        guard let values = try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        if cachedUnreadStateModificationDate == modificationDate {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }

        guard let data = try? Data(contentsOf: stateURL),
              let state = Self.threadState(from: data)
        else {
            return UnreadThreadState(
                ids: cachedUnreadThreadIDs,
                explicitlyVisibleIDs: cachedExplicitlyVisibleThreadIDs,
                isAvailable: hasCachedUnreadState
            )
        }
        cachedUnreadThreadIDs = state.ids
        cachedExplicitlyVisibleThreadIDs = state.explicitlyVisibleIDs
        cachedUnreadStateModificationDate = modificationDate
        hasCachedUnreadState = state.isAvailable
        nextRolloutScanAt = .distantPast
        return state
    }

    static func threadState(from data: Data) -> UnreadThreadState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let atomState = root["electron-persisted-atom-state"] as? [String: Any]
        let unreadByHost = atomState?["unread-thread-ids-by-host-v1"] as? [String: Any]
        var unreadIDs = Set<String>()
        for value in unreadByHost?.values ?? Dictionary<String, Any>().values {
            guard let hostIDs = value as? [String] else { continue }
            unreadIDs.formUnion(hostIDs.map { $0.lowercased() })
        }

        var explicitlyVisibleIDs = Set<String>()
        for key in ["pinned-thread-ids", "projectless-thread-ids"] {
            guard let ids = root[key] as? [String] else { continue }
            explicitlyVisibleIDs.formUnion(ids.map { $0.lowercased() })
        }
        if let assignments = root["thread-project-assignments"] as? [String: Any] {
            explicitlyVisibleIDs.formUnion(assignments.keys.map { $0.lowercased() })
        }

        return UnreadThreadState(
            ids: unreadIDs,
            explicitlyVisibleIDs: explicitlyVisibleIDs,
            isAvailable: unreadByHost != nil
        )
    }

    private func recentRollouts(
        at now: Date,
        unreadThreadIDs: Set<String>,
        explicitlyVisibleThreadIDs: Set<String>
    ) -> [RolloutCandidate] {
        if let override = ProcessInfo.processInfo.environment["THREADHELM_TASK_ROLLOUT_FILE"],
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            guard isUserVisibleRollout(
                url,
                explicitlyVisibleThreadIDs: explicitlyVisibleThreadIDs
            ) else { return [] }
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now
            return [RolloutCandidate(url: url, modificationDate: modified)]
        }

        // A denied removable-volume prompt makes enumeration fail. Retrying on
        // every five-second refresh only prompts the user again; wait for an app
        // restart before trying the unavailable transcript root another time.
        guard !rolloutDiscoveryUnavailable else { return [] }

        if now < nextRolloutScanAt, !cachedRollouts.isEmpty {
            return cachedRollouts.filter { fileManager.fileExists(atPath: $0.url.path) }
        }

        nextRolloutScanAt = now.addingTimeInterval(rolloutRescanInterval)
        let codexHome = codexHomeURL()
        // sessions 可能被搬到外置卷、只在家目录留符号链接：URL 枚举器不跟随
        // 符号链接根，不解析就会把整个会话目录当成空目录。
        let sessionsURL = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileManager.isReadableFile(atPath: sessionsURL.path) else {
            rolloutDiscoveryUnavailable = true
            cachedRollouts = []
            return []
        }
        var discoveryFailed = false
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                discoveryFailed = true
                return false
            }
        ) else {
            rolloutDiscoveryUnavailable = true
            cachedRollouts = []
            return []
        }

        var candidates: [RolloutCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            let threadID = Self.threadID(from: url)
            let isUnread = threadID.map { unreadThreadIDs.contains($0) } ?? false
            let scanVisibility = max(
                activeTaskFreshness,
                completedTaskVisibility
            )
            guard now.timeIntervalSince(modified) <= scanVisibility || isUnread,
                  isUserVisibleRollout(
                      url,
                      explicitlyVisibleThreadIDs: explicitlyVisibleThreadIDs
                  )
            else {
                continue
            }
            candidates.append(RolloutCandidate(url: url, modificationDate: modified))
        }
        guard !discoveryFailed else {
            rolloutDiscoveryUnavailable = true
            cachedRollouts = []
            return []
        }

        cachedRollouts = Array(candidates.sorted {
            $0.modificationDate > $1.modificationDate
        }.prefix(12))
        let activePaths = Set(cachedRollouts.map { $0.url.path })
        let indexStore = TranscriptIndexStore(
            rootDirectory: indexRootDirectory,
            fileManager: fileManager
        )
        for stalePath in parsedCache.keys where !activePaths.contains(stalePath) {
            let staleURL = URL(fileURLWithPath: stalePath)
            let sessionKey = Self.threadID(from: staleURL)
                ?? staleURL.lastPathComponent
            indexStore.delete(agentID: .codex, sessionKey: sessionKey)
        }
        let referencedSessionKeys = Set(cachedRollouts.map {
            Self.threadID(from: $0.url) ?? $0.url.lastPathComponent
        })
        indexStore.purgeOrphans(
            agentID: .codex,
            referencedSessionKeys: referencedSessionKeys,
            now: now
        )
        parsedCache = parsedCache.filter { activePaths.contains($0.key) }
        return cachedRollouts
    }

    private func readSessionMetadata(
        from url: URL,
        sourceIdentity: TranscriptSourceIdentity? = nil
    ) -> RolloutSessionMetadata {
        let currentIdentity = sourceIdentity
            ?? TranscriptEventReader.make(at: url)?.identity
        if let cached = cachedSessionMetadata[url.path],
           cached.sourceIdentity == currentIdentity
        {
            return cached.metadata
        }
        var firstLine: String?
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144),
               let text = String(data: data, encoding: .utf8),
               let line = text.split(separator: "\n", maxSplits: 1).first
            {
                firstLine = String(line)
            }
        }
        let metadata = RolloutSessionMetadata(
            firstLine: firstLine,
            workingDirectory: firstLine.flatMap(
                Self.workingDirectoryFromSessionMetadata(line:)
            )
        )
        cachedSessionMetadata[url.path] = CachedSessionMetadataEntry(
            sourceIdentity: currentIdentity,
            metadata: metadata
        )
        return metadata
    }

    private func isUserVisibleRollout(
        _ url: URL,
        explicitlyVisibleThreadIDs: Set<String>
    ) -> Bool {
        let explicitlyVisible = Self.threadID(from: url).map {
            explicitlyVisibleThreadIDs.contains($0)
        } ?? false
        let cacheKey = "\(url.path)#\(explicitlyVisible ? "explicit" : "default")"
        let sourceIdentity = TranscriptEventReader.make(at: url)?.identity
        if let cached = cachedRolloutVisibility[cacheKey],
           cached.sourceIdentity == sourceIdentity
        {
            return cached.isVisible
        }
        var isVisible = true
        if let firstLine = readSessionMetadata(
            from: url,
            sourceIdentity: sourceIdentity
        ).firstLine {
            isVisible = Self.isUserVisibleSessionMetadata(
                line: firstLine,
                explicitlyVisible: explicitlyVisible
            )
        }
        cachedRolloutVisibility[cacheKey] = CachedRolloutVisibilityEntry(
            sourceIdentity: sourceIdentity,
            isVisible: isVisible
        )
        return isVisible
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

    private func readTailLinesColdScan(
        reader: TranscriptEventReader,
        url: URL,
        fromEnd requestedEndOffset: UInt64? = nil,
        maximumBytes: Int = TranscriptReadBudget.transcriptEvents
            .maximumBytesPerPass
    ) -> ColdScanResult {
        let fileSize = (try? fileManager.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        // 有界回扫：每次 readCollection 只做一个 8 MiB backward pass。
        // 跨刷新由 checkpoint/cache 中的 continuation 推进，单 lifecycle
        // 由调用方限制最多 64 MiB。
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
                    if Self.isPublicMessageLine(line) {
                        descriptors.append(location)
                    }
                }
            }
            nextContinuation = cont
        }
        // 持久 checkpoint 停在最后完整 LF 后（末尾未完成行不计入）。
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

    private static func isHistoricalColdRecordSafeToApply(_ line: String) -> Bool {
        line.contains("session_meta")
            || line.contains("user_message")
            // 新格式的用户消息不含 user_message 字面量。工具记录同旧格式
            // 一样仍不回放，历史工具不该显示成当前活动。
            || line.contains(#""UserMessage""#)
            || isPublicMessageLine(line)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
