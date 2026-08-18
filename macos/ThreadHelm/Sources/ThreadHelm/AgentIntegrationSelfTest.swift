//
//  AgentIntegrationSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁定五 Agent 公共核心、确定性事件归并和本地传输边界。
//

import Foundation

private struct SixthAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata

    init(displayName: String = "Mock Sixth") {
        metadata = AgentMetadata(
            id: AgentID(rawValue: "mockSixth"),
            displayName: displayName,
            shortName: "Mock",
            iconResourceName: "ProviderIcon-mock",
            fallbackSymbolName: "puzzlepiece.extension",
            brandColor: AgentColorComponents(red: 0.5, green: 0.5, blue: 0.5),
            versionSource: "self-test",
            identityPolicy: "synthetic-test-id",
            capabilities: AgentCapabilitySet(
                supported: [.lifecycleObservation],
                unknown: [.stableIdentity, .exactReturn]
            )
        )
    }
}

private enum AgentIntegrationSelfTestError: Error {
    case unavailable
}

func runAgentIntegrationSelfTest() {
    let expectedBuiltIns: [AgentID] = [
        .codex,
        .claudeCode,
        .cursor,
        .zcode,
        .omp,
    ]
    guard AgentID.builtInOrder == expectedBuiltIns,
          expectedBuiltIns.map(\.rawValue) == [
              "codex", "claudeCode", "cursor", "zcode", "omp",
          ]
    else {
        failAgentIntegrationSelfTest("built-in IDs/order")
    }

    let mock = SixthAgentAdapter()
    let duplicate = SixthAgentAdapter(displayName: "Duplicate must lose")
    let registry = AgentRegistry(
        adapters: builtInAgentAdapters() + [mock, duplicate]
    )
    guard registry.agentIDs == expectedBuiltIns + [mock.metadata.id],
          registry.adapter(for: mock.metadata.id)?.metadata.displayName
              == "Mock Sixth",
          registry.count == 6
    else {
        failAgentIntegrationSelfTest("registry extension/deduplication")
    }

    let runtimePlaceholders = agentRuntimeStatusPlaceholders(registry: registry)
    let runtimeNow = Date(timeIntervalSince1970: 1_786_500_000)
    let runtimeIdentity = AgentSessionIdentity(
        agentID: mock.metadata.id,
        nativeID: "mock-runtime-session"
    )
    let runtimeSnapshot = AgentSessionSnapshot(
        identity: runtimeIdentity,
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .question,
        actionability: .viewOnly,
        evidenceQuality: .nativeState,
        freshness: Freshness(observedAt: runtimeNow, expiresAt: nil),
        title: "Mock runtime",
        activitySummary: nil,
        workingDirectory: nil,
        latestEventID: "mock-runtime-event",
        updatedAt: runtimeNow
    )
    let runtimeAttention = AgentAttentionItem(
        identity: runtimeIdentity,
        reason: .question,
        actionability: .viewOnly,
        evidenceQuality: .nativeState,
        updatedAt: runtimeNow,
        // Dashboard totals describe unresolved hard-attention work, not
        // whether the interruption gate emitted another notification.
        isInterrupting: false
    )
    let inferredBlockedAttention = AgentAttentionItem(
        identity: runtimeIdentity,
        reason: .blocked,
        actionability: .viewOnly,
        evidenceQuality: .inferred,
        updatedAt: runtimeNow,
        // Exercise the policy boundary independently from any stale producer
        // flag: inferred blocked state is not verified hard attention.
        isInterrupting: true
    )
    let runtimeStatuses = agentRuntimeStatusesWithActivity(
        runtimePlaceholders,
        snapshots: [runtimeSnapshot],
        attentionItems: [runtimeAttention, inferredBlockedAttention]
    )
    guard runtimePlaceholders.count == registry.count,
          runtimePlaceholders.first(where: {
              $0.metadata.id == mock.metadata.id
          })?.integrationStatus == .notManaged,
          runtimeStatuses.first(where: {
              $0.metadata.id == mock.metadata.id
          })?.activeSessionCount == 1,
          runtimeStatuses.first(where: {
              $0.metadata.id == mock.metadata.id
          })?.attentionCount == 1
    else {
        failAgentIntegrationSelfTest("runtime health placeholders/activity")
    }
    let mergedIntegrationStatuses = agentRuntimeStatusesMergingIntegration(
        runtimePlaceholders,
        report: AgentIntegrationRunReport(
            operation: .status,
            backupID: nil,
            restoredBackupID: nil,
            rolledBack: false,
            agents: [
                AgentIntegrationRunRecord(
                    agentID: .cursor,
                    statusBefore: .notInstalled,
                    result: nil,
                    statusAfter: .notInstalled
                )
            ]
        )
    )
    guard mergedIntegrationStatuses.first(where: {
        $0.metadata.id == .cursor
    })?.integrationStatus == .notInstalled
    else {
        failAgentIntegrationSelfTest("runtime integration status merge")
    }

    for id in expectedBuiltIns {
        guard let metadata = registry.metadata(for: id),
              !metadata.displayName.isEmpty,
              !metadata.shortName.isEmpty,
              !metadata.iconResourceName.isEmpty,
              !metadata.fallbackSymbolName.isEmpty,
              !metadata.versionSource.isEmpty,
              !metadata.identityPolicy.isEmpty
        else {
            failAgentIntegrationSelfTest("metadata completeness for \(id.rawValue)")
        }
    }

    guard registry.metadata(for: .omp)?.capabilities.status(
        for: .lifecycleObservation
    ) == .supported,
          registry.metadata(for: .omp)?.capabilities.status(
              for: .nativeNavigation
          ) == .supported,
          registry.metadata(for: .omp)?.capabilities.status(
              for: .inAppPermission
          ) == .unsupported,
          registry.metadata(for: .omp)?.capabilities.status(
              for: .exactReturn
          ) == .unknown,
          registry.metadata(for: .cursor)?.capabilities.status(
              for: .exactReturn
          ) == .unknown,
          registry.metadata(for: .zcode)?.capabilities.status(
              for: .exactReturn
          ) == .unknown,
          registry.metadata(for: .codex)?.capabilities.status(
              for: .managedIntegration
          ) == .unsupported,
          [.claudeCode, .cursor, .zcode, .omp].allSatisfy({ agentID in
              registry.metadata(for: agentID)?.capabilities.status(
                  for: .managedIntegration
              ) == .supported
          })
    else {
        failAgentIntegrationSelfTest("navigation/control capability boundary")
    }

    guard QuotaProvider.allCases.map(\.rawValue) == ["codex", "claudeCode"]
    else {
        failAgentIntegrationSelfTest("quota providers remain independent")
    }

    guard TaskSourceFilter.options(for: AgentID.builtInOrder).map(\.rawValue)
        == ["all", "codex", "claudeCode", "cursor", "zcode", "omp"],
          TaskSourceFilter(agentID: mock.metadata.id).agentID == mock.metadata.id
    else {
        failAgentIntegrationSelfTest("source-agnostic filters")
    }

    runAgentTaskProgressRegistrySelfTest(mockAgentID: mock.metadata.id)
    runAgentReducerSelfTest()
    runAgentHookCommandSelfTest()
    runAgentLiveEventStoreSelfTest()
    runAgentAttentionPolicySelfTest()
    guard runAgentEventSocketSelfTest() else {
        failAgentIntegrationSelfTest("owner-only event socket")
    }
    runCursorAgentAdapterSelfTest()
    runZCodeAgentAdapterSelfTest()
    runOMPAgentAdapterSelfTest()
    runCodexClaudeAdapterSelfTest()
    runAgentVersionTruthSelfTest()
    runAgentOpenMeasurementSelfTest()
    runAgentAttentionFeedbackSelfTest()
    runClaudeAdapterLifecycleSelfTest()
    runAgentIntegrationManagerSelfTest()
}

