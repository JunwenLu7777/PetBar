//
//  AgentTruthReplay.swift
//  ThreadHelm
//
//  模块职责：只读回放五 Agent 的脱敏固定版本真值夹具。夹具信号进入
//  Swift 生产归一化与 AgentEventReducer；结果只用于发布验证，不写个人会话证据。
//

import Foundation

private enum AgentTruthFixtureContract {
    static let baselineCommit =
        "f7cb4843eea3aa5aae9ee6045092c007f7cd9452"
}

struct AgentTruthReplayMetric: Equatable {
    let agentID: AgentID
    let misses: Int
    let hardAttentionOpportunities: Int
    let falseAlerts: Int
    let negativeDecisions: Int
    let duplicateVisibleItems: Int
    let visibleAttentionItems: Int
    let exactReturnSuccesses: Int
    let exactReturnAttempts: Int
    let testedVersion: String
    let collectionWindow: String

    var line: String {
        [
            "agent=\(agentID.rawValue)",
            "miss=\(misses)/\(hardAttentionOpportunities)",
            "falseAlert=\(falseAlerts)/\(negativeDecisions)",
            "duplicate=\(duplicateVisibleItems)/\(visibleAttentionItems)",
            "exactReturn=\(exactReturnSuccesses)/\(exactReturnAttempts)",
            "testedVersion=\(testedVersion)",
            "collectionWindow=\(collectionWindow)",
            "source=redacted-truth-fixture",
        ].joined(separator: " ")
    }
}

struct AgentTruthReplayReport: Equatable {
    let scenarioCount: Int
    let metrics: [AgentTruthReplayMetric]
}

enum AgentTruthReplayError: LocalizedError {
    case invalidFixture(String)
    case unsupportedSignal(agentID: AgentID, signal: String)
    case mismatch(
        scenarioID: String,
        field: String,
        expected: String,
        actual: String
    )

    var errorDescription: String? {
        switch self {
        case .invalidFixture(let detail):
            return "真值夹具无效：\(detail)"
        case .unsupportedSignal(let agentID, let signal):
            return "未识别的脱敏信号：\(agentID.rawValue) / \(signal)"
        case .mismatch(let scenarioID, let field, let expected, let actual):
            return "场景 \(scenarioID) 的 \(field) 不一致：期望 \(expected)，实际 \(actual)"
        }
    }
}

