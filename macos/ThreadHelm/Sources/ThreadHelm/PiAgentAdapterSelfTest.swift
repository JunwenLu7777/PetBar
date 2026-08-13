//
//  PiAgentAdapterSelfTest.swift
//  ThreadHelm
//
//  模块职责：Pi state-only adapter 的隔离配置、传输和归一化自测。
//

import Foundation

func runPiAgentAdapterSelfTest() {
    do {
        try runPiDelayedVersionDiscoverySelfTest()
        try runPiIntegrationLifecycleSelfTest()
        try runPiStateOnlyContractSelfTest()
        try runPiGeneratedExtensionLoadSelfTest()
        try runPiEventReductionSelfTest()
        try runPiTransportContractSelfTest()
        print(
            "pi-agent-adapter-self-test: lifecycle=install+repeat+status+repair+repeat-uninstall+partial+preserve+live-home-guard "
                + "state-only=open-unavailable+no-control-fields+installed-jiti-load "
                + "events=offline+slow+malformed+duplicate+out-of-order+shutdown-stale"
        )
    } catch {
        fputs("pi-agent-adapter-self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

private func runPiDelayedVersionDiscoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-pi-version-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let executableURL = temporaryRoot.appendingPathComponent("pi")
    defer { try? manager.removeItem(at: temporaryRoot) }

    try manager.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: true
    )
    let attemptURL = temporaryRoot.appendingPathComponent("attempt")
    try Data(
        """
        #!/bin/sh
        if [ ! -f "\(attemptURL.path)" ]; then
          /usr/bin/touch "\(attemptURL.path)"
          /bin/sleep 3
        fi
        /bin/echo 0.84.1
        """.appending("\n").utf8
    ).write(to: executableURL)
    try manager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executableURL.path
    )

    let discovery = discoverLocalPiAgent(environment: [
        "THREADHELM_PI_EXECUTABLE": executableURL.path,
        "PATH": "/usr/bin:/bin",
    ])
    guard discovery.isInstalled,
          discovery.version == "0.84.1",
          discovery.compatibility == .validated
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "Pi CLI transient cold-start timeout was not retried"
        )
    }
}

private enum PiAgentAdapterSelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func runPiIntegrationLifecycleSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-pi-adapter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    let unrelatedURL = temporaryRoot
        .appendingPathComponent(
            ".pi/agent/extensions/user-owned-extension",
            isDirectory: true
        )
        .appendingPathComponent("extension.json")
    try manager.createDirectory(
        at: unrelatedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let unrelatedContent = #"{"name":"user-owned-extension","enabled":false}"#
    try Data(unrelatedContent.utf8).write(to: unrelatedURL)

    let adapter = PiAgentAdapter(discovery: {
        AgentDiscovery(
            isInstalled: true,
            version: "0.84.1",
            compatibility: .unknown
        )
    }, executablePath: { "/tmp/ThreadHelm" })

    let collisionRoot = temporaryRoot.appendingPathComponent(
        "pi-unowned-collision",
        isDirectory: true
    )
    let collisionDirectory = collisionRoot.appendingPathComponent(
        ".pi/agent/extensions/threadhelm-state-observer",
        isDirectory: true
    )
    let collisionScript = collisionDirectory.appendingPathComponent("index.ts")
    let collisionContent = Data("// user-owned collision".utf8)
    try manager.createDirectory(
        at: collisionDirectory,
        withIntermediateDirectories: true
    )
    try collisionContent.write(to: collisionScript)
    let collisionScope = AgentIntegrationScope.isolated(at: collisionRoot)
    guard adapter.integrationStatus(in: collisionScope) == .needsRepair else {
        throw PiAgentAdapterSelfTestError.failed("unowned collision status")
    }
    for operation in [
        { try adapter.repairIntegration(in: collisionScope) },
        { try adapter.uninstallIntegration(in: collisionScope) },
    ] {
        do {
            _ = try operation()
            throw PiAgentAdapterSelfTestError.failed("unowned collision was modified")
        } catch PiExtensionConfigurationError.notOwned {
        }
    }
    guard try Data(contentsOf: collisionScript) == collisionContent else {
        throw PiAgentAdapterSelfTestError.failed("unowned collision was not preserved")
    }
    let scope = AgentIntegrationScope.isolated(at: temporaryRoot)
    let unavailableRoot = temporaryRoot.appendingPathComponent(
        "pi-unavailable",
        isDirectory: true
    )
    let unavailableAdapter = PiAgentAdapter(discovery: {
        AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    })
    guard try unavailableAdapter.installIntegration(
        in: .isolated(at: unavailableRoot)
    ) == .unchanged,
    try unavailableAdapter.repairIntegration(
        in: .isolated(at: unavailableRoot)
    ) == .unchanged,
    !manager.fileExists(atPath: unavailableRoot.path)
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "unavailable Pi must not write integration files"
        )
    }

    guard adapter.integrationStatus(in: scope) == .notInstalled,
          try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.installIntegration(in: scope) == .unchanged,
          try String(contentsOf: unrelatedURL, encoding: .utf8)
              == unrelatedContent
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "install/status/idempotency or unrelated extension preservation"
        )
    }

    let directoryURL = try PiExtensionConfiguration.extensionDirectoryURL(
        in: scope
    )
    let scriptURL = directoryURL.appendingPathComponent("index.ts")
    try Data("partial-corruption".utf8).write(to: scriptURL)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed
    else {
        throw PiAgentAdapterSelfTestError.failed("partial corruption repair")
    }

    guard try adapter.uninstallIntegration(in: scope) == .uninstalled,
          try adapter.uninstallIntegration(in: scope) == .unchanged,
          adapter.integrationStatus(in: scope) == .notInstalled,
          try String(contentsOf: unrelatedURL, encoding: .utf8)
              == unrelatedContent
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "uninstall idempotency or unrelated extension preservation"
        )
    }

    do {
        _ = try adapter.installIntegration(
            in: .isolated(at: manager.homeDirectoryForCurrentUser)
        )
        throw PiAgentAdapterSelfTestError.failed("live home write was allowed")
    } catch AgentIntegrationError.liveConfigurationWriteDenied {
    }
}