private func runAgentVersionTruthSelfTest() {
    let profiles = builtInAgentValidationProfiles()
    let cursorPinned = versionValidatedAgentDiscovery(
        agentID: .cursor,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "desktop", label: "Desktop", value: "3.15.19"),
            AgentVersionComponent(
                key: "agentCLI",
                label: "Agent CLI",
                value: "2026.04.15-dccdccd"
            ),
        ]
    )
    let cursorDrifted = versionValidatedAgentDiscovery(
        agentID: .cursor,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "desktop", label: "Desktop", value: "3.15.6"),
            AgentVersionComponent(
                key: "agentCLI",
                label: "Agent CLI",
                value: "2026.04.15-dccdccd"
            ),
        ]
    )
    let cursorMissingCLI = versionValidatedAgentDiscovery(
        agentID: .cursor,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "desktop", label: "Desktop", value: "3.15.19"),
        ]
    )
    let zcodePinned = versionValidatedAgentDiscovery(
        agentID: .zcode,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "version", label: "Version", value: "3.7.6"),
            AgentVersionComponent(key: "build", label: "build", value: "3.7.6.4691"),
        ]
    )
    let zcodeDriftedBuild = versionValidatedAgentDiscovery(
        agentID: .zcode,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "version", label: "Version", value: "3.7.6"),
            AgentVersionComponent(key: "build", label: "build", value: "3.7.6.5000"),
        ]
    )
    let codexPinned = versionValidatedAgentDiscovery(
        agentID: .codex,
        isInstalled: true,
        components: [
            AgentVersionComponent(key: "version", label: "Version", value: "0.145.0"),
        ]
    )
    let codexMetadata = builtInAgentMetadata().first { $0.id == .codex }
    let ompMetadata = builtInAgentMetadata().first { $0.id == .omp }
    let driftedCodexAdapter = CodexAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: {
            versionValidatedAgentDiscovery(
                agentID: .codex,
                isInstalled: true,
                components: [
                    AgentVersionComponent(
                        key: "version",
                        label: "Version",
                        value: "0.146.0"
                    ),
                ]
            )
        },
        openURL: { _ in true }
    )
    let driftedCodexStatus = probedAgentRuntimeStatuses(
        registry: AgentRegistry(adapters: [driftedCodexAdapter])
    ).first

    guard Set(profiles.keys) == Set(AgentID.builtInOrder),
          cursorPinned.compatibility == .validated,
          cursorPinned.version == "3.15.19",
          cursorPinned.versionComponents.map(\.key) == ["desktop", "agentCLI"],
          cursorDrifted.compatibility == .unvalidated,
          cursorMissingCLI.compatibility == .unvalidated,
          zcodePinned.compatibility == .validated,
          zcodePinned.versionComponents.map(\.value) == ["3.7.6", "3.7.6.4691"],
          zcodeDriftedBuild.compatibility == .unvalidated,
          codexPinned.compatibility == .validated,
          profiles[.codex]?.effectiveCapabilities(
              metadata: codexMetadata!,
              discovery: versionValidatedAgentDiscovery(
                  agentID: .codex,
                  isInstalled: true,
                  components: [
                      AgentVersionComponent(
                          key: "version",
                          label: "Version",
                          value: "0.146.0"
                      ),
                  ]
              )
          ).status(for: .lifecycleObservation) == .unknown,
          driftedCodexStatus?.discovery.compatibility == .unvalidated,
          driftedCodexStatus?.metadata.capabilities.status(
              for: .lifecycleObservation
          ) == .unknown,
          driftedCodexStatus?.metadata.capabilities.status(
              for: .nativeNavigation
          ) == .unknown,
          driftedCodexStatus?.metadata.capabilities.status(
              for: .managedIntegration
          ) == .unsupported,
          codexMetadata?.capabilities.status(for: .exactReturn) == .unknown,
          ompMetadata?.capabilities.status(for: .exactReturn) == .unknown,
          normalizedAgentVersion(from: "codex-cli 0.145.0") == "0.145.0",
          normalizedAgentVersion(from: "2.1.226 (Claude Code)") == "2.1.226",
          normalizedAgentVersion(from: "2026.04.14-ee4b43a")
            == "2026.04.14-ee4b43a"
    else {
        failAgentIntegrationSelfTest("version-pinned validation and drift downgrade")
    }
}