func runAgentTruthReplayCLIIfRequested(
    arguments: [String] = CommandLine.arguments
) -> Int? {
    guard let flag = arguments.firstIndex(of: "--verify-agent-truth") else {
        return nil
    }
    guard arguments.indices.contains(flag + 1),
          flag + 2 == arguments.count
    else {
        fputs("用法：--verify-agent-truth <fixture-root>\n", stderr)
        return 64
    }
    let root = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    do {
        let report = try verifyAgentTruthFixtures(at: root)
        print(
            "agent-truth-replay: agents=\(report.metrics.count) "
                + "scenarios=\(report.scenarioCount) "
                + "personal-sessions=unchanged"
        )
        report.metrics.forEach { print("agent-truth-metric: \($0.line)") }
        return 0
    } catch {
        fputs("agent-truth-replay failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

func verifyAgentTruthFixtures(
    at fixtureRoot: URL
) throws -> AgentTruthReplayReport {
    let root = fixtureRoot.standardizedFileURL.resolvingSymlinksInPath()
    let index: TruthIndex = try decodeTruthFixture(
        TruthIndex.self,
        at: root.appendingPathComponent("index.json")
    )
    let versions: TruthVersions = try decodeTruthFixture(
        TruthVersions.self,
        at: root.appendingPathComponent("versions.json")
    )
    guard index.schemaVersion == 1,
          versions.schemaVersion == 1,
          index.agents == AgentID.builtInOrder.map(\.rawValue),
          Set(index.scenarioFiles.keys) == Set(index.agents),
          Set(versions.agents.keys) == Set(index.agents)
    else {
        throw AgentTruthReplayError.invalidFixture(
            "schema、Agent 顺序或版本表不匹配"
        )
    }
    guard index.baselineCommit == AgentTruthFixtureContract.baselineCommit,
          versions.baselineCommit == index.baselineCommit
    else {
        throw AgentTruthReplayError.invalidFixture(
            "index.json 或 versions.json 的 baselineCommit 不匹配"
        )
    }

    let profiles = builtInAgentValidationProfiles()
    var scenariosByAgent: [AgentID: [TruthScenario]] = [:]
    var scenarioIDs = Set<String>()
    for agentID in AgentID.builtInOrder {
        guard let relativePath = index.scenarioFiles[agentID.rawValue],
              let scenarioURL = truthFixtureChildURL(
                  relativePath,
                  root: root
              ),
              let version = versions.agents[agentID.rawValue],
              let profile = profiles[agentID]
        else {
            throw AgentTruthReplayError.invalidFixture(
                "缺少 \(agentID.rawValue) 的场景、版本或验证档案"
            )
        }
        try verifyPinnedFixtureVersion(
            version,
            agentID: agentID,
            profile: profile
        )
        let document: TruthScenarioDocument = try decodeTruthFixture(
            TruthScenarioDocument.self,
            at: scenarioURL
        )
        guard document.schemaVersion == 1,
              document.agentId == agentID.rawValue,
              document.observedAgentVersion == version.version,
              document.baselineCommit == index.baselineCommit,
              document.scenarios.allSatisfy({
                  $0.agentId == agentID.rawValue
                      && $0.observedAgentVersion == version.version
              })
        else {
            throw AgentTruthReplayError.invalidFixture(
                "\(agentID.rawValue) 场景文档、baseline 或版本表不一致"
            )
        }
        for scenario in document.scenarios {
            guard !scenario.id.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  scenarioIDs.insert(scenario.id).inserted
            else {
                throw AgentTruthReplayError.invalidFixture(
                    "场景 ID 为空或重复：\(scenario.id)"
                )
            }
            guard !scenario.captureSource.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  !scenario.evidence.isEmpty,
                  scenario.evidence.allSatisfy({
                      !$0.reference.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                  })
            else {
                throw AgentTruthReplayError.invalidFixture(
                    "\(scenario.id) 缺少 captureSource 或 evidence"
                )
            }
            if scenario.evidence.allSatisfy({ $0.kind == .syntheticPolicy }),
               scenario.expected.evidenceQuality != "inferred",
               scenario.expected.evidenceQuality != "unknown"
            {
                throw AgentTruthReplayError.invalidFixture(
                    "\(scenario.id) 的纯合成 evidence 夸大了证据质量"
                )
            }
        }
        scenariosByAgent[agentID] = document.scenarios
    }

    let allScenarios = AgentID.builtInOrder.flatMap {
        scenariosByAgent[$0] ?? []
    }
    guard allScenarios.count == index.counts.total,
          AgentID.builtInOrder.allSatisfy({ agentID in
              scenariosByAgent[agentID]?.count
                  == index.counts.byAgent[agentID.rawValue]
          })
    else {
        throw AgentTruthReplayError.invalidFixture(
            "场景总数或分 Agent 数量不匹配"
        )
    }

    var accumulators = Dictionary(
        uniqueKeysWithValues: AgentID.builtInOrder.map {
            ($0, TruthMetricAccumulator())
        }
    )
    for scenario in allScenarios {
        let agentID = AgentID(rawValue: scenario.agentId)
        guard AgentID.builtInOrder.contains(agentID),
              let profile = profiles[agentID]
        else {
            throw AgentTruthReplayError.invalidFixture(
                "未知 Agent：\(scenario.agentId)"
            )
        }
        let evaluation = try AgentTruthSignalNormalizer(
            agentID: agentID,
            adapterVersion: profile.testedVersionComponents.first?.value
                ?? profile.testedVersion
        ).evaluate(scenario)
        try compareTruthFields(
            scenarioID: scenario.id,
            expected: scenario.expected.fields,
            actual: evaluation.fields
        )
        accumulators[agentID]?.record(
            scenario: scenario,
            evaluation: evaluation
        )
    }

    let metrics = try AgentID.builtInOrder.map { agentID in
        guard let accumulator = accumulators[agentID],
              let profile = profiles[agentID]
        else {
            throw AgentTruthReplayError.invalidFixture(
                "缺少 \(agentID.rawValue) 指标累加器"
            )
        }
        return accumulator.metric(
            agentID: agentID,
            testedVersion: profile.testedVersion
        )
    }
    return AgentTruthReplayReport(
        scenarioCount: allScenarios.count,
        metrics: metrics
    )
}

private struct TruthIndex: Decodable {
    let schemaVersion: Int
    let baselineCommit: String
    let agents: [String]
    let scenarioFiles: [String: String]
    let counts: TruthCounts
}

private struct TruthCounts: Decodable {
    let total: Int
    let byAgent: [String: Int]
}

private struct TruthVersions: Decodable {
    let schemaVersion: Int
    let baselineCommit: String
    let agents: [String: TruthVersion]
}

private struct TruthVersion: Decodable {
    let version: String
    let agentCliVersion: String?
    let build: String?
}

private struct TruthScenarioDocument: Decodable {
    let schemaVersion: Int
    let agentId: String
    let observedAgentVersion: String
    let baselineCommit: String
    let scenarios: [TruthScenario]
}

private enum TruthCapabilityStatus: String, Decodable {
    case supported
    case unsupported
    case unknown
}

private enum TruthEvidenceKind: String, Decodable {
    case localCode
    case executableSelfTest
    case officialDocumentation
    case bundledDocumentation
    case localObservation
    case syntheticPolicy
}

private struct TruthEvidence: Decodable {
    let kind: TruthEvidenceKind
    let reference: String
}

private struct TruthScenario: Decodable {
    let id: String
    let agentId: String
    let capabilityStatus: TruthCapabilityStatus
    let captureSource: String
    let capturedAt: String
    let observedAgentVersion: String
    let input: TruthInput
    let expected: TruthExpected
    let evidence: [TruthEvidence]
}

private struct TruthInput: Decodable {
    let redacted: Bool
    let signal: String
}

private struct TruthExpected: Decodable {
    let executionState: String
    let attentionReason: String
    let actionability: String
    let evidenceQuality: String
    let freshness: String
    let openResult: String
    let interruptDecision: String

    var fields: TruthFields {
        TruthFields(
            executionState: executionState,
            attentionReason: attentionReason,
            actionability: actionability,
            evidenceQuality: evidenceQuality,
            freshness: freshness,
            openResult: openResult,
            interruptDecision: interruptDecision
        )
    }
}

private struct TruthFields: Equatable {
    let executionState: String
    let attentionReason: String
    let actionability: String
    let evidenceQuality: String
    let freshness: String
    let openResult: String
    let interruptDecision: String
}

private struct TruthEvaluation {
    let fields: TruthFields
    let attentionItems: [AgentAttentionItem]
    let openReport: AgentOpenReport?
}

private struct TruthMetricAccumulator {
    private(set) var misses = 0
    private(set) var hardAttentionOpportunities = 0
    private(set) var falseAlerts = 0
    private(set) var negativeDecisions = 0
    private(set) var duplicateVisibleItems = 0
    private(set) var visibleAttentionItems = 0
    private(set) var exactReturnSuccesses = 0
    private(set) var exactReturnAttempts = 0
    private(set) var capturedAtValues: [String] = []

    mutating func record(
        scenario: TruthScenario,
        evaluation: TruthEvaluation
    ) {
        let expectedInterrupt = scenario.expected.interruptDecision == "interrupt"
        let actualInterrupt = evaluation.fields.interruptDecision == "interrupt"
        if scenario.capabilityStatus == .supported && expectedInterrupt {
            hardAttentionOpportunities += 1
            if !actualInterrupt { misses += 1 }
        }
        if !expectedInterrupt {
            negativeDecisions += 1
            if actualInterrupt { falseAlerts += 1 }
        }

        var visibleKeys = Set<String>()
        for item in evaluation.attentionItems {
            visibleAttentionItems += 1
            let key = [
                item.identity.agentID.rawValue,
                item.identity.nativeID,
                item.reason.rawValue,
            ].joined(separator: ":")
            if !visibleKeys.insert(key).inserted {
                duplicateVisibleItems += 1
            }
        }
        if let report = evaluation.openReport, report.exactAttempted {
            exactReturnAttempts += 1
            if report.independentlyConfirmedIdentity {
                exactReturnSuccesses += 1
            }
        }
        capturedAtValues.append(scenario.capturedAt)
    }

    func metric(
        agentID: AgentID,
        testedVersion: String
    ) -> AgentTruthReplayMetric {
        let lower = capturedAtValues.min() ?? "unknown"
        let upper = capturedAtValues.max() ?? "unknown"
        return AgentTruthReplayMetric(
            agentID: agentID,
            misses: misses,
            hardAttentionOpportunities: hardAttentionOpportunities,
            falseAlerts: falseAlerts,
            negativeDecisions: negativeDecisions,
            duplicateVisibleItems: duplicateVisibleItems,
            visibleAttentionItems: visibleAttentionItems,
            exactReturnSuccesses: exactReturnSuccesses,
            exactReturnAttempts: exactReturnAttempts,
            testedVersion: testedVersion,
            collectionWindow: "\(lower)..\(upper)"
        )
    }
}

private enum TruthSignalSemantic: Equatable {
    case discovery
    case idle
    case running
    case recoverableToolFailure
    case taskFailure
    case completion
    case permission
    case question
    case planApproval
    case resolvedRequest
    case stale
    case offline
    case exactReturn
    case returnUnknown
    case appFallback
    case workingDirectoryFallback
    case unsupported
}

private struct AgentTruthSignalNormalizer {
    private static let nativeSessionID =
        "11111111-2222-4333-8444-555555555555"
    private static let requestID = UUID(
        uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!

    let agentID: AgentID
    let adapterVersion: String

    func evaluate(_ scenario: TruthScenario) throws -> TruthEvaluation {
        guard scenario.input.redacted else {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenario.id) 不是脱敏输入"
            )
        }
        guard let observedAt = ISO8601DateFormatter.truthFixture.date(
            from: scenario.capturedAt
        ) else {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenario.id) capturedAt 无效"
            )
        }
        let signal = scenario.input.signal
        let normalizedSignal = signal.lowercased()
        let semantic = try semantic(
            for: normalizedSignal,
            originalSignal: signal
        )
        let openReport = makeOpenReport(
            semantic: semantic,
            signal: normalizedSignal
        )

        if isDirectClassification(semantic) {
            let fields = directFields(
                semantic: semantic,
                signal: normalizedSignal,
                openReport: openReport
            )
            return TruthEvaluation(
                fields: fields,
                attentionItems: [],
                openReport: openReport
            )
        }

        var events = try normalizedEvents(
            semantic: semantic,
            scenarioID: scenario.id,
            signal: normalizedSignal,
            observedAt: observedAt
        )
        let duplicateInput = normalizedSignal.contains("observed twice")
            || normalizedSignal.contains("repeated")
        let outOfOrderInput = normalizedSignal.contains("older")
        if duplicateInput, let first = events.first {
            events.append(first)
        }
        if outOfOrderInput, let first = events.first {
            events[0] = copiedEvent(
                first,
                eventID: first.eventID,
                sequence: 2
            )
            events.append(olderEvent(
                than: events[0],
                semantic: semantic,
                scenarioID: scenario.id
            ))
        }

        let reduction = AgentEventReducer.reduce(events: events)
        guard let snapshot = reduction.snapshots.first else {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenario.id) 没有产生归一化快照"
            )
        }
        if duplicateInput,
           !(events.count >= 2 && reduction.processedEventCount < events.count)
        {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenario.id) 未经过 reducer 去重"
            )
        }
        if outOfOrderInput {
            let latest = events.compactMap { event -> (Int, String)? in
                event.sequence.map { ($0, event.eventID) }
            }.max { $0.0 < $1.0 }
            guard latest?.1 == snapshot.latestEventID else {
                throw AgentTruthReplayError.invalidFixture(
                    "\(scenario.id) 未经过 reducer 乱序裁决"
                )
            }
        }

        let evaluationDate = observedAt.addingTimeInterval(1)
        let freshness = snapshot.freshness.isStale(at: evaluationDate)
            ? "stale"
            : "fresh"
        let interrupt = reduction.attentionItems.contains {
            $0.identity.key == snapshot.identity.key && $0.isInterrupting
        }
        let fields = TruthFields(
            executionState: snapshot.executionState.rawValue,
            attentionReason: snapshot.attentionReason.rawValue,
            actionability: snapshot.actionability.rawValue,
            evidenceQuality: snapshot.evidenceQuality.rawValue,
            freshness: freshness,
            openResult: openReport?.result.rawValue
                ?? OpenResult.notAttempted.rawValue,
            interruptDecision: interrupt ? "interrupt" : "nonInterrupt"
        )
        return TruthEvaluation(
            fields: fields,
            attentionItems: reduction.attentionItems,
            openReport: openReport
        )
    }

    private func semantic(
        for signal: String,
        originalSignal: String
    ) throws -> TruthSignalSemantic {
        if signal.contains("capability queried") {
            return .unsupported
        }
        if signal.contains("matching live process and process-start identity") {
            return .exactReturn
        }
        if signal.contains("valid synthetic thread identity")
            || signal.contains("valid synthetic session identity and project location")
            || signal.contains("synthetic chat identity candidate")
            || signal.contains("synthetic session identity candidate with no end-to-end")
            || signal.contains("synthetic identity candidate with no verified return")
        {
            return .returnUnknown
        }
        if signal.contains("application installed; no independently verified")
            || signal.contains("application installed; no verified session target")
            || (signal.contains("identity malformed")
                && signal.contains("application installed"))
        {
            return .appFallback
        }
        if signal.contains("resume unavailable") {
            return .workingDirectoryFallback
        }
        if signal.contains("bundle and cli executables present")
            || signal.contains("application bundle present")
            || signal.contains("executable and bundled documentation present")
        {
            return .discovery
        }
        if signal.contains("session_shutdown") {
            return .offline
        }
        if signal.contains("freshness expired")
            || signal.contains("expiry reached")
            || signal.contains("passes stale deadline")
            || signal.contains("ambiguous record exceeds freshness")
            || signal.contains("prior session retained")
            || signal.contains("old snapshot retained")
            || signal.contains("no fresh lifecycle evidence")
            || signal.contains("no stop or process evidence")
        {
            return .stale
        }
        if signal.contains("request resolved") {
            return .resolvedRequest
        }
        if signal.contains("permission request")
            || signal.contains("same synthetic request identity")
        {
            return .permission
        }
        if signal.contains("plan request") {
            return .planApproval
        }
        if signal.contains("question enters")
            || signal.contains("request-user-input")
            || signal.contains("new question state")
        {
            return .question
        }
        if signal.contains("tool failure followed")
            || signal.contains("tool failure; subsequent")
            || signal.contains("tool_result classified failed")
            || signal.contains("posttoolusefailure followed")
            || signal.contains("tool reports failure")
        {
            return .recoverableToolFailure
        }
        if signal.contains("terminal failed outcome")
            || signal.contains("outcome is failed")
            || signal.contains("terminal failure")
            || signal.contains("task failure")
            || signal.contains("task error")
            || signal.contains("terminal error")
        {
            return .taskFailure
        }
        if signal.contains("terminal completed outcome")
            || signal.contains("outcome is completed")
            || signal.contains("normal terminal lifecycle outcome")
            || signal.contains("classified successful")
            || signal.contains("verified successful outcome")
        {
            return .completion
        }
        if signal.contains("agent_end observed") {
            return .running
        }
        if signal.contains("no active agent")
            || signal.contains("no active turn")
            || signal.contains("sessionstart lifecycle")
            || signal.contains("sessionstart event")
            || signal.contains("session_start lifecycle")
        {
            return .idle
        }
        if signal.contains("active work")
            || signal.contains("active turn")
            || signal.contains("fresh agents snapshot")
            || signal.contains("continued agent activity")
            || signal.contains("fresh active native state")
            || signal.contains("beforeSubmitPrompt".lowercased())
            || signal.contains("userpromptsubmit")
            || signal.contains("tool lifecycle")
            || signal.contains("pretooluse")
            || signal.contains("tool_call lifecycle")
            || signal.contains("agent_start lifecycle")
        {
            return .running
        }
        throw AgentTruthReplayError.unsupportedSignal(
            agentID: agentID,
            signal: originalSignal
        )
    }

    private func isDirectClassification(
        _ semantic: TruthSignalSemantic
    ) -> Bool {
        switch semantic {
        case .appFallback, .workingDirectoryFallback, .unsupported:
            return true
        case .returnUnknown:
            return agentID == .cursor || agentID == .zcode || agentID == .pi
        default:
            return false
        }
    }

    private func directFields(
        semantic: TruthSignalSemantic,
        signal: String,
        openReport: AgentOpenReport?
    ) -> TruthFields {
        let reason = semantic == .unsupported
            && !signal.contains("terminal/process fallback")
            ? "unknown"
            : "none"
        let freshness = semantic == .unsupported
            ? "notApplicable"
            : "unknown"
        return TruthFields(
            executionState: "unknown",
            attentionReason: reason,
            actionability: actionability(
                semantic: semantic,
                signal: signal
            ).rawValue,
            evidenceQuality: evidenceQuality(
                semantic: semantic,
                signal: signal
            ).rawValue,
            freshness: freshness,
            openResult: openReport?.result.rawValue
                ?? OpenResult.notAttempted.rawValue,
            interruptDecision: "nonInterrupt"
        )
    }

    private func normalizedEvents(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) throws -> [AgentEvent] {
        switch semantic {
        case .discovery, .stale, .offline:
            return [manualEvent(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )]
        default:
            break
        }
        switch agentID {
        case .codex, .claudeCode:
            return [try taskProgressEvent(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )]
        case .cursor:
            return try cursorEvents(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )
        case .zcode:
            return try zcodeEvents(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )
        case .pi:
            return try piEvents(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )
        default:
            throw AgentTruthReplayError.invalidFixture(
                "\(scenarioID) 使用未知 Agent"
            )
        }
    }

    private func taskProgressEvent(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) throws -> AgentEvent {
        let kind: TaskProgressKind
        switch semantic {
        case .idle: kind = .idle
        case .taskFailure: kind = .failed
        case .completion, .exactReturn, .returnUnknown: kind = .completed
        case .question where agentID == .codex: kind = .waitingForInput
        default: kind = .running
        }
        let isMissingIdentity = signal.contains("identity")
            && (signal.contains("missing")
                || signal.contains("absent")
                || signal.contains("malformed"))
        if isMissingIdentity {
            return manualEvent(
                semantic: semantic,
                scenarioID: scenarioID,
                signal: signal,
                observedAt: observedAt
            )
        }
        let workingDirectory = agentID == .claudeCode
            ? "/tmp/threadhelm-truth-replay"
            : nil
        let item = TaskProgressItem(
            title: "Truth fixture",
            kind: kind,
            startedAt: observedAt,
            updatedAt: observedAt,
            source: agentID,
            threadID: agentID == .codex ? Self.nativeSessionID : nil,
            sessionID: agentID == .claudeCode ? Self.nativeSessionID : nil,
            workingDirectory: workingDirectory,
            processID: semantic == .exactReturn ? 4242 : nil,
            processStartIdentity: semantic == .exactReturn
                ? "truth-process-start"
                : nil
        )
        let queue = claudePermissionQueue(
            semantic: semantic,
            observedAt: observedAt
        )
        guard let metadata = builtInAgentMetadata().first(where: {
            $0.id == agentID
        }),
        let snapshot = agentSessionSnapshot(
            from: item,
            metadata: metadata,
            permissionQueue: queue,
            adapterVersion: adapterVersion
        ) else {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenarioID) 不能归一化任务快照"
            )
        }
        return event(
            from: snapshot,
            eventID: "\(scenarioID)-event",
            sequence: 1,
            evidenceQuality: evidenceQuality(
                semantic: semantic,
                signal: signal
            )
        )
    }

    private func claudePermissionQueue(
        semantic: TruthSignalSemantic,
        observedAt: Date
    ) -> ClaudePermissionQueueSnapshot {
        guard agentID == .claudeCode else { return .empty }
        let kind: ClaudePermissionInteractionKind
        switch semantic {
        case .permission: kind = .toolApproval
        case .question: kind = .askUserQuestion
        case .planApproval: kind = .exitPlanMode
        default: return .empty
        }
        return ClaudePermissionQueueSnapshot(
            current: ClaudePermissionQueueItem(
                requestID: Self.requestID,
                interactionKind: kind,
                title: "Truth fixture request",
                sessionID: Self.nativeSessionID,
                arrivedAt: observedAt
            ),
            pending: []
        )
    }

    private func cursorEvents(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) throws -> [AgentEvent] {
        let eventType: String
        let terminalTaskError: Bool
        switch semantic {
        case .idle:
            eventType = "sessionStart"
            terminalTaskError = false
        case .recoverableToolFailure:
            eventType = "postToolUseFailure"
            terminalTaskError = false
        case .taskFailure:
            eventType = "stop"
            terminalTaskError = true
        case .completion:
            eventType = "stop"
            terminalTaskError = false
        default:
            eventType = signal.contains("submit")
                ? "beforeSubmitPrompt"
                : "preToolUse"
            terminalTaskError = false
        }
        let missingIdentity = signal.contains("identity")
            && signal.contains("absent")
        let adapter = CursorAgentAdapter(
            discovery: { pinnedDiscovery(for: .cursor) },
            signals: {
                [CursorHookSignal(
                    eventType: eventType,
                    sessionID: missingIdentity ? nil : Self.nativeSessionID,
                    eventID: "\(scenarioID)-event",
                    sequence: 1,
                    observedAt: observedAt,
                    terminalTaskError: terminalTaskError
                )]
            },
            hookCommand: "/tmp/threadhelm-truth-replay"
        )
        return try adapter.observe().events
    }

    private func zcodeEvents(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) throws -> [AgentEvent] {
        let eventType: String
        let outcome: String?
        switch semantic {
        case .idle:
            eventType = "SessionStart"
            outcome = nil
        case .recoverableToolFailure:
            eventType = "PostToolUseFailure"
            outcome = nil
        case .taskFailure:
            eventType = "Stop"
            outcome = "failed"
        case .completion:
            eventType = "Stop"
            outcome = "success"
        default:
            eventType = signal.contains("submit")
                ? "UserPromptSubmit"
                : "PreToolUse"
            outcome = nil
        }
        let missingIdentity = signal.contains("identity")
            && signal.contains("absent")
        let envelope = ZCodeHookEnvelope(
            eventID: "\(scenarioID)-event",
            sessionID: missingIdentity ? nil : Self.nativeSessionID,
            sequence: 1,
            eventType: eventType,
            observedAt: observedAt,
            monotonicNanoseconds: 1,
            outcome: outcome
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let adapter = ZCodeAgentAdapter(
            discovery: { pinnedDiscovery(for: .zcode) },
            readEnvelopeData: { [data] },
            now: { observedAt.addingTimeInterval(1) },
            executablePath: { "/tmp/threadhelm-truth-replay" }
        )
        return try adapter.observe().events
    }

    private func piEvents(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) throws -> [AgentEvent] {
        let eventType: String
        let state: ExecutionState
        switch semantic {
        case .idle:
            eventType = "session_start"
            state = .idle
        case .taskFailure:
            eventType = "agent_settled"
            state = .failed
        case .completion:
            eventType = "agent_settled"
            state = .completed
        default:
            if signal.contains("agent_end") {
                eventType = "agent_end"
            } else if signal.contains("agent_start") {
                eventType = "agent_start"
            } else if signal.contains("tool_result") {
                eventType = "tool_result"
            } else {
                eventType = "tool_call"
            }
            state = .running
        }
        let missingIdentity = signal.contains("identity")
            && signal.contains("absent")
        let evidence = evidenceQuality(semantic: semantic, signal: signal)
        let envelope = AgentTransportEnvelope(
            agentID: .pi,
            adapterVersion: adapterVersion,
            nativeSessionCandidate: missingIdentity ? nil : Self.nativeSessionID,
            eventID: "\(scenarioID)-event",
            sequence: 1,
            eventType: eventType,
            monotonicNanoseconds: 1,
            redactedPayload: [
                "state": state.rawValue,
                "attentionReason": state == .failed
                    ? AttentionReason.taskFailure.rawValue
                    : AttentionReason.none.rawValue,
                "evidenceQuality": evidence.rawValue,
                "freshness": "fresh",
            ]
        )
        guard let event = piAgentEvent(from: envelope, observedAt: observedAt)
        else {
            throw AgentTruthReplayError.invalidFixture(
                "\(scenarioID) 不能归一化 Pi 事件"
            )
        }
        return [event]
    }

    private func manualEvent(
        semantic: TruthSignalSemantic,
        scenarioID: String,
        signal: String,
        observedAt: Date
    ) -> AgentEvent {
        let state: ExecutionState
        let reason: AttentionReason
        switch semantic {
        case .discovery:
            state = .discovering
            reason = .none
        case .stale:
            state = .stale
            reason = .none
        case .offline:
            state = .offline
            reason = .none
        case .taskFailure:
            state = .failed
            reason = .taskFailure
        default:
            state = .running
            reason = .none
        }
        let stale = semantic == .stale || semantic == .offline
        return AgentEvent(
            identity: AgentSessionIdentity(
                agentID: agentID,
                nativeID: "\(agentID.rawValue)-truth-session"
            ),
            adapterVersion: adapterVersion,
            eventID: "\(scenarioID)-event",
            sequence: 1,
            eventType: "truth-\(semantic)",
            observedAt: observedAt,
            monotonicNanoseconds: 1,
            executionState: state,
            attentionReason: reason,
            actionability: actionability(
                semantic: semantic,
                signal: signal
            ),
            evidenceQuality: evidenceQuality(
                semantic: semantic,
                signal: signal
            ),
            freshness: Freshness(
                observedAt: observedAt,
                expiresAt: stale
                    ? observedAt
                    : observedAt.addingTimeInterval(30 * 60),
                staleReason: stale ? "truth-fixture-stale" : nil
            ),
            title: "Truth fixture",
            activitySummary: nil,
            workingDirectory: agentID == .claudeCode
                && signal.contains("identity")
                ? "/tmp/threadhelm-truth-replay"
                : nil
        )
    }

    private func actionability(
        semantic: TruthSignalSemantic,
        signal: String
    ) -> Actionability {
        if semantic == .discovery || semantic == .stale
            || semantic == .offline || semantic == .unsupported
        {
            return .viewOnly
        }
        if semantic == .workingDirectoryFallback {
            return .openWorkingDirectory
        }
        if signal.contains("identity")
            && (signal.contains("absent") || signal.contains("malformed"))
        {
            switch agentID {
            case .codex, .cursor, .zcode: return .openNativeApp
            case .claudeCode: return .openWorkingDirectory
            case .pi: return .viewOnly
            default: return .viewOnly
            }
        }
        switch agentID {
        case .codex:
            return semantic == .appFallback ? .openNativeApp : .openExactNativeSession
        case .claudeCode:
            if [.permission, .question, .planApproval].contains(semantic) {
                return .inApp
            }
            return .openExactNativeSession
        case .cursor, .zcode:
            return .openNativeApp
        case .pi:
            return .viewOnly
        default:
            return .viewOnly
        }
    }

    private func evidenceQuality(
        semantic: TruthSignalSemantic,
        signal: String
    ) -> EvidenceQuality {
        if semantic == .discovery { return .processObservation }
        if semantic == .stale { return .inferred }
        if semantic == .offline { return .officialHook }
        if signal.contains("older") && semantic != .resolvedRequest {
            return .inferred
        }
        if signal.contains("identity")
            && (signal.contains("absent") || signal.contains("malformed"))
        {
            return .inferred
        }
        switch semantic {
        case .recoverableToolFailure:
            return .inferred
        case .permission, .planApproval:
            return .officialHook
        case .question:
            return agentID == .codex ? .officialAPI : .officialHook
        case .resolvedRequest:
            return .officialHook
        case .exactReturn:
            return .processObservation
        case .returnUnknown:
            switch agentID {
            case .codex, .claudeCode: return .nativeState
            case .cursor, .pi: return .officialAPI
            case .zcode: return .processObservation
            default: return .unknown
            }
        case .appFallback:
            return agentID == .codex ? .inferred : .processObservation
        case .workingDirectoryFallback:
            return .processObservation
        case .unsupported:
            if agentID == .zcode { return .officialHook }
            if signal.contains("terminal/process fallback") { return .inferred }
            return .unknown
        case .taskFailure:
            if signal.contains("twice") || signal.contains("repeated")
                || signal.contains("older") || signal.contains("restored")
            {
                return .inferred
            }
            if agentID == .claudeCode { return .transcript }
            if agentID == .codex { return .nativeState }
            return .inferred
        case .completion:
            if agentID == .claudeCode { return .transcript }
            if agentID == .codex { return .nativeState }
            return .officialHook
        case .idle, .running:
            switch agentID {
            case .codex: return .nativeState
            case .claudeCode: return .officialAPI
            case .cursor, .zcode, .pi: return .officialHook
            default: return .unknown
            }
        case .discovery, .stale, .offline:
            return .unknown
        }
    }

    private func makeOpenReport(
        semantic: TruthSignalSemantic,
        signal: String
    ) -> AgentOpenReport? {
        let result: OpenResult
        let invokedExactTarget: Bool
        let confirmed: Bool
        switch semantic {
        case .exactReturn:
            result = .exactSession
            invokedExactTarget = true
            confirmed = true
        case .returnUnknown:
            if agentID == .pi {
                result = .unavailable
                invokedExactTarget = false
            } else {
                result = .unknown
                invokedExactTarget = agentID == .codex || agentID == .claudeCode
            }
            confirmed = false
        case .appFallback:
            result = .appFocused
            invokedExactTarget = false
            confirmed = false
        case .workingDirectoryFallback:
            result = .workingDirectoryFallback
            invokedExactTarget = false
            confirmed = false
        case .unsupported:
            result = .unavailable
            invokedExactTarget = false
            confirmed = false
        case .taskFailure where signal.contains("identity")
            && (signal.contains("absent") || signal.contains("malformed")):
            switch agentID {
            case .claudeCode: result = .workingDirectoryFallback
            case .codex, .cursor, .zcode: result = .appFocused
            case .pi: result = .unavailable
            default: result = .unavailable
            }
            invokedExactTarget = false
            confirmed = false
        default:
            return nil
        }
        return AgentOpenReport(
            agentID: agentID,
            advertisedActionability: actionability(
                semantic: semantic,
                signal: signal
            ),
            result: result,
            invokedExactTarget: invokedExactTarget,
            independentlyConfirmedIdentity: confirmed
        )
    }

    private func event(
        from snapshot: AgentSessionSnapshot,
        eventID: String,
        sequence: Int,
        evidenceQuality: EvidenceQuality
    ) -> AgentEvent {
        AgentEvent(
            identity: snapshot.identity,
            adapterVersion: snapshot.adapterVersion,
            eventID: eventID,
            sequence: sequence,
            eventType: "truth-task-progress",
            observedAt: snapshot.updatedAt,
            monotonicNanoseconds: UInt64(sequence),
            executionState: snapshot.executionState,
            attentionReason: snapshot.attentionReason,
            actionability: snapshot.actionability,
            evidenceQuality: evidenceQuality,
            freshness: snapshot.freshness,
            title: snapshot.title,
            activitySummary: nil,
            workingDirectory: snapshot.workingDirectory
        )
    }

    private func olderEvent(
        than event: AgentEvent,
        semantic: TruthSignalSemantic,
        scenarioID: String
    ) -> AgentEvent {
        let reason: AttentionReason = semantic == .resolvedRequest
            ? .permission
            : .none
        let action: Actionability = semantic == .resolvedRequest
            ? .inApp
            : actionability(semantic: .running, signal: "")
        return AgentEvent(
            identity: event.identity,
            adapterVersion: event.adapterVersion,
            eventID: "\(scenarioID)-older",
            sequence: 1,
            eventType: "older-running",
            observedAt: event.observedAt.addingTimeInterval(60),
            monotonicNanoseconds: 1,
            executionState: .running,
            attentionReason: reason,
            actionability: action,
            evidenceQuality: .inferred,
            freshness: Freshness(
                observedAt: event.observedAt,
                expiresAt: event.observedAt.addingTimeInterval(30 * 60)
            ),
            title: "Truth fixture older event",
            activitySummary: nil,
            workingDirectory: nil
        )
    }

    private func copiedEvent(
        _ event: AgentEvent,
        eventID: String,
        sequence: Int
    ) -> AgentEvent {
        AgentEvent(
            identity: event.identity,
            adapterVersion: event.adapterVersion,
            eventID: eventID,
            sequence: sequence,
            eventType: event.eventType,
            observedAt: event.observedAt,
            monotonicNanoseconds: UInt64(sequence),
            executionState: event.executionState,
            attentionReason: event.attentionReason,
            actionability: event.actionability,
            evidenceQuality: event.evidenceQuality,
            freshness: event.freshness,
            title: event.title,
            activitySummary: event.activitySummary,
            workingDirectory: event.workingDirectory
        )
    }
}

