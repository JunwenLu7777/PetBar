//
//  OMPAgentAdapterSelfTest.swift
//  ThreadHelm
//
//  模块职责：OMP adapter 的隔离配置、传输、归一化和会话跳转自测。
//

import Foundation

func runOMPAgentAdapterSelfTest() {
    do {
        try runOMPDelayedVersionDiscoverySelfTest()
        try runOMPIntegrationLifecycleSelfTest()
        try runOMPStateOnlyContractSelfTest()
        try runOMPStrictRequirementSelfTest()
        let extensionLoad = try runOMPGeneratedExtensionLoadSelfTest()
        try runOMPEventReductionSelfTest()
        try runOMPTransportContractSelfTest()
        try runOMPLocalSessionContentSelfTest()
        print(
            "omp-agent-adapter-self-test: lifecycle=install+repeat+status+repair+repeat-uninstall+partial+preserve+live-home-guard "
                + "navigation=resume-dispatch+no-control-fields+"
                + "installed-jiti-load=\(extensionLoad.rawValue) "
                + "events=offline+slow+malformed+duplicate+out-of-order+shutdown-stale "
                + "public-output=text-only+cwd+bounded-local-read+atomic-replace"
        )
    } catch {
        fputs("omp-agent-adapter-self-test failed: \(error)\n", stderr)
        exit(1)
    }
}

/// 生成的扩展是否真的在本机 OMP 运行时里被加载过。
/// 这条断言需要一个真实安装的 OMP，CI runner 上通常没有——那里既不该当成
/// 通过，也不该当成失败，只能如实报告"未覆盖"。
enum OMPExtensionLoadCoverage: String {
    case verified
    case skippedNoLocalOMP = "skipped-no-local-omp"
}

private func runOMPDelayedVersionDiscoverySelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-version-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    let executableURL = temporaryRoot.appendingPathComponent("omp")
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
        /bin/echo 17.3.2
        """.appending("\n").utf8
    ).write(to: executableURL)
    try manager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executableURL.path
    )

    let discovery = discoverLocalOMPAgent(environment: [
        "THREADHELM_OMP_EXECUTABLE": executableURL.path,
        "PATH": "/usr/bin:/bin",
    ])
    guard discovery.isInstalled,
          discovery.version == "17.3.2",
          discovery.compatibility == .validated
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP CLI transient cold-start timeout was not retried"
        )
    }
}

/// 隔离 OMP RPC 自测前需要从环境中清除的厂商密钥变量。
/// 保证自测既不读取用户真实凭据，也不会因本机是否导出密钥而结果漂移。
private let ompSelfTestClearedProviderKeys = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "OPENROUTER_API_KEY",
    "XAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "PI_API_KEY",
]

private enum OMPAgentAdapterSelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func runOMPIntegrationLifecycleSelfTest() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-adapter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    let unrelatedURL = temporaryRoot
        .appendingPathComponent(
            ".omp/agent/extensions/user-owned-extension",
            isDirectory: true
        )
        .appendingPathComponent("extension.json")
    try manager.createDirectory(
        at: unrelatedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let unrelatedContent = #"{"name":"user-owned-extension","enabled":false}"#
    try Data(unrelatedContent.utf8).write(to: unrelatedURL)

    let adapter = OMPAgentAdapter(discovery: {
        AgentDiscovery(
            isInstalled: true,
            version: "17.3.2",
            compatibility: .unknown
        )
    }, executablePath: { "/tmp/ThreadHelm" })

    let collisionRoot = temporaryRoot.appendingPathComponent(
        "omp-unowned-collision",
        isDirectory: true
    )
    let collisionDirectory = collisionRoot.appendingPathComponent(
        ".omp/agent/extensions/threadhelm-state-observer",
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
        throw OMPAgentAdapterSelfTestError.failed("unowned collision status")
    }
    for operation in [
        { try adapter.repairIntegration(in: collisionScope) },
        { try adapter.uninstallIntegration(in: collisionScope) },
    ] {
        do {
            _ = try operation()
            throw OMPAgentAdapterSelfTestError.failed("unowned collision was modified")
        } catch OMPExtensionConfigurationError.notOwned {
        }
    }
    guard try Data(contentsOf: collisionScript) == collisionContent else {
        throw OMPAgentAdapterSelfTestError.failed("unowned collision was not preserved")
    }
    let scope = AgentIntegrationScope.isolated(at: temporaryRoot)
    let unavailableRoot = temporaryRoot.appendingPathComponent(
        "omp-unavailable",
        isDirectory: true
    )
    let unavailableAdapter = OMPAgentAdapter(discovery: {
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
        throw OMPAgentAdapterSelfTestError.failed(
            "unavailable OMP must not write integration files"
        )
    }

    guard adapter.integrationStatus(in: scope) == .notInstalled,
          try adapter.installIntegration(in: scope) == .installed,
          adapter.integrationStatus(in: scope) == .installed,
          try adapter.installIntegration(in: scope) == .unchanged,
          try String(contentsOf: unrelatedURL, encoding: .utf8)
              == unrelatedContent
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "install/status/idempotency or unrelated extension preservation"
        )
    }

    let directoryURL = try OMPExtensionConfiguration.extensionDirectoryURL(
        in: scope
    )
    let scriptURL = directoryURL.appendingPathComponent("index.ts")
    try Data("partial-corruption".utf8).write(to: scriptURL)
    guard adapter.integrationStatus(in: scope) == .needsRepair,
          try adapter.repairIntegration(in: scope) == .repaired,
          adapter.integrationStatus(in: scope) == .installed
    else {
        throw OMPAgentAdapterSelfTestError.failed("partial corruption repair")
    }

    guard try adapter.uninstallIntegration(in: scope) == .uninstalled,
          try adapter.uninstallIntegration(in: scope) == .unchanged,
          adapter.integrationStatus(in: scope) == .notInstalled,
          try String(contentsOf: unrelatedURL, encoding: .utf8)
              == unrelatedContent
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "uninstall idempotency or unrelated extension preservation"
        )
    }

    do {
        _ = try adapter.installIntegration(
            in: .isolated(at: manager.homeDirectoryForCurrentUser)
        )
        throw OMPAgentAdapterSelfTestError.failed("live home write was allowed")
    } catch AgentIntegrationError.liveConfigurationWriteDenied {
    }
}

private func runOMPStateOnlyContractSelfTest() throws {
    let now = Date(timeIntervalSince1970: 1_786_532_400)
    var resumedSessionID: String?
    let adapter = OMPAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "17.3.2",
                compatibility: .validated
            )
        },
        readEvents: {
            [ompSelfTestEvent(
                eventID: "omp-running",
                eventType: "agent_start",
                observedAt: now,
                monotonicNanoseconds: 10,
                executionState: .running,
                attentionReason: .permission,
                actionability: .inApp,
                workingDirectory: "/private/should-not-pass"
            )]
        },
        resumeSession: {
            resumedSessionID = $0
            return true
        }
    )
    let observation = try adapter.observe()
    let report = observation.snapshots.first.map(adapter.open(session:))
    guard observation.snapshots.count == 1,
          let snapshot = observation.snapshots.first,
          snapshot.identity.agentID == .omp,
          snapshot.attentionReason == .none,
          snapshot.actionability == .openExactNativeSession,
          snapshot.workingDirectory == nil,
          report?.result == .unknown,
          report?.exactAttempted == true,
          report?.independentlyConfirmedIdentity == false,
          resumedSessionID == "omp-session-1",
          adapter.diagnostics().health == .healthy,
          ompResumeCommand(
              sessionID: "omp-session-1",
              executablePath: "/opt/homebrew/bin/omp"
          ) == "exec '/opt/homebrew/bin/omp' --resume 'omp-session-1'",
          ompResumeCommand(
              sessionID: "bad session; rm -rf",
              executablePath: "/opt/homebrew/bin/omp"
          ) == nil
    else {
        throw OMPAgentAdapterSelfTestError.failed("resume navigation/diagnostics")
    }

    let generatedFiles = OMPExtensionConfiguration.generatedFilesForSelfTest()
    let generatedText = generatedFiles["index.ts"]?.lowercased() ?? ""
    let forbiddenFragments = [
        "omp.sendusermessage",
        "omp.sendmessage",
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
        throw OMPAgentAdapterSelfTestError.failed(
            "generated extension contains forbidden fragment \(forbidden)"
        )
    }

    guard Set(generatedFiles.keys) == Set(["index.ts", ".threadhelm-owner"]),
          generatedFiles[".threadhelm-owner"]
            == "threadhelm-managed-state-observer-v1\n",
          generatedText.contains("export default function"),
          generatedText.contains("omp.on(\"session_start\""),
          generatedText.contains("omp.on(\"agent_end\""),
          generatedText.contains("event.willcontinue"),
          generatedText.contains("task_failure"),
          !generatedText.contains("agent_settled"),
          generatedText.contains("omp.on(\"session_compact\""),
          generatedText.contains("--agent-hook"),
          generatedText.contains("node:child_process"),
          !generatedText.contains("threadhelmagenteventsocketemit")
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "generated extension must use the installed OMP extension API"
        )
    }

    guard AgentTransportContract.maximumSerializedBytes == 64 * 1_024,
          AgentTransportContract.synchronousTimeout == 0.25
    else {
        throw OMPAgentAdapterSelfTestError.failed("transport constants")
    }
}

private func runOMPStrictRequirementSelfTest() throws {
    do {
        _ = try runOMPGeneratedExtensionLoadSelfTest(
            environment: ["THREADHELM_REQUIRE_OMP": "1"],
            locateExecutable: { nil }
        )
    } catch let error as OMPAgentAdapterSelfTestError {
        // 收窄到具体错误：宽泛的 catch 在未来有人往 guard 之前加入可抛的
        // setup 时，会把无关错误吸收成"通过"。
        guard error.description.contains("THREADHELM_REQUIRE_OMP") else {
            throw OMPAgentAdapterSelfTestError.failed(
                "严格模式应因缺少 OMP 而失败，实际错误：\(error)"
            )
        }
        return
    }
    throw OMPAgentAdapterSelfTestError.failed(
        "THREADHELM_REQUIRE_OMP must fail when OMP is unavailable"
    )
}

private func runOMPGeneratedExtensionLoadSelfTest(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    locateExecutable: () -> URL? = { locateOMPExecutable() }
) throws
    -> OMPExtensionLoadCoverage
{
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-extension-load-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: temporaryRoot) }

    // 没装 OMP 就没有可加载扩展的运行时。把这当失败会让任何没有 OMP 的
    // 环境（CI runner）永远红，且红的原因与被测代码无关；如实报告未覆盖，
    // 并在摘要里留痕，比假装通过或假装失败都诚实。
    guard let ompExecutable = locateExecutable() else {
        if environment["THREADHELM_REQUIRE_OMP"] == "1" {
            throw OMPAgentAdapterSelfTestError.failed(
                "THREADHELM_REQUIRE_OMP=1 but no OMP executable was found"
            )
        }
        fputs(
            "omp-agent-adapter-self-test: 未发现本机 OMP，跳过生成扩展的加载验证\n",
            stderr
        )
        return .skippedNoLocalOMP
    }
    let adapter = OMPAgentAdapter(
        discovery: {
            AgentDiscovery(
                isInstalled: true,
                version: "17.3.2",
                compatibility: .unknown
            )
        },
        executablePath: { "/tmp/ThreadHelm" }
    )
    let scope = AgentIntegrationScope.isolated(at: temporaryRoot)
    guard try adapter.installIntegration(in: scope) == .installed else {
        throw OMPAgentAdapterSelfTestError.failed(
            "isolated OMP extension was not installed"
        )
    }
    let scriptURL = try OMPExtensionConfiguration.extensionDirectoryURL(
        in: scope
    ).appendingPathComponent("index.ts")

    let projectURL = temporaryRoot.appendingPathComponent(
        "empty-project",
        isDirectory: true
    )
    try manager.createDirectory(
        at: projectURL,
        withIntermediateDirectories: true
    )
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = ompExecutable
    process.currentDirectoryURL = projectURL
    process.arguments = [
        "--mode", "rpc",
        "--no-session",
        "--no-tools",
        "--no-skills",
        "--no-lsp",
        "--no-pty",
        "--extension", scriptURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = temporaryRoot.path
    environment["PI_CODING_AGENT_DIR"] = temporaryRoot
        .appendingPathComponent(".omp/agent").path
    // 本用例把 HOME 指向临时目录，OMP 因此读不到用户的 models.yml；没有任何
    // 可用模型时它会在加载扩展之前就以 status 1 退出（"No models available"），
    // 使断言失败原因与扩展本身无关。这里注入占位密钥让 OMP 能完成启动。
    //
    // 同时清空所有已知厂商密钥，确保：
    //   1. 结果不随开发者本机是否导出了真实密钥而漂移（自测必须可复现）；
    //   2. 自测进程绝不可能拿到用户的真实凭据。
    // `get_state` 是纯本地查询，占位密钥不会产生任何网络请求。
    for key in ompSelfTestClearedProviderKeys {
        environment.removeValue(forKey: key)
    }
    environment["ANTHROPIC_API_KEY"] = "threadhelm-self-test-placeholder"
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(
        contentsOf: Data("{\"id\":\"threadhelm\",\"type\":\"get_state\"}\n".utf8)
    )
    try input.fileHandleForWriting.close()
    let capture = captureProcessOutput(
        process: process,
        output: output.fileHandleForReading,
        timeout: 10,
        terminationGracePeriod: 2,
        maximumOutputBytes: 65_536
    )
    let text = String(data: capture.data, encoding: .utf8) ?? ""
    let frames: [[String: Any]] = text
        .split(whereSeparator: \.isNewline)
        .compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) else { return nil }
            return object as? [String: Any]
        }
    let sawReady = frames.contains { frame in
        frame["type"] as? String == "ready"
    }
    let sawSuccessfulStateResponse = frames.contains { frame in
        frame["id"] as? String == "threadhelm"
            && frame["type"] as? String == "response"
            && frame["command"] as? String == "get_state"
            && frame["success"] as? Bool == true
    }
    let sawExtensionError = frames.contains { frame in
        frame["type"] as? String == "extension_error"
    }
    guard capture.termination == .exited,
          process.terminationStatus == 0,
          sawReady,
          sawSuccessfulStateResponse,
          !sawExtensionError
    else {
        // 只截断展示，便于区分"扩展本身有问题"与"OMP 根本没起来"
        // （例如缺少可用模型、CLI 参数变更）这两类完全不同的失败。
        let diagnostic = text
            .split(whereSeparator: \.isNewline)
            .suffix(6)
            .joined(separator: " | ")
            .prefix(600)
        throw OMPAgentAdapterSelfTestError.failed(
            "generated index.ts did not load in isolated OMP RPC mode "
                + "(termination=\(capture.termination), status=\(process.terminationStatus), "
                + "ready=\(sawReady), response=\(sawSuccessfulStateResponse), "
                + "extensionError=\(sawExtensionError))"
                + "; last output: \(diagnostic.isEmpty ? "<empty>" : String(diagnostic))"
        )
    }
    return .verified
}

private func runOMPEventReductionSelfTest() throws {
    let now = Date(timeIntervalSince1970: 1_786_532_500)
    let agentEnd = ompSelfTestEvent(
        eventID: "omp-agent-end",
        eventType: "agent_end",
        observedAt: now,
        monotonicNanoseconds: 20,
        executionState: .running,
        attentionReason: .none
    )
    let terminalFailure = ompSelfTestEvent(
        eventID: "omp-terminal-failure",
        eventType: "agent_end",
        observedAt: now.addingTimeInterval(1),
        monotonicNanoseconds: 30,
        executionState: .failed,
        attentionReason: .taskFailure,
        evidenceQuality: .inferred
    )
    let olderTool = ompSelfTestEvent(
        eventID: "omp-tool-old",
        eventType: "tool_result",
        observedAt: now.addingTimeInterval(-10),
        monotonicNanoseconds: 10,
        executionState: .running,
        attentionReason: .none
    )
    let duplicateFailure = ompSelfTestEvent(
        eventID: "omp-terminal-failure",
        eventType: "agent_end",
        observedAt: now.addingTimeInterval(1),
        monotonicNanoseconds: 30,
        executionState: .failed,
        attentionReason: .taskFailure,
        evidenceQuality: .inferred
    )
    let reduction = AgentEventReducer.reduce(events: [
        agentEnd,
        terminalFailure,
        olderTool,
        duplicateFailure,
    ])
    guard reduction.snapshots.count == 1,
          reduction.processedEventCount == 3,
          reduction.snapshots.first?.executionState == .failed,
          reduction.snapshots.first?.attentionReason == .taskFailure,
          reduction.snapshots.first?.actionability == .openExactNativeSession,
          reduction.attentionItems.count == 1,
          reduction.attentionItems.first?.isInterrupting == true
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "duplicate/out-of-order terminal failure reduction"
        )
    }

    let agentEndOnly = AgentEventReducer.reduce(events: [agentEnd])
    guard agentEndOnly.snapshots.first?.executionState == .running,
          agentEndOnly.attentionItems.isEmpty
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "agent_end must not be terminal"
        )
    }

    let shutdown = ompSelfTestEvent(
        eventID: "omp-shutdown",
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
        throw OMPAgentAdapterSelfTestError.failed("shutdown/stale cleanup")
    }

    let envelope = AgentTransportEnvelope(
        agentID: .omp,
        adapterVersion: OMPAgentDefaults.adapterVersion,
        nativeSessionCandidate: "omp-envelope-session",
        eventID: "omp-envelope-failure",
        sequence: 5,
        eventType: "agent_end",
        monotonicNanoseconds: 50,
        redactedPayload: [
            "state": "failed",
            "attentionReason": "taskFailure",
            "actionability": "inApp",
            "evidenceQuality": "inferred",
            "freshness": "fresh",
        ]
    )
    guard let parsed = ompAgentEvent(from: envelope, observedAt: now),
          parsed.identity.nativeID == "omp-envelope-session",
          parsed.executionState == .failed,
          parsed.attentionReason == .taskFailure,
          parsed.actionability == .openExactNativeSession,
          parsed.workingDirectory == nil,
          parsed.activitySummary == nil
    else {
        throw OMPAgentAdapterSelfTestError.failed("transport envelope parsing")
    }
}

private func runOMPTransportContractSelfTest() throws {
    let envelope = AgentTransportEnvelope(
        agentID: .omp,
        adapterVersion: OMPAgentDefaults.adapterVersion,
        nativeSessionCandidate: "omp-transport-session",
        eventID: "omp-transport-event",
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
        throw OMPAgentAdapterSelfTestError.failed(
            "offline/slow/malformed fail-open transport"
        )
    }

    let sensitive = AgentTransportEnvelope(
        agentID: .omp,
        adapterVersion: OMPAgentDefaults.adapterVersion,
        nativeSessionCandidate: "omp-transport-session",
        eventID: "omp-sensitive-event",
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
        throw OMPAgentAdapterSelfTestError.failed(
            "sensitive transport fields must become metadata-only"
        )
    }
}

private func runOMPLocalSessionContentSelfTest() throws {
    let sessionID = "01a00dcf-f7ab-7000-9273-9c7707ab6193"
    let transcript = """
    {"type":"session","timestamp":"2026-08-17T03:42:08.299Z","cwd":"/private/tmp/omp-public-project"}
    {"type":"message","timestamp":"2026-08-17T03:45:24.944Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"隐藏推理不能显示"},{"type":"text","text":"正在整理 OMP 的公开结果"},{"type":"toolCall","name":"bash","arguments":{"cmd":"echo secret"}}]}}
    {"type":"message","timestamp":"2026-08-17T03:45:25.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"工具输出不能显示"}]}}
    {"type":"message","timestamp":"2026-08-17T03:46:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"access_token=omp-secret-value"}]}}
    {"type":"message","timestamp":"2026-08-17T03:47:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"{\\"password\\":\\"raw-json-secret\\"}"}]}}
    """
    let parsed = OMPLocalSession.content(fromJSONL: transcript)
    guard parsed.workingDirectory == "/private/tmp/omp-public-project",
          parsed.events.map(\.text) == [
              "access_token=[已隐藏]",
              "正在整理 OMP 的公开结果",
          ],
          !parsed.events.contains(where: {
              $0.text.contains("隐藏推理")
                  || $0.text.contains("工具输出")
                  || $0.text.contains("echo secret")
                  || $0.text.contains("raw-json-secret")
          })
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP local transcript privacy projection"
        )
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "threadhelm-omp-session-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? manager.removeItem(at: root) }
    let indexRoot = root.appendingPathComponent(
        "Transcript Index",
        isDirectory: true
    )
    let project = root.appendingPathComponent("project", isDirectory: true)
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    let transcriptURL = project.appendingPathComponent(
        "2026-08-17T03-42-08-299Z_\(sessionID).jsonl"
    )
    try Data(transcript.utf8).write(to: transcriptURL)
    let located = OMPLocalSession.content(
        sessionID: sessionID,
        sessionsRoot: root,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    guard located?.workingDirectory == parsed.workingDirectory,
          located?.events.map(\.text) == parsed.events.map(\.text),
          located?.events.contains(where: {
              $0.text.contains("隐藏推理")
                  || $0.text.contains("工具输出")
                  || $0.text.contains("echo secret")
                  || $0.text.contains("raw-json-secret")
          }) == false,
          OMPLocalSession.content(
              sessionID: "bad session; unsafe",
              sessionsRoot: root,
              fileManager: manager,
              indexRootDirectory: indexRoot
          ) == nil
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP bounded local transcript lookup"
        )
    }

    // Cache validation is identity-based, not just mtime/size based.  Replace
    // the transcript atomically with equal-length content and preserve mtime;
    // the second production read must project only the replacement inode.
    let replaceSessionID = "01a00dcf-f7ab-7000-9273-9c7707ab6200"
    let replaceURL = project.appendingPathComponent(
        "2026-08-17T03-42-08-299Z_\(replaceSessionID).jsonl"
    )
    func replaceTranscript(_ text: String) -> Data {
        Data(
            ("""
            {"type":"session","timestamp":"2026-08-17T03:42:08.299Z","cwd":"/private/tmp/omp-replace-project"}
            {"type":"message","timestamp":"2026-08-17T03:45:24.944Z","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
            """ + "\n").utf8
        )
    }
    let replaceFirstData = replaceTranscript("AAAA")
    let replaceSecondData = replaceTranscript("BBBB")
    guard replaceFirstData.count == replaceSecondData.count else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP atomic replace fixtures differ in size"
        )
    }
    let replaceDate = Date(timeIntervalSince1970: 1_786_600_000)
    OMPLocalSession.resetInMemoryStateForTesting()
    try replaceFirstData.write(to: replaceURL)
    try manager.setAttributes(
        [.modificationDate: replaceDate],
        ofItemAtPath: replaceURL.path
    )
    guard let firstIdentity = TranscriptEventReader.make(at: replaceURL)?.identity,
          OMPLocalSession.content(
              sessionID: replaceSessionID,
              sessionsRoot: root,
              fileManager: manager,
              indexRootDirectory: indexRoot
          )?.events.contains(where: { $0.text.contains("AAAA") }) == true
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP atomic replace initial projection"
        )
    }
    try replaceSecondData.write(to: replaceURL, options: .atomic)
    try manager.setAttributes(
        [.modificationDate: replaceDate],
        ofItemAtPath: replaceURL.path
    )
    let replaced = OMPLocalSession.content(
        sessionID: replaceSessionID,
        sessionsRoot: root,
        fileManager: manager,
        indexRootDirectory: indexRoot
    )
    guard TranscriptEventReader.make(at: replaceURL)?.identity != firstIdentity,
          replaced?.events.contains(where: { $0.text.contains("BBBB") }) == true,
          replaced?.events.contains(where: { $0.text.contains("AAAA") }) != true
    else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP same-size atomic replace reused stale cache"
        )
    }

    let largeSessionID = "01a00e24-d9a5-7000-a897-cc3f8baf2a75"
    let privateFiller = String(repeating: "隐藏填充", count: 100_000)
    var splitUTF8Data: Data?
    for leadingPadding in ["", "x", "xx"] {
        let candidate = """
        {"type":"session","timestamp":"2026-08-17T05:14:51.173Z","cwd":"/private/tmp/omp-large-project"}
        {"type":"message","timestamp":"2026-08-17T05:15:00.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"\(leadingPadding)\(privateFiller)"}]}}
        {"type":"message","timestamp":"2026-08-17T05:16:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"尾部公开结果仍可读取"}]}}
        """ + "\n"
        let data = Data(candidate.utf8)
        let largeTranscriptURL = project.appendingPathComponent(
            "2026-08-17T05:14:51-173Z_\(largeSessionID).jsonl"
        )
        try data.write(to: largeTranscriptURL)
        let largeLocated = OMPLocalSession.content(
            sessionID: largeSessionID,
            sessionsRoot: root,
            fileManager: manager,
            indexRootDirectory: indexRoot
        )
        if largeLocated?.workingDirectory == "/private/tmp/omp-large-project",
           largeLocated?.events.map(\.text) == ["尾部公开结果仍可读取"],
           !(largeLocated?.events.contains(where: {
               $0.text.contains("隐藏填充")
           }) ?? true)
        {
            splitUTF8Data = data
            break
        }
    }
    guard let splitUTF8Data else {
        throw OMPAgentAdapterSelfTestError.failed(
            "OMP large transcript recovery via shared reader failed"
        )
    }
    _ = splitUTF8Data
}

private func ompSelfTestEvent(
    eventID: String,
    eventType: String,
    observedAt: Date,
    monotonicNanoseconds: UInt64,
    executionState: ExecutionState,
    attentionReason: AttentionReason,
    evidenceQuality: EvidenceQuality = .officialHook,
    stale: Bool = false,
    actionability: Actionability = .openExactNativeSession,
    workingDirectory: String? = nil
) -> AgentEvent {
    AgentEvent(
        identity: AgentSessionIdentity(agentID: .omp, nativeID: "omp-session-1"),
        adapterVersion: OMPAgentDefaults.adapterVersion,
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
                : observedAt.addingTimeInterval(OMPAgentDefaults.staleAfter),
            staleReason: stale ? "omp-session-shutdown-or-stale" : nil
        ),
        title: "OMP self-test",
        activitySummary: nil,
        workingDirectory: workingDirectory
    )
}