private func runCodexClaudeAdapterSelfTest() {
    let now = Date(timeIntervalSince1970: 1_786_500_500)
    let codexThreadID = "e1653f97-f01e-4215-a4fd-c8f70e7e3235"
    let codexTask = TaskProgressItem(
        title: "Codex needs input",
        kind: .waitingForInput,
        startedAt: now.addingTimeInterval(-30),
        updatedAt: now,
        source: .codex,
        threadID: codexThreadID,
        workingDirectory: "/tmp/threadhelm-codex"
    )
    var openedCodexURL: URL?
    let validatedCodexDiscovery: () -> AgentDiscovery = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .validated
        )
    }
    let codex = CodexAgentAdapter(
        readCollection: { .displaying([codexTask]) },
        discovery: validatedCodexDiscovery,
        openURL: {
            openedCodexURL = $0
            return true
        }
    )
    guard let codexObservation = try? codex.observe(),
          let codexSnapshot = codexObservation.snapshots.first
    else {
        failAgentIntegrationSelfTest("Codex adapter observation")
    }
    let codexReport = codex.open(session: codexSnapshot)
    var driftedCodexOpenCallCount = 0
    let driftedCodexReport = CodexAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: {
            versionValidatedAgentDiscovery(
                agentID: .codex,
                isInstalled: true,
                components: [
                    AgentVersionComponent(
                        key: "version",
                        label: "Version",
                        value: "0.146.0"
                    ),
                ]
            )
        },
        openURL: { _ in
            driftedCodexOpenCallCount += 1
            return true
        }
    ).open(session: codexSnapshot)
    let failedCodexReport = CodexAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: validatedCodexDiscovery,
        openURL: { _ in false }
    ).open(session: codexSnapshot)
    guard codexSnapshot.identity.agentID == .codex,
          codexSnapshot.identity.nativeID == codexThreadID,
          codexSnapshot.executionState == .running,
          codexSnapshot.attentionReason == .question,
          codexSnapshot.actionability == .openExactNativeSession,
          codexSnapshot.workingDirectory == "/tmp/threadhelm-codex",
          codexReport.advertisedActionability == .openExactNativeSession,
          codexReport.result == .unknown,
          codexReport.exactAttempted,
          !codexReport.independentlyConfirmedIdentity,
          driftedCodexReport.result == .unknown,
          driftedCodexReport.exactAttempted,
          !driftedCodexReport.independentlyConfirmedIdentity,
          driftedCodexOpenCallCount == 1,
          failedCodexReport.result == .failed,
          failedCodexReport.exactAttempted,
          !failedCodexReport.independentlyConfirmedIdentity,
          openedCodexURL?.absoluteString == "codex://threads/\(codexThreadID)"
    else {
        failAgentIntegrationSelfTest("Codex adapter projection/open")
    }

    let claudeSessionID = "2d61280e-b4f1-4db7-a326-19f9f0dd804c"
    let claudeTask = TaskProgressItem(
        title: "Claude needs a choice",
        kind: .waitingForInput,
        startedAt: now.addingTimeInterval(-20),
        updatedAt: now,
        source: .claudeCode,
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/threadhelm-claude"
    )
    let queue = ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
        requestID: UUID(uuidString: "f7e5c36f-f367-4457-b6af-2f46c6fc05df")!,
        interactionKind: .askUserQuestion,
        title: "Choose",
        sessionID: claudeSessionID,
        arrivedAt: now
    ))
    var openedClaudeRequest: ClaudeTerminalOpenRequest?
    let validatedClaudeDiscovery: () -> AgentDiscovery = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .validated
        )
    }
    let claude = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([claudeTask]) },
        permissionQueue: { queue },
        discovery: validatedClaudeDiscovery,
        openTerminal: {
            openedClaudeRequest = $0
            return .workingDirectoryFallback
        }
    )
    guard let claudeObservation = try? claude.observe(),
          let claudeSnapshot = claudeObservation.snapshots.first
    else {
        failAgentIntegrationSelfTest("Claude adapter observation")
    }
    let claudeReport = claude.open(session: claudeSnapshot)
    var driftedClaudeGateBodyCallCount = 0
    var driftedClaudeTerminalOpenCallCount = 0
    let driftedClaude = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: {
            versionValidatedAgentDiscovery(
                agentID: .claudeCode,
                isInstalled: true,
                components: [
                    AgentVersionComponent(
                        key: "version",
                        label: "Version",
                        value: "2.1.227"
                    ),
                ]
            )
        },
        openTerminal: { _ in
            driftedClaudeTerminalOpenCallCount += 1
            return .unknown
        }
    )
    let driftedClaudeReport = driftedClaude.openSessionIfInstalled(
        session: claudeSnapshot
    ) {
        driftedClaudeGateBodyCallCount += 1
        return driftedClaude.openValidated(session: claudeSnapshot)
    }
    let nativeOnlyClaudeSnapshot = try? ClaudeCodeAgentAdapter(
        readCollection: { .displaying([claudeTask]) },
        permissionQueue: { .empty },
        openTerminal: { _ in .unknown }
    ).observe().snapshots.first
    guard claudeSnapshot.identity.agentID == .claudeCode,
          claudeSnapshot.executionState == .running,
          claudeSnapshot.attentionReason == .question,
          claudeSnapshot.actionability == .inApp,
          claudeReport.result == .workingDirectoryFallback,
          claudeReport.advertisedActionability == .inApp,
          !claudeReport.exactAttempted,
          !claudeReport.independentlyConfirmedIdentity,
          driftedClaudeReport.result == .unknown,
          !driftedClaudeReport.exactAttempted,
          !driftedClaudeReport.independentlyConfirmedIdentity,
          driftedClaudeGateBodyCallCount == 1,
          driftedClaudeTerminalOpenCallCount == 1,
          nativeOnlyClaudeSnapshot?.attentionReason == .question,
          nativeOnlyClaudeSnapshot?.actionability
            == .openExactNativeSession,
          openedClaudeRequest?.sessionID == claudeSessionID,
          openedClaudeRequest?.workingDirectory == "/tmp/threadhelm-claude",
          claudeAttentionReason(for: .toolApproval) == .permission,
          claudeAttentionReason(for: .askUserQuestion) == .question,
          claudeAttentionReason(for: .exitPlanMode) == .planApproval
    else {
        failAgentIntegrationSelfTest("Claude adapter projection/open/actions")
    }

    let queueOnlyRequestID = UUID(
        uuidString: "bf54f333-c99c-483f-a308-8e049bbb3188"
    )!
    let queueOnly = ClaudePermissionQueueSnapshot(current: ClaudePermissionQueueItem(
        requestID: queueOnlyRequestID,
        interactionKind: .exitPlanMode,
        title: "Review the plan",
        sessionID: nil,
        arrivedAt: now.addingTimeInterval(1)
    ))
    let normalizedQueueOnly = normalizedBuiltInAgentState(
        collection: .displaying([]),
        permissionQueue: queueOnly
    )
    guard normalizedQueueOnly.snapshots.count == 1,
          normalizedQueueOnly.snapshots.first?.identity.agentID == .claudeCode,
          normalizedQueueOnly.snapshots.first?.attentionReason == .planApproval,
          normalizedQueueOnly.snapshots.first?.actionability == .inApp,
          normalizedQueueOnly.snapshots.first?.evidenceQuality == .officialHook,
          normalizedQueueOnly.attentionItems.count == 1,
          normalizedQueueOnly.attentionItems.first?.isInterrupting == true
    else {
        failAgentIntegrationSelfTest("queue-only normalized attention")
    }

    let exactProcess = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: 42,
            processStartIdentity: "self-test-start"
        ),
        focusProcess: { _, _ in .exactSession },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in false }
    )
    let resumeRequested = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: nil
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in true },
        focusWorkingDirectory: { _ in false }
    )
    let directoryFallback = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: nil,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: nil
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in true }
    )
    let resumeFailureDirectoryFallback = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: nil
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in true }
    )
    let reusedPIDDirectoryFallback = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: 42,
            processStartIdentity: "old-process-start"
        ),
        focusProcess: { processID, processStartIdentity in
            processID == 42 && processStartIdentity == "old-process-start"
                ? .failed
                : .exactSession
        },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in true }
    )
    let deadProcessResumeRequested = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: 42,
            processStartIdentity: "dead-process-start"
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in true },
        focusWorkingDirectory: { _ in false }
    )
    let failed = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/threadhelm-claude",
            processID: nil
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in false }
    )
    let unavailable = claudeTerminalOpenResult(
        for: ClaudeTerminalOpenRequest(
            sessionID: nil,
            workingDirectory: nil,
            processID: nil
        ),
        focusProcess: { _, _ in .failed },
        resumeSession: { _, _ in false },
        focusWorkingDirectory: { _ in false }
    )
    guard exactProcess == .exactSession,
          resumeRequested == .unknown,
          directoryFallback == .workingDirectoryFallback,
          resumeFailureDirectoryFallback == .workingDirectoryFallback,
          reusedPIDDirectoryFallback == .workingDirectoryFallback,
          deadProcessResumeRequested == .unknown,
          failed == .failed,
          unavailable == .unavailable
    else {
        failAgentIntegrationSelfTest("typed Claude navigation results")
    }

    let exactClaudeSnapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .claudeCode,
            nativeID: claudeSessionID,
            processID: 42,
            processStartIdentity: "self-test-start"
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openExactNativeSession,
        evidenceQuality: .processObservation,
        freshness: Freshness(observedAt: now, expiresAt: nil),
        title: "Claude exact",
        activitySummary: nil,
        workingDirectory: "/tmp/threadhelm-claude",
        latestEventID: "claude-exact",
        updatedAt: now
    )
    let exactClaudeReport = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: validatedClaudeDiscovery,
        openTerminal: { _ in .exactSession }
    ).open(session: exactClaudeSnapshot)
    let resumeClaudeSnapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .claudeCode,
            nativeID: claudeSessionID
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openExactNativeSession,
        evidenceQuality: .nativeState,
        freshness: Freshness(observedAt: now, expiresAt: nil),
        title: "Claude resume",
        activitySummary: nil,
        workingDirectory: "/tmp/threadhelm-claude",
        latestEventID: "claude-resume",
        updatedAt: now
    )
    let resumeClaudeReport = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: validatedClaudeDiscovery,
        openTerminal: { _ in .unknown }
    ).open(session: resumeClaudeSnapshot)
    let missingProcessStartSnapshot = AgentSessionSnapshot(
        identity: AgentSessionIdentity(
            agentID: .claudeCode,
            nativeID: claudeSessionID,
            processID: 42,
            processStartIdentity: nil
        ),
        adapterVersion: "self-test",
        executionState: .running,
        attentionReason: .none,
        actionability: .openExactNativeSession,
        evidenceQuality: .processObservation,
        freshness: Freshness(observedAt: now, expiresAt: nil),
        title: "Claude incomplete process identity",
        activitySummary: nil,
        workingDirectory: "/tmp/threadhelm-claude",
        latestEventID: "claude-incomplete-process",
        updatedAt: now
    )
    let missingProcessStartReport = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: validatedClaudeDiscovery,
        openTerminal: { _ in .exactSession }
    ).open(session: missingProcessStartSnapshot)
    guard exactClaudeReport.result == .exactSession,
          exactClaudeReport.exactAttempted,
          exactClaudeReport.independentlyConfirmedIdentity,
          resumeClaudeReport.result == .unknown,
          resumeClaudeReport.exactAttempted,
          !resumeClaudeReport.independentlyConfirmedIdentity,
          missingProcessStartReport.result == .unknown,
          missingProcessStartReport.exactAttempted,
          !missingProcessStartReport.independentlyConfirmedIdentity
    else {
        failAgentIntegrationSelfTest("Claude exact identity confirmation")
    }
}