private func pinnedDiscovery(for agentID: AgentID) -> AgentDiscovery {
    let profile = builtInAgentValidationProfiles()[agentID]
    return versionValidatedAgentDiscovery(
        agentID: agentID,
        isInstalled: true,
        components: profile?.testedVersionComponents ?? []
    )
}

private func decodeTruthFixture<T: Decodable>(
    _ type: T.Type,
    at url: URL
) throws -> T {
    do {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw AgentTruthReplayError.invalidFixture(
            "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"
        )
    }
}

private func truthFixtureChildURL(
    _ relativePath: String,
    root: URL
) -> URL? {
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains("..")
    else { return nil }
    let candidate = root.appendingPathComponent(relativePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(root.path + "/") else { return nil }
    return candidate
}

private func verifyPinnedFixtureVersion(
    _ version: TruthVersion,
    agentID: AgentID,
    profile: AgentValidationProfile
) throws {
    let components: [AgentVersionComponent]
    switch agentID {
    case .cursor:
        components = [
            AgentVersionComponent(
                key: "desktop",
                label: "Desktop",
                value: version.version
            ),
            version.agentCliVersion.map {
                AgentVersionComponent(
                    key: "agentCLI",
                    label: "Agent CLI",
                    value: $0
                )
            },
        ].compactMap { $0 }
    case .zcode:
        components = [
            AgentVersionComponent(
                key: "version",
                label: "Version",
                value: version.version
            ),
            version.build.map {
                AgentVersionComponent(
                    key: "build",
                    label: "build",
                    value: $0
                )
            },
        ].compactMap { $0 }
    default:
        components = [AgentVersionComponent(
            key: "version",
            label: "Version",
            value: version.version
        )]
    }
    let discovery = versionValidatedAgentDiscovery(
        agentID: agentID,
        isInstalled: true,
        components: components
    )
    guard discovery.compatibility == .validated,
          components == profile.testedVersionComponents
    else {
        throw AgentTruthReplayError.invalidFixture(
            "\(agentID.rawValue) 夹具版本不等于固定验证版本"
        )
    }
}

private func compareTruthFields(
    scenarioID: String,
    expected: TruthFields,
    actual: TruthFields
) throws {
    let fields: [(String, String, String)] = [
        ("executionState", expected.executionState, actual.executionState),
        ("attentionReason", expected.attentionReason, actual.attentionReason),
        ("actionability", expected.actionability, actual.actionability),
        ("evidenceQuality", expected.evidenceQuality, actual.evidenceQuality),
        ("freshness", expected.freshness, actual.freshness),
        ("openResult", expected.openResult, actual.openResult),
        ("interruptDecision", expected.interruptDecision, actual.interruptDecision),
    ]
    if let mismatch = fields.first(where: { $0.1 != $0.2 }) {
        throw AgentTruthReplayError.mismatch(
            scenarioID: scenarioID,
            field: mismatch.0,
            expected: mismatch.1,
            actual: mismatch.2
        )
    }
}

private extension ISO8601DateFormatter {
    static let truthFixture: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