private func runPiStateOnlyContractSelfTest() throws {
    let now = Date(timeIntervalSince1970: 1_786_532_400)
    let adapter = PiAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: false,
                version: nil,
                compatibility: .unknown
            )
        },
        readEvents: {
            [piSelfTestEvent(
                eventID: "pi-running",
                eventType: "agent_start",
                observedAt: now,
                monotonicNanoseconds: 10,
                executionState: .running,
                attentionReason: .permission,
                actionability: .inApp,
                workingDirectory: "/private/should-not-pass"
            )]
        }
    )
    let observation = try adapter.observe()
    guard observation.snapshots.count == 1,
          let snapshot = observation.snapshots.first,
          snapshot.identity.agentID == .pi,
          snapshot.attentionReason == .none,
          snapshot.actionability == .viewOnly,
          snapshot.workingDirectory == nil,
          adapter.open(session: snapshot).result == .unavailable,
          !adapter.open(session: snapshot).exactAttempted,
          !adapter.open(session: snapshot).independentlyConfirmedIdentity,
          adapter.diagnostics().health == .unavailable
    else {
        throw PiAgentAdapterSelfTestError.failed("state-only open/diagnostics")
    }

    let generatedFiles = PiExtensionConfiguration.generatedFilesForSelfTest()
    let generatedText = generatedFiles["index.ts"]?.lowercased() ?? ""
    let forbiddenFragments = [
        "pi.sendusermessage",
        "pi.sendmessage",
        "registertool",
        "registercommand",
        "ctx.newsession",
        "ctx.fork",
        "ctx.switchsession",
        "ctx.ui",
        "rawprompt",
        "tool_args",
        "tool_output",
        "command",
        "cwd",
        "workingdirectory",
        "secret",
        "password",
    ]
    if let forbidden = forbiddenFragments.first(where: {
        generatedText.contains($0)
    }) {
        throw PiAgentAdapterSelfTestError.failed(
            "generated extension contains forbidden fragment \(forbidden)"
        )
    }

    guard Set(generatedFiles.keys) == Set(["index.ts", ".threadhelm-owner"]),
          generatedFiles[".threadhelm-owner"]
            == "threadhelm-managed-state-observer-v1\n",
          generatedText.contains("export default function"),
          generatedText.contains("pi.on(\"session_start\""),
          generatedText.contains("pi.on(\"agent_settled\""),
          generatedText.contains("pi.on(\"session_compact\""),
          generatedText.contains("--agent-hook"),
          generatedText.contains("node:child_process"),
          !generatedText.contains("threadhelmagenteventsocketemit")
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "generated extension must use the installed Pi extension API"
        )
    }

    guard AgentTransportContract.maximumSerializedBytes == 64 * 1_024,
          AgentTransportContract.synchronousTimeout == 0.25
    else {
        throw PiAgentAdapterSelfTestError.failed("transport constants")
    }
}

private func runPiGeneratedExtensionLoadSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-pi-extension-load-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    guard let piExecutable = locatePiExecutable() else {
        throw PiAgentAdapterSelfTestError.failed(
            "installed Pi executable is required for extension load test"
        )
    }
    let piModuleURL = piExecutable
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appendingPathComponent("index.js")
    guard manager.fileExists(atPath: piModuleURL.path) else {
        throw PiAgentAdapterSelfTestError.failed(
            "installed Pi module entry is unavailable"
        )
    }

    let adapter = PiAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "0.84.1",
                compatibility: .unknown
            )
        },
        executablePath: { "/tmp/ThreadHelm" }
    )
    let scope = AgentIntegrationScope.isolated(at: temporaryRoot)
    guard try adapter.installIntegration(in: scope) == .installed else {
        throw PiAgentAdapterSelfTestError.failed(
            "isolated Pi extension was not installed"
        )
    }

    let projectURL = temporaryRoot.appendingPathComponent(
        "empty-project",
        isDirectory: true
    )
    try manager.createDirectory(
        at: projectURL,
        withIntermediateDirectories: true
    )
    let runnerURL = temporaryRoot.appendingPathComponent("load-extension.mjs")
    let runner = #"""
    import { pathToFileURL } from "node:url";

    const [agentDir, cwd, modulePath] = process.argv.slice(2);
    const { discoverAndLoadExtensions } = await import(
      pathToFileURL(modulePath).href
    );
    const result = await discoverAndLoadExtensions([], cwd, agentDir);
    const expected = [
      "agent_end",
      "agent_settled",
      "agent_start",
      "session_compact",
      "session_shutdown",
      "session_start",
      "tool_call",
      "tool_result"
    ];
    if (result.errors.length !== 0 || result.extensions.length !== 1) {
      process.exit(10);
    }
    const extension = result.extensions[0];
    const handlers = [...extension.handlers.keys()].sort();
    if (JSON.stringify(handlers) !== JSON.stringify(expected)) {
      process.exit(11);
    }
    if ([...extension.handlers.values()].some((items) => items.length !== 1)) {
      process.exit(12);
    }
    if (
      extension.tools.size !== 0 ||
      extension.commands.size !== 0 ||
      extension.shortcuts.size !== 0 ||
      extension.flags.size !== 0 ||
      extension.messageRenderers.size !== 0 ||
      (extension.entryRenderers?.size ?? 0) !== 0
    ) {
      process.exit(13);
    }
    process.stdout.write("pi-extension-load-ok");
    """#
    try Data(runner.utf8).write(to: runnerURL, options: .atomic)

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "node",
        runnerURL.path,
        temporaryRoot.appendingPathComponent(".pi/agent").path,
        projectURL.path,
        piModuleURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let capture = captureProcessOutput(
        process: process,
        output: output.fileHandleForReading,
        timeout: 5,
        maximumOutputBytes: 16_384
    )
    guard capture.termination == .exited,
          process.terminationStatus == 0,
          capture.data == Data("pi-extension-load-ok".utf8)
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "generated index.ts did not load as a state-only Pi extension"
        )
    }
}

private func runPiEventReductionSelfTest() throws {
    let now = Date(timeIntervalSince1970: 1_786_532_500)
    let agentEnd = piSelfTestEvent(
        eventID: "pi-agent-end",
        eventType: "agent_end",
        observedAt: now,
        monotonicNanoseconds: 20,
        executionState: .running,
        attentionReason: .none
    )
    let settledFailure = piSelfTestEvent(
        eventID: "pi-settled-failure",
        eventType: "agent_settled",
        observedAt: now.addingTimeInterval(1),
        monotonicNanoseconds: 30,
        executionState: .failed,
        attentionReason: .taskFailure,
        evidenceQuality: .inferred
    )
    let olderTool = piSelfTestEvent(
        eventID: "pi-tool-old",
        eventType: "tool_result",
        observedAt: now.addingTimeInterval(-10),
        monotonicNanoseconds: 10,
        executionState: .running,
        attentionReason: .none
    )
    let duplicateFailure = piSelfTestEvent(
        eventID: "pi-settled-failure",
        eventType: "agent_settled",
        observedAt: now.addingTimeInterval(1),
        monotonicNanoseconds: 30,
        executionState: .failed,
        attentionReason: .taskFailure,
        evidenceQuality: .inferred
    )
    let reduction = AgentEventReducer.reduce(events: [
        agentEnd,
        settledFailure,
        olderTool,
        duplicateFailure,
    ])
    guard reduction.snapshots.count == 1,
          reduction.processedEventCount == 3,
          reduction.snapshots.first?.executionState == .failed,
          reduction.snapshots.first?.attentionReason == .taskFailure,
          reduction.snapshots.first?.actionability == .viewOnly,
          reduction.attentionItems.count == 1,
          reduction.attentionItems.first?.isInterrupting == true
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "duplicate/out-of-order settled failure reduction"
        )
    }

    let agentEndOnly = AgentEventReducer.reduce(events: [agentEnd])
    guard agentEndOnly.snapshots.first?.executionState == .running,
          agentEndOnly.attentionItems.isEmpty
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "agent_end must not be terminal"
        )
    }

    let shutdown = piSelfTestEvent(
        eventID: "pi-shutdown",
        eventType: "session_shutdown",
        observedAt: now.addingTimeInterval(2),
        monotonicNanoseconds: 40,
        executionState: .offline,
        attentionReason: .none,
        stale: true
    )
    let shutdownReduction = AgentEventReducer.reduce(events: [shutdown])
    guard shutdownReduction.snapshots.first?.executionState == .offline,
          shutdownReduction.snapshots.first?.freshness.staleReason != nil,
          shutdownReduction.attentionItems.isEmpty
    else {
        throw PiAgentAdapterSelfTestError.failed("shutdown/stale cleanup")
    }

    let envelope = AgentTransportEnvelope(
        agentID: .pi,
        adapterVersion: PiAgentDefaults.adapterVersion,
        nativeSessionCandidate: "pi-envelope-session",
        eventID: "pi-envelope-failure",
        sequence: 5,
        eventType: "agent_settled",
        monotonicNanoseconds: 50,
        redactedPayload: [
            "state": "failed",
            "attentionReason": "taskFailure",
            "actionability": "inApp",
            "evidenceQuality": "inferred",
            "freshness": "fresh",
        ]
    )
    guard let parsed = piAgentEvent(from: envelope, observedAt: now),
          parsed.identity.nativeID == "pi-envelope-session",
          parsed.executionState == .failed,
          parsed.attentionReason == .taskFailure,
          parsed.actionability == .viewOnly,
          parsed.workingDirectory == nil,
          parsed.activitySummary == nil
    else {
        throw PiAgentAdapterSelfTestError.failed("transport envelope parsing")
    }
}

private func runPiTransportContractSelfTest() throws {
    let envelope = AgentTransportEnvelope(
        agentID: .pi,
        adapterVersion: PiAgentDefaults.adapterVersion,
        nativeSessionCandidate: "pi-transport-session",
        eventID: "pi-transport-event",
        sequence: nil,
        eventType: "tool_call",
        monotonicNanoseconds: 60,
        redactedPayload: [
            "state": "running",
            "attentionReason": "none",
            "actionability": "viewOnly",
            "evidenceQuality": "officialHook",
            "freshness": "fresh",
        ]
    )
    let offline = AgentHookTransport.send(envelope) { _ in nil }
    let malformed = AgentHookTransport.send(envelope) { _ in Data("bad".utf8) }
    let slow = AgentHookTransport.send(envelope) { _ in
        Thread.sleep(forTimeInterval: AgentTransportContract.synchronousTimeout + 0.1)
        return AgentHookTransport.validAcknowledgement
    }
    guard offline.disposition == .offline,
          malformed.disposition == .malformedResponse,
          slow.disposition == .timedOut,
          offline.vendorResponse.isEmpty,
          malformed.vendorResponse.isEmpty,
          slow.vendorResponse.isEmpty
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "offline/slow/malformed fail-open transport"
        )
    }

    let sensitive = AgentTransportEnvelope(
        agentID: .pi,
        adapterVersion: PiAgentDefaults.adapterVersion,
        nativeSessionCandidate: "pi-transport-session",
        eventID: "pi-sensitive-event",
        sequence: nil,
        eventType: "tool_result",
        monotonicNanoseconds: 61,
        redactedPayload: [
            "state": "running",
            "prompt": "not allowed",
        ]
    )
    guard let encoding = try? AgentTransportEncoder.encode(sensitive),
          encoding.wasReducedToMetadata
    else {
        throw PiAgentAdapterSelfTestError.failed(
            "sensitive transport fields must become metadata-only"
        )
    }
}

private func piSelfTestEvent(
    eventID: String,
    eventType: String,
    observedAt: Date,
    monotonicNanoseconds: UInt64,
    executionState: ExecutionState,
    attentionReason: AttentionReason,
    evidenceQuality: EvidenceQuality = .officialHook,
    stale: Bool = false,
    actionability: Actionability = .viewOnly,
    workingDirectory: String? = nil
) -> AgentEvent {
    AgentEvent(
        identity: AgentSessionIdentity(agentID: .pi, nativeID: "pi-session-1"),
        adapterVersion: PiAgentDefaults.adapterVersion,
        eventID: eventID,
        sequence: nil,
        eventType: eventType,
        observedAt: observedAt,
        monotonicNanoseconds: monotonicNanoseconds,
        executionState: executionState,
        attentionReason: attentionReason,
        actionability: actionability,
        evidenceQuality: evidenceQuality,
        freshness: Freshness(
            observedAt: observedAt,
            expiresAt: stale
                ? observedAt
                : observedAt.addingTimeInterval(PiAgentDefaults.staleAfter),
            staleReason: stale ? "pi-session-shutdown-or-stale" : nil
        ),
        title: "Pi self-test",
        activitySummary: nil,
        workingDirectory: workingDirectory
    )
}