private func runClaudeAdapterLifecycleSelfTest() {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-claude-adapter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let settingsURL = temporaryRoot
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")
    let isolatedScope = AgentIntegrationScope.isolated(at: temporaryRoot)
    let adapter = ClaudeCodeAgentAdapter(
        readCollection: { .displaying([]) },
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "self-test",
                compatibility: .supported
            )
        }
    )

    do {
        try manager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unrelatedSettings = """
        {
          "env": {"THREADHELM_SELF_TEST": "keep"},
          "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "keep-me"}]}]
          },
          "model": "self-test-model"
        }
        """
        try Data(unrelatedSettings.utf8).write(to: settingsURL)

        guard adapter.integrationStatus(in: isolatedScope) == .notInstalled,
              try adapter.installIntegration(in: isolatedScope) == .installed,
              adapter.integrationStatus(in: isolatedScope) == .installed,
              try adapter.installIntegration(in: isolatedScope) == .unchanged
        else {
            failAgentIntegrationSelfTest("Claude adapter install/status/idempotency")
        }

        let repairFixture = """
        {
          "env": {"THREADHELM_SELF_TEST": "keep"},
          "hooks": {
            "PermissionRequest": [{
              "matcher": "",
              "hooks": [{
                "type": "http",
                "url": "http://127.0.0.1:27841/threadhelm/claude/permission",
                "timeout": 1,
                "headers": {}
              }]
            }],
            "Stop": [{"hooks": [{"type": "command", "command": "keep-me"}]}]
          },
          "model": "self-test-model"
        }
        """
        try Data(repairFixture.utf8).write(to: settingsURL)
        guard adapter.integrationStatus(in: isolatedScope) == .notInstalled,
              try adapter.repairIntegration(in: isolatedScope) == .repaired,
              adapter.integrationStatus(in: isolatedScope) == .installed,
              try adapter.uninstallIntegration(in: isolatedScope) == .uninstalled,
              try adapter.uninstallIntegration(in: isolatedScope) == .unchanged,
              adapter.integrationStatus(in: isolatedScope) == .notInstalled,
              let finalData = try? Data(contentsOf: settingsURL),
              let finalSettings = try JSONSerialization.jsonObject(
                  with: finalData
              ) as? [String: Any],
              finalSettings["model"] as? String == "self-test-model",
              (finalSettings["env"] as? [String: String])?[
                  "THREADHELM_SELF_TEST"
              ] == "keep",
              let finalHooks = finalSettings["hooks"] as? [String: Any],
              finalHooks["Stop"] != nil,
              finalHooks["PermissionRequest"] == nil
        else {
            failAgentIntegrationSelfTest(
                "Claude adapter repair/uninstall/config preservation"
            )
        }

        let liveHomeScope = AgentIntegrationScope.isolated(
            at: manager.homeDirectoryForCurrentUser
        )
        do {
            _ = try adapter.installIntegration(in: liveHomeScope)
            failAgentIntegrationSelfTest("Claude live-home write guard")
        } catch AgentIntegrationError.liveConfigurationWriteDenied {
        } catch {
            failAgentIntegrationSelfTest("Claude live-home guard error type")
        }

        // Inspecting the live home configuration is not a mutation: the write
        // guard must not turn a read-only status probe into a failure that the
        // dashboard would then misreport as repairable drift.
        guard let liveReadURL = try? liveHomeScope.managedURL(
            relativePath: ".claude/settings.json",
            for: .read
        ), liveReadURL.path.hasSuffix("/.claude/settings.json"),
        (try? liveHomeScope.managedURL(
            relativePath: ".claude/settings.json",
            for: .write
        )) == nil
        else {
            failAgentIntegrationSelfTest("live-home read must survive write guard")
        }

        guard agentIntegrationStatusForFailedProbe(
            AgentIntegrationError.liveConfigurationWriteDenied
        ) == .checkFailed,
        agentIntegrationStatusForFailedProbe(
            AgentIntegrationError.invalidManagedPath
        ) == .checkFailed,
        agentIntegrationStatusForFailedProbe(
            ClaudeHookConfigurationError.invalidSettings
        ) == .needsRepair
        else {
            failAgentIntegrationSelfTest("probe failure classification")
        }

        let unavailableRoot = temporaryRoot.appendingPathComponent(
            "claude-unavailable",
            isDirectory: true
        )
        let unavailableSettingsURL = unavailableRoot
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
        let unavailableAdapter = ClaudeCodeAgentAdapter(
            readCollection: { .displaying([]) },
            discovery: {
                AgentDiscovery(
                    isInstalled: false,
                    version: nil,
                    compatibility: .unknown
                )
            }
        )
        guard try unavailableAdapter.installIntegration(
            in: .isolated(at: unavailableRoot)
        ) == .unchanged,
        try unavailableAdapter.repairIntegration(
            in: .isolated(at: unavailableRoot)
        ) == .unchanged,
        !manager.fileExists(atPath: unavailableSettingsURL.path)
        else {
            failAgentIntegrationSelfTest(
                "Claude unavailable install/repair must not write"
            )
        }
    } catch {
        failAgentIntegrationSelfTest(
            "Claude adapter lifecycle: \(error.localizedDescription)"
        )
    }

    try? manager.removeItem(at: temporaryRoot)
}

private func runAgentTaskProgressRegistrySelfTest(mockAgentID: AgentID) {
    let now = Date(timeIntervalSince1970: 1_786_500_000)
    var mockShouldFail = false
    var codexTitle = "Codex first"
    let registry = AgentTaskProgressRegistry(sources: [
        AgentTaskProgressSource(agentID: mockAgentID) {
            if mockShouldFail { throw AgentIntegrationSelfTestError.unavailable }
            return [TaskProgressItem(
                title: "Sixth source",
                kind: .running,
                startedAt: now,
                source: mockAgentID,
                threadID: "mock-session"
            )]
        },
        AgentTaskProgressSource(agentID: .codex) {
            [TaskProgressItem(
                title: codexTitle,
                kind: .running,
                startedAt: now,
                source: .codex,
                threadID: "codex-session"
            )]
        },
        AgentTaskProgressSource(agentID: mockAgentID) {
            throw AgentIntegrationSelfTestError.unavailable
        },
    ])
    let first = registry.readCollection()
    mockShouldFail = true
    codexTitle = "Codex second"
    let second = registry.readCollection()
    guard registry.agentIDs == [.codex, mockAgentID],
          Set(first.items.map(\.source)) == Set([.codex, mockAgentID]),
          Set(second.items.map(\.source)) == Set([.codex, mockAgentID]),
          second.items.contains(where: { $0.title == "Codex second" }),
          second.items.contains(where: { $0.title == "Sixth source" })
    else {
        failAgentIntegrationSelfTest("task registry extension/fail-open")
    }

    let navigableItems = [
        TaskProgressItem(
            title: "Codex navigation",
            kind: .running,
            startedAt: now,
            source: .codex,
            threadID: "11111111-1111-4111-8111-111111111111"
        ),
        TaskProgressItem(
            title: "Claude navigation",
            kind: .running,
            startedAt: now,
            source: .claudeCode,
            sessionID: "22222222-2222-4222-8222-222222222222",
            workingDirectory: "/tmp/threadhelm-claude"
        ),
        TaskProgressItem(
            title: "Cursor navigation",
            kind: .running,
            startedAt: now,
            source: .cursor,
            sessionID: "cursor-navigation"
        ),
        TaskProgressItem(
            title: "ZCode navigation",
            kind: .running,
            startedAt: now,
            source: .zcode,
            sessionID: "zcode-navigation"
        ),
        TaskProgressItem(
            title: "OMP navigation",
            kind: .running,
            startedAt: now,
            source: .omp,
            sessionID: "omp-navigation"
        ),
    ]
    guard navigableItems.allSatisfy(\.canOpen),
          navigableItems.map(\.openButtonTitle) == [
              "打开 Codex",
              "回到终端",
              "打开 Cursor",
              "打开 ZCode",
              "打开 OMP",
          ],
          AgentRegistry.builtIn.metadata(for: .omp).flatMap({ metadata in
              agentSessionSnapshot(
                  from: navigableItems[4],
                  metadata: metadata
              )
          })?.actionability == .openExactNativeSession
    else {
        failAgentIntegrationSelfTest("all built-in tasks expose navigation")
    }

    let duplicateRunning = TaskProgressItem(
        title: "Same identity",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        source: .cursor,
        sessionID: "cursor-candidate"
    )
    let duplicateWaiting = TaskProgressItem(
        title: "Same identity",
        kind: .waitingForInput,
        startedAt: now,
        updatedAt: now,
        source: .cursor,
        sessionID: "cursor-candidate"
    )
    let forward = TaskProgressCollectionSnapshot.displaying([
        duplicateRunning,
        duplicateWaiting,
    ])
    let reverse = TaskProgressCollectionSnapshot.displaying([
        duplicateWaiting,
        duplicateRunning,
    ])
    guard forward == reverse,
          forward.items.map(\.kind) == [.waitingForInput]
    else {
        failAgentIntegrationSelfTest("deterministic task snapshot deduplication")
    }

    let openAllowed = TaskProgressItem(
        title: "Same open policy identity",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        source: .codex,
        threadID: "codex-open-policy",
        allowsAgentOpen: true
    )
    let openDenied = TaskProgressItem(
        title: "Same open policy identity",
        kind: .running,
        startedAt: now,
        updatedAt: now,
        source: .codex,
        threadID: "codex-open-policy",
        allowsAgentOpen: false
    )
    let allowedFirst = TaskProgressCollectionSnapshot.displaying([
        openAllowed,
        openDenied,
    ])
    let deniedFirst = TaskProgressCollectionSnapshot.displaying([
        openDenied,
        openAllowed,
    ])
    guard allowedFirst == deniedFirst,
          allowedFirst.items.first?.canOpen == false
    else {
        failAgentIntegrationSelfTest(
            "deterministic task open policy must prefer view-only"
        )
    }
}

private func runAgentReducerSelfTest() {
    let base = Date(timeIntervalSince1970: 1_786_500_000)
    let codexIdentity = AgentSessionIdentity(
        agentID: .codex,
        nativeID: "codex-session"
    )
    let oldRunning = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-running",
        sequence: 1,
        observedAt: base,
        state: .running
    )
    let newerWaiting = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-waiting",
        sequence: 2,
        observedAt: base.addingTimeInterval(1),
        state: .running,
        reason: .question,
        actionability: .openExactNativeSession
    )

    let inOrder = AgentEventReducer.reduce(events: [
        oldRunning,
        oldRunning,
        newerWaiting,
    ])
    let outOfOrder = AgentEventReducer.reduce(events: [
        newerWaiting,
        oldRunning,
        oldRunning,
    ])
    guard inOrder == outOfOrder,
          inOrder.processedEventCount == 2,
          inOrder.snapshots.first?.attentionReason == .question,
          inOrder.attentionItems.count == 1
    else {
        failAgentIntegrationSelfTest("dedupe/out-of-order reducer")
    }

    let terminal = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "event-terminal",
        sequence: 3,
        observedAt: base.addingTimeInterval(2),
        state: .failed,
        reason: .taskFailure,
        actionability: .openExactNativeSession
    )
    let terminalReduction = AgentEventReducer.reduce(events: [
        terminal,
        oldRunning,
        newerWaiting,
    ])
    guard terminalReduction.snapshots.first?.executionState == .failed,
          terminalReduction.snapshots.first?.attentionReason == .taskFailure
    else {
        failAgentIntegrationSelfTest("newer terminal wins over stale events")
    }

    let sameTimestampA = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "tie-a",
        sequence: nil,
        observedAt: base.addingTimeInterval(3),
        state: .running
    )
    let sameTimestampB = makeAgentSelfTestEvent(
        identity: codexIdentity,
        eventID: "tie-b",
        sequence: nil,
        observedAt: base.addingTimeInterval(3),
        state: .completed,
        reason: .reviewReady
    )
    let tieAB = AgentEventReducer.reduce(events: [sameTimestampA, sameTimestampB])
    let tieBA = AgentEventReducer.reduce(events: [sameTimestampB, sameTimestampA])
    guard tieAB == tieBA,
          tieAB.snapshots.first?.latestEventID == "tie-b",
          tieAB.snapshots.first?.executionState == .completed
    else {
        failAgentIntegrationSelfTest("stable timestamp tie-break")
    }

    let mixedEvents = AgentID.builtInOrder.reversed().enumerated().map {
        index, agentID in
        makeAgentSelfTestEvent(
            identity: AgentSessionIdentity(
                agentID: agentID,
                nativeID: "session-\(agentID.rawValue)"
            ),
            eventID: "mixed-\(index)",
            sequence: 1,
            observedAt: base,
            state: .running
        )
    }
    let mixed = AgentEventReducer.reduce(events: mixedEvents)
    guard mixed.snapshots.map(\.identity.agentID) == AgentID.builtInOrder
    else {
        failAgentIntegrationSelfTest("five-agent stable output order")
    }

    let secondCodexSession = makeAgentSelfTestEvent(
        identity: AgentSessionIdentity(
            agentID: .codex,
            nativeID: "codex-session-two"
        ),
        eventID: oldRunning.eventID,
        sequence: 1,
        observedAt: base,
        state: .running
    )
    let sameEventIDAcrossSessions = AgentEventReducer.reduce(events: [
        oldRunning,
        secondCodexSession,
    ])
    guard sameEventIDAcrossSessions.processedEventCount == 2,
          sameEventIDAcrossSessions.snapshots.count == 2
    else {
        failAgentIntegrationSelfTest("event IDs are scoped to session identity")
    }

    let previousOMP = AgentEventReducer.reduce(events: [
        makeAgentSelfTestEvent(
            identity: AgentSessionIdentity(
                agentID: .omp,
                nativeID: "omp-preserved"
            ),
            eventID: "omp-old",
            sequence: 1,
            observedAt: base,
            state: .running,
            actionability: .viewOnly
        ),
    ])
    let failurePreserved = AgentEventReducer.reduce(
        events: [newerWaiting],
        previousSnapshots: previousOMP.snapshots,
        preservingAgentIDs: [.omp]
    )
    guard Set(failurePreserved.snapshots.map(\.identity.agentID))
        == Set([.codex, .omp])
    else {
        failAgentIntegrationSelfTest("adapter failure preserves prior frame")
    }
}

func runAgentTransportSelfTest() {
    guard AgentTransportContract.schemaVersion == 1,
          AgentTransportContract.maximumSerializedBytes == 64 * 1_024,
          AgentTransportContract.synchronousTimeout == 0.25
    else {
        failAgentIntegrationSelfTest("transport constants")
    }

    let oversizedSecret = String(repeating: "private-prompt-", count: 8_000)
    let oversized = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "self-test",
        nativeSessionCandidate: "cursor-session",
        eventID: "oversized",
        sequence: 1,
        eventType: "running",
        monotonicNanoseconds: 42,
        redactedPayload: [
            "state": oversizedSecret,
            "rawPrompt": "must never leave the hook",
        ]
    )
    let encoded: AgentTransportEncoding
    do {
        encoded = try AgentTransportEncoder.encode(oversized)
    } catch {
        failAgentIntegrationSelfTest("oversized envelope encoding")
    }
    let encodedText = String(data: encoded.data, encoding: .utf8) ?? ""
    guard encoded.data.count <= AgentTransportContract.maximumSerializedBytes,
          encoded.wasReducedToMetadata,
          !encodedText.contains("private-prompt"),
          !encodedText.contains("must never leave")
    else {
        failAgentIntegrationSelfTest("metadata-only oversized fallback")
    }

    let normal = AgentTransportEnvelope(
        agentID: .zcode,
        adapterVersion: "self-test",
        nativeSessionCandidate: nil,
        eventID: "normal",
        sequence: nil,
        eventType: "stop",
        monotonicNanoseconds: 43,
        redactedPayload: ["state": "completed"]
    )
    guard let normalEncoding = try? AgentTransportEncoder.encode(normal),
          let normalObject = try? JSONSerialization.jsonObject(
              with: normalEncoding.data
          ) as? [String: Any],
          normalObject["agentID"] as? String == "zcode",
          (normalObject["redactedPayload"] as? [String: String])
              == ["state": "completed"]
    else {
        failAgentIntegrationSelfTest("transport JSON/token contract")
    }

    let rejectedSensitive = AgentTransportEnvelope(
        agentID: .cursor,
        adapterVersion: "private version words",
        nativeSessionCandidate: "private path with spaces",
        eventID: "event with prompt words",
        sequence: nil,
        eventType: "raw prompt",
        monotonicNanoseconds: 44,
        redactedPayload: ["rawPrompt": "do not transport me"]
    )
    guard let rejectedEncoding = try? AgentTransportEncoder.encode(
        rejectedSensitive
    ),
          rejectedEncoding.wasReducedToMetadata,
          let rejectedText = String(
              data: rejectedEncoding.data,
              encoding: .utf8
          ),
          !rejectedText.contains("private"),
          !rejectedText.contains("prompt words"),
          !rejectedText.contains("do not transport")
    else {
        failAgentIntegrationSelfTest("transport rejects non-token/sensitive fields")
    }
    let offline = AgentHookTransport.send(normal) { _ in nil }
    let malformed = AgentHookTransport.send(normal) { _ in Data("not-json".utf8) }
    let started = Date()
    let slow = AgentHookTransport.send(normal) { _ in
        Thread.sleep(forTimeInterval: 0.60)
        return AgentHookTransport.validAcknowledgement
    }
    let elapsed = Date().timeIntervalSince(started)
    guard offline.disposition == .offline,
          malformed.disposition == .malformedResponse,
          slow.disposition == .timedOut,
          offline.vendorResponse.isEmpty,
          malformed.vendorResponse.isEmpty,
          slow.vendorResponse.isEmpty,
          elapsed < 0.50
    else {
        failAgentIntegrationSelfTest("fail-open offline/slow/malformed transport")
    }
}

private func makeAgentSelfTestEvent(
    identity: AgentSessionIdentity,
    eventID: String,
    sequence: Int?,
    observedAt: Date,
    state: ExecutionState,
    reason: AttentionReason = .none,
    actionability: Actionability = .viewOnly
) -> AgentEvent {
    AgentEvent(
        identity: identity,
        adapterVersion: "self-test",
        eventID: eventID,
        sequence: sequence,
        eventType: state.rawValue,
        observedAt: observedAt,
        monotonicNanoseconds: nil,
        executionState: state,
        attentionReason: reason,
        actionability: actionability,
        evidenceQuality: .nativeState,
        freshness: Freshness(
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(30)
        ),
        title: "Self-test",
        activitySummary: nil,
        workingDirectory: nil
    )
}

private func failAgentIntegrationSelfTest(_ message: String) -> Never {
    fputs("agent integration self-test failed: \(message)\n", stderr)
    exit(1)
}
