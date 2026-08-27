//
//  AgentIntegrationManagerSelfTest.swift
//  ThreadHelm
//
//  模块职责：只在临时 root 内验证五 Agent 的统一集成生命周期、备份恢复、
//  事务回滚和命令行安全边界。不得读取或修改真实厂商配置。
//

import Foundation

private enum IntegrationManagerSelfTestError: Error {
    case expectedFailure
    case injectedWriteFailure
    case assertion(String)
}

private struct FailingManagedAdapter: AgentAdapter {
    let metadata = AgentMetadata(
        id: AgentID(rawValue: "transactionFailure"),
        displayName: "Transaction Failure",
        shortName: "Failure",
        iconResourceName: "ProviderIcon-test",
        fallbackSymbolName: "exclamationmark.triangle",
        brandColor: AgentColorComponents(red: 1, green: 0, blue: 0),
        versionSource: "self-test",
        identityPolicy: "self-test",
        capabilities: AgentCapabilitySet(supported: [.managedIntegration])
    )

    var managedIntegrationRelativePaths: [String] {
        [".failure/threadhelm.json"]
    }

    func discover() -> AgentDiscovery {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .validated
        )
    }

    func integrationStatus(
        in scope: AgentIntegrationScope
    ) -> AgentIntegrationStatus {
        .notInstalled
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

/// 与 `FailingManagedAdapter` 的区别：它**先真正落盘再失败**。
/// 只有这样，回滚断言才可能变红——如果备份作用域被改坏（为空、或漏掉本
/// Agent），垃圾内容就会留在盘上，字节级断言随即失败。
private struct WritingThenFailingManagedAdapter: AgentAdapter {
    static let managedRelativePath = ".writing-failure/threadhelm.json"
    static let agentID = AgentID(rawValue: "writingTransactionFailure")

    let metadata = AgentMetadata(
        id: WritingThenFailingManagedAdapter.agentID,
        displayName: "Writing Transaction Failure",
        shortName: "WriteFailure",
        iconResourceName: "ProviderIcon-test",
        fallbackSymbolName: "exclamationmark.triangle",
        brandColor: AgentColorComponents(red: 1, green: 0, blue: 0),
        versionSource: "self-test",
        identityPolicy: "self-test",
        capabilities: AgentCapabilitySet(supported: [.managedIntegration])
    )

    var managedIntegrationRelativePaths: [String] {
        [WritingThenFailingManagedAdapter.managedRelativePath]
    }

    func discover() -> AgentDiscovery {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .validated
        )
    }

    func integrationStatus(
        in scope: AgentIntegrationScope
    ) -> AgentIntegrationStatus {
        .notInstalled
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let url = scope.rootDirectory.appendingPathComponent(
            WritingThenFailingManagedAdapter.managedRelativePath
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"owner":"half-written-garbage"}"#.utf8).write(to: url)
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

func runAgentIntegrationManagerSelfTest() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "threadhelm-integration-manager-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    do {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fixtures = try makeIntegrationManagerFixtures(at: root)
        let registry = makeIntegrationManagerRegistry()
        let manager = AgentIntegrationManager(registry: registry)
        let scope = AgentIntegrationScope.isolated(at: root)

        let status = manager.status(in: scope)
        guard status.operation == .status,
              status.backupID == nil,
              status.agents.map(\.agentID) == AgentID.builtInOrder,
              // Codex 自接入审批闸门起也进入受管集合，五家再无例外。
              status.record(for: .codex)?.statusAfter == .notInstalled,
              status.record(for: .claudeCode)?.statusAfter == .notInstalled,
              status.record(for: .cursor)?.statusAfter == .notInstalled,
              status.record(for: .zcode)?.statusAfter == .notInstalled,
              status.record(for: .omp)?.statusAfter == .notInstalled
        else {
            failIntegrationManagerSelfTest("five-agent status")
        }

        let installed = try manager.perform(.install, in: scope)
        guard installed.operation == .install,
              installed.backupID != nil,
              installed.record(for: .codex)?.statusAfter == .installed,
              installed.record(for: .claudeCode)?.statusAfter == .installed,
              installed.record(for: .cursor)?.statusAfter == .installed,
              installed.record(for: .zcode)?.statusAfter == .installed,
              installed.record(for: .omp)?.statusAfter == .installed,
              // 闸门的令牌必须与 hooks.json 一起落到隔离的 scope 里，
              // 而不是漏写进用户真实的 ~/.codex。
              fileManager.fileExists(
                  atPath: root.appendingPathComponent(".codex/hooks.json").path
              ),
              CodexHookConfiguration.authenticationToken(
                  for: root.appendingPathComponent(".codex/hooks.json")
              ) != nil
        else {
            failIntegrationManagerSelfTest("five-agent install")
        }

        let repeated = try manager.perform(.install, in: scope)
        guard repeated.agents.allSatisfy({ $0.result == .unchanged }) else {
            failIntegrationManagerSelfTest("repeated install")
        }

        let uninstalled = try manager.perform(.uninstall, in: scope)
        guard uninstalled.agents.allSatisfy({ record in
            record.result == .uninstalled && record.statusAfter == .notInstalled
        }), try fixtures.unrelatedConfigurationIsPreserved()
        else {
            failIntegrationManagerSelfTest("five-agent uninstall/preservation")
        }

        let repaired = try manager.perform(.repair, in: scope)
        guard repaired.agents.allSatisfy({ record in
            record.result == .repaired && record.statusAfter == .installed
        }) else {
            failIntegrationManagerSelfTest("five-agent repair")
        }

        guard let originalBackupID = installed.backupID else {
            failIntegrationManagerSelfTest("install backup ID")
        }
        let backupDirectory = root.appendingPathComponent(
            "Library/Application Support/ThreadHelm/Integration Backups/"
                + originalBackupID,
            isDirectory: true
        )
        let backupPermissions = try fileManager.attributesOfItem(
            atPath: backupDirectory.path
        )[.posixPermissions] as? NSNumber
        let manifestPermissions = try fileManager.attributesOfItem(
            atPath: backupDirectory.appendingPathComponent("manifest.json").path
        )[.posixPermissions] as? NSNumber
        guard (backupPermissions?.intValue ?? -1) & 0o777 == 0o700,
              (manifestPermissions?.intValue ?? -1) & 0o777 == 0o600
        else {
            failIntegrationManagerSelfTest("owner-only backup permissions")
        }
        let restored = try manager.restoreBackup(
            id: originalBackupID,
            in: scope
        )
        guard restored.operation == .restore,
              restored.restoredBackupID == originalBackupID,
              try fixtures.matchesOriginalBytes(),
              !fileManager.fileExists(
                  atPath: fixtures.ompManagedDirectory.path
              )
        else {
            failIntegrationManagerSelfTest("backup restore drill")
        }

        try runIntegrationManagerRollbackSelfTest(
            root: root.appendingPathComponent("rollback", isDirectory: true)
        )
        try runIntegrationManagerInstallGateSelfTest(
            root: root.appendingPathComponent("version-gate", isDirectory: true)
        )
        try runLegacyClaudeHookInstallGateSelfTest(
            root: root.appendingPathComponent(
                "legacy-claude-install-gate",
                isDirectory: true
            )
        )
        try runIntegrationAtomicWriteFailureSelfTest(
            root: root.appendingPathComponent("atomic", isDirectory: true)
        )
        try runIntegrationRestoreAtomicitySelfTest(
            root: root.appendingPathComponent(
                "restore-atomicity",
                isDirectory: true
            )
        )
        try runSingleAgentTargetedSelfTest(
            root: root.appendingPathComponent(
                "single-agent-target",
                isDirectory: true
            )
        )
        try runSingleAgentTargetedRollbackSelfTest(
            root: root.appendingPathComponent(
                "single-agent-target-rollback",
                isDirectory: true
            )
        )
        runIntegrationCLIParsingSelfTest(root: root)
    } catch {
        failIntegrationManagerSelfTest("unexpected error: \(error)")
    }
}

private func runSingleAgentTargetedSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let fixtures = try makeIntegrationManagerFixtures(at: root)
    let registry = makeIntegrationManagerRegistry()
    let manager = AgentIntegrationManager(registry: registry)
    let scope = AgentIntegrationScope.isolated(at: root)

    let cursorReport = try manager.perform(.install, targetAgentID: .cursor, in: scope)
    guard cursorReport.operation == .install,
          cursorReport.backupID != nil,
          cursorReport.agents.count == 1,
          cursorReport.agents.first?.agentID == .cursor,
          cursorReport.agents.first?.result == .installed,
          cursorReport.agents.first?.statusAfter == .installed,
          try Data(contentsOf: fixtures.claudeURL) == fixtures.originalClaude,
          try Data(contentsOf: fixtures.zcodeURL) == fixtures.originalZCode,
          try Data(contentsOf: fixtures.ompUnrelatedURL) == fixtures.unrelatedOMP,
          !fileManager.fileExists(atPath: fixtures.ompManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "single-agent targeted install did not isolate modification to Cursor"
        )
    }

    let cursorRepeat = try manager.perform(.install, targetAgentID: .cursor, in: scope)
    guard cursorRepeat.agents.first?.result == .unchanged else {
        throw IntegrationManagerSelfTestError.assertion(
            "single-agent targeted repeat install must return unchanged"
        )
    }

    let driftedManager = AgentIntegrationManager(
        registry: makeIntegrationManagerRegistry(compatibility: .unvalidated)
    )
    let driftedScope = AgentIntegrationScope.isolated(at: root.appendingPathComponent("drifted", isDirectory: true))
    try fileManager.createDirectory(at: driftedScope.rootDirectory, withIntermediateDirectories: true)
    // 版本漂移必须照常安装。要求 validated 会形成循环依赖——探测要 hook 在跑，
    // 跑要先装上——而四家 Agent 都漂移过，稳定态就是谁都装不上。装上之后契约
    // 若不对，探测会降级并诚实报 needsRepair。
    let unvalidatedReport = try driftedManager.perform(
        AgentIntegrationOperation.install,
        targetAgentID: AgentID.cursor,
        in: driftedScope
    )
    guard unvalidatedReport.agents.first?.result == .installed else {
        throw IntegrationManagerSelfTestError.assertion(
            "drifted target install must proceed, not silently skip"
        )
    }

    guard fileManager.fileExists(
        atPath: driftedScope.rootDirectory
            .appendingPathComponent(".cursor/hooks.json").path
    ) else {
        throw IntegrationManagerSelfTestError.assertion(
            "drifted target must still write its managed configuration"
        )
    }

    // 未安装的 Agent 仍然一律不动：没有宿主可挂，写配置就是往用户机器上
    // 塞垃圾。这是放开版本闸之后剩下的唯一前置条件。
    let absentManager = AgentIntegrationManager(
        registry: makeIntegrationManagerRegistry(
            compatibility: .unknown,
            isInstalled: false
        )
    )
    let absentScope = AgentIntegrationScope.isolated(
        at: root.appendingPathComponent("absent", isDirectory: true)
    )
    try fileManager.createDirectory(
        at: absentScope.rootDirectory,
        withIntermediateDirectories: true
    )
    let absentReport = try absentManager.perform(
        AgentIntegrationOperation.install,
        targetAgentID: AgentID.cursor,
        in: absentScope
    )
    guard absentReport.agents.first?.result == .unchanged else {
        throw IntegrationManagerSelfTestError.assertion(
            "absent agent install must return unchanged"
        )
    }
    guard !fileManager.fileExists(
        atPath: absentScope.rootDirectory
            .appendingPathComponent(".cursor/hooks.json").path
    ) else {
        throw IntegrationManagerSelfTestError.assertion(
            "absent agent must not create vendor configuration"
        )
    }

    let emptyRegistry = AgentRegistry(adapters: [])
    let emptyManager = AgentIntegrationManager(registry: emptyRegistry)
    do {
        _ = try emptyManager.perform(.install, targetAgentID: .cursor, in: scope)
        throw IntegrationManagerSelfTestError.assertion(
            "single-agent with missing adapter must throw error"
        )
    } catch is AgentIntegrationManagerError {
        // Expected
    }
}

/// 定向失败回滚：备份范围已收敛到单个 Agent，因此失败回滚也必须只还原该
/// Agent 的受管路径，且其他 Agent 的宿主配置全程字节不变。
private func runSingleAgentTargetedRollbackSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let claudeURL = root.appendingPathComponent(".claude/settings.json")
    try fileManager.createDirectory(
        at: claudeURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let claudeOriginal = Data(#"{"model":"targeted-rollback-bystander"}"#.utf8)
    try claudeOriginal.write(to: claudeURL)

    let failureURL = root.appendingPathComponent(
        WritingThenFailingManagedAdapter.managedRelativePath
    )
    try fileManager.createDirectory(
        at: failureURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let failureOriginal = Data(#"{"owner":"targeted-rollback-original"}"#.utf8)
    try failureOriginal.write(to: failureURL)

    let installed = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .validated
        )
    }
    let registry = AgentRegistry(adapters: [
        ClaudeCodeAgentAdapter(
            readCollection: { .displaying([]) },
            discovery: installed
        ),
        WritingThenFailingManagedAdapter(),
    ])
    let manager = AgentIntegrationManager(registry: registry)
    let failureAgentID = WritingThenFailingManagedAdapter.agentID

    do {
        _ = try manager.perform(
            .install,
            targetAgentID: failureAgentID,
            in: .isolated(at: root)
        )
        throw IntegrationManagerSelfTestError.assertion(
            "targeted install on a failing adapter must throw"
        )
    } catch let error as AgentIntegrationManagerError {
        guard error.didRollback, error.agentID == failureAgentID else {
            throw IntegrationManagerSelfTestError.assertion(
                "targeted rollback must report didRollback and the failing agent"
            )
        }
    }

    // 该 adapter 会先写入垃圾再抛错，所以这条断言只有在回滚真的发生、
    // 且备份作用域确实包含了目标 Agent 时才成立。
    guard try Data(contentsOf: failureURL) == failureOriginal else {
        throw IntegrationManagerSelfTestError.assertion(
            "targeted rollback must restore the target agent byte-for-byte"
        )
    }
    guard try Data(contentsOf: claudeURL) == claudeOriginal else {
        throw IntegrationManagerSelfTestError.assertion(
            "targeted rollback must leave other agents untouched"
        )
    }

    // 封死"备份作用域过宽"这一侧：清单里记录的路径必须恰好是目标 Agent 的
    // 受管路径，绝不能把其他 Agent 的配置一起纳入备份与回滚范围。
    try assertTargetedBackupScope(
        root: root,
        expectedRelativePaths: [
            WritingThenFailingManagedAdapter.managedRelativePath,
        ]
    )
}

/// 读取本次运行留下的备份清单，断言其覆盖范围。
private func assertTargetedBackupScope(
    root: URL,
    expectedRelativePaths: [String]
) throws {
    let fileManager = FileManager.default
    let backupRoot = root
        .appendingPathComponent(
            "Library/Application Support/ThreadHelm/Integration Backups",
            isDirectory: true
        )
    let backups = try fileManager.contentsOfDirectory(
        at: backupRoot,
        includingPropertiesForKeys: nil
    )
    guard backups.count == 1 else {
        throw IntegrationManagerSelfTestError.assertion(
            "targeted run must leave exactly one backup, found \(backups.count)"
        )
    }
    let manifestURL = backups[0].appendingPathComponent("manifest.json")
    guard
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as? [String: Any],
        let items = manifest["items"] as? [[String: Any]]
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "targeted backup manifest is unreadable"
        )
    }
    let recorded = Set(items.compactMap { $0["relativePath"] as? String })
    guard recorded == Set(expectedRelativePaths) else {
        throw IntegrationManagerSelfTestError.assertion(
            "targeted backup scope must cover exactly the target agent paths; "
                + "expected \(Set(expectedRelativePaths)), got \(recorded)"
        )
    }
}

private struct IntegrationManagerFixtures {
    let root: URL
    let originalClaude: Data
    let originalCursor: Data
    let originalZCode: Data
    let unrelatedOMP: Data

    var claudeURL: URL {
        root.appendingPathComponent(".claude/settings.json")
    }

    var cursorURL: URL {
        root.appendingPathComponent(".cursor/hooks.json")
    }

    var zcodeURL: URL {
        root.appendingPathComponent(".zcode/cli/config.json")
    }

    var ompUnrelatedURL: URL {
        root.appendingPathComponent(
            ".omp/agent/extensions/user-owned/index.ts"
        )
    }

    var ompManagedDirectory: URL {
        root.appendingPathComponent(
            ".omp/agent/extensions/threadhelm-state-observer",
            isDirectory: true
        )
    }

    func matchesOriginalBytes() throws -> Bool {
        try Data(contentsOf: claudeURL) == originalClaude
            && Data(contentsOf: cursorURL) == originalCursor
            && Data(contentsOf: zcodeURL) == originalZCode
            && Data(contentsOf: ompUnrelatedURL) == unrelatedOMP
    }

    func unrelatedConfigurationIsPreserved() throws -> Bool {
        let claude = try JSONSerialization.jsonObject(
            with: Data(contentsOf: claudeURL)
        ) as? [String: Any]
        let cursor = try JSONSerialization.jsonObject(
            with: Data(contentsOf: cursorURL)
        ) as? [String: Any]
        let zcode = try JSONSerialization.jsonObject(
            with: Data(contentsOf: zcodeURL)
        ) as? [String: Any]
        let ompData = try Data(contentsOf: ompUnrelatedURL)
        return claude?["model"] as? String == "keep-claude"
            && cursor?["keep"] as? String == "keep-cursor"
            && zcode?["keep"] as? String == "keep-zcode"
            && ompData == unrelatedOMP
    }
}

private func makeIntegrationManagerFixtures(
    at root: URL
) throws -> IntegrationManagerFixtures {
    let originalClaude = Data(#"{"model":"keep-claude"}"#.utf8)
    let originalCursor = Data(#"{"version":1,"keep":"keep-cursor"}"#.utf8)
    let originalZCode = Data(
        #"{"hooks":{"enabled":true,"events":{}},"keep":"keep-zcode"}"#.utf8
    )
    let unrelatedOMP = Data("export default 'keep-omp'\n".utf8)
    let fixtures = IntegrationManagerFixtures(
        root: root,
        originalClaude: originalClaude,
        originalCursor: originalCursor,
        originalZCode: originalZCode,
        unrelatedOMP: unrelatedOMP
    )
    for (url, data) in [
        (fixtures.claudeURL, originalClaude),
        (fixtures.cursorURL, originalCursor),
        (fixtures.zcodeURL, originalZCode),
        (fixtures.ompUnrelatedURL, unrelatedOMP),
    ] {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
    return fixtures
}

private func makeIntegrationManagerRegistry(
    compatibility: AgentCompatibility = .validated,
    isInstalled: Bool = true
) -> AgentRegistry {
    let installed = {
        AgentDiscovery(
            isInstalled: isInstalled,
            version: isInstalled ? "self-test" : nil,
            compatibility: compatibility
        )
    }
    return AgentRegistry(adapters: [
        CodexAgentAdapter(
            readCollection: { .displaying([]) },
            discovery: installed,
            openURL: { _ in false }
        ),
        ClaudeCodeAgentAdapter(
            readCollection: { .displaying([]) },
            discovery: installed
        ),
        CursorAgentAdapter(
            discovery: installed,
            hookCommand: "/tmp/ThreadHelm --agent-hook cursor"
        ),
        ZCodeAgentAdapter(
            discovery: installed,
            executablePath: { "/tmp/ThreadHelm" }
        ),
        OMPAgentAdapter(
            discovery: installed,
            executablePath: { "/tmp/ThreadHelm" },
            timeoutStore: InMemoryOMPToolCallTimeoutStore(value: 600_000)
        ),
    ])
}

private func runIntegrationManagerInstallGateSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let fixtures = try makeIntegrationManagerFixtures(at: root)
    let scope = AgentIntegrationScope.isolated(at: root)
    let driftedManager = AgentIntegrationManager(
        registry: makeIntegrationManagerRegistry(compatibility: .unvalidated)
    )

    let status = driftedManager.status(in: scope)
    guard status.operation == .status,
          status.backupID == nil,
          try fixtures.matchesOriginalBytes(),
          !fileManager.fileExists(atPath: fixtures.ompManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "status must remain read-only for drifted versions"
        )
    }

    // 漂移版本照常安装。旧行为是在这里静默返回 unchanged，结果由于四家的
    // 发版节奏都不受我们控制，稳定态就是谁都装不上、功能默认关闭。
    let driftedInstall = try driftedManager.perform(.install, in: scope)
    guard driftedInstall.backupID != nil,
          driftedInstall.agents.count == 5,
          driftedInstall.agents.allSatisfy({ $0.statusAfter == .installed }),
          fileManager.fileExists(atPath: fixtures.ompManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "drifted-version install must proceed and write managed entries"
        )
    }
    // 装完再 repair 应当已是幂等的——受管条目就位后没有可修的东西。
    let driftedRepair = try driftedManager.perform(.repair, in: scope)
    guard driftedRepair.agents.allSatisfy({ $0.statusAfter == .installed }) else {
        throw IntegrationManagerSelfTestError.assertion(
            "repair after drifted install must keep entries installed"
        )
    }

    // 放开版本闸之后，唯一剩下的前置条件是宿主存在：Agent 没装就不该写它的
    // 配置，否则是往用户机器上塞一份永远不会被读取的文件。
    let absentScope = AgentIntegrationScope.isolated(
        at: root.appendingPathComponent("absent-host", isDirectory: true)
    )
    try fileManager.createDirectory(
        at: absentScope.rootDirectory,
        withIntermediateDirectories: true
    )
    let absentReport = try AgentIntegrationManager(
        registry: makeIntegrationManagerRegistry(
            compatibility: .unknown,
            isInstalled: false
        )
    ).perform(.install, in: absentScope)
    guard absentReport.agents.allSatisfy({ $0.result == .unchanged }),
          !fileManager.fileExists(
              atPath: absentScope.rootDirectory
                  .appendingPathComponent(".cursor/hooks.json").path
          )
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "absent agents must not receive managed configuration"
        )
    }
    let uninstalled = try driftedManager.perform(.uninstall, in: scope)
    guard uninstalled.agents.allSatisfy({ record in
        record.result == .uninstalled && record.statusAfter == .notInstalled
    }),
    try fixtures.unrelatedConfigurationIsPreserved(),
    !fileManager.fileExists(atPath: fixtures.ompManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "drifted-version uninstall must remove only ThreadHelm-owned entries"
        )
    }
}

/// 老的 `--install-claude-hook` 入口在版本漂移时该怎么办。
///
/// 断言方向在这里翻过来了。原来它要求「漂移就不写配置」，可那意味着
/// Claude 每发一版，安装脚本就静默跳过 hook，闸门整个消失，而用户只会
/// 觉得确认框不弹了——而且没有任何可执行的补救办法，因为他管不了上游
/// 发版节奏。安装是可逆的（受管条目带所有权标记、装前必备份、卸载只摘
/// 自己那几条），所以现在只看装没装。
private func runLegacyClaudeHookInstallGateSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeClaudeURL = root.appendingPathComponent("claude")
    try Data("#!/bin/zsh\nprint -r -- 'Claude Code 9.9.9'\n".utf8)
        .write(to: fakeClaudeURL)
    try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fakeClaudeURL.path
    )

    guard let executableURL = Bundle.main.executableURL else {
        throw IntegrationManagerSelfTestError.assertion(
            "current ThreadHelm executable is unavailable"
        )
    }
    let configDirectory = root.appendingPathComponent(
        "claude-config",
        isDirectory: true
    )
    let output = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--install-claude-hook"]
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_BIN"] = fakeClaudeURL.path
    environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let settingsURL = configDirectory.appendingPathComponent("settings.json")
    let settings = (try? Data(contentsOf: settingsURL))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    guard process.terminationStatus == 0,
          message.contains("已安装"),
          !message.contains("版本未验证"),
          settings.contains(ClaudeHookConstants.url)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "legacy Claude install must ignore version drift"
                + "（exit=\(process.terminationStatus) 输出=\(message)）"
        )
    }
}

private func runIntegrationManagerRollbackSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let settingsURL = root.appendingPathComponent(".claude/settings.json")
    try fileManager.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let original = Data(#"{"model":"rollback-original"}"#.utf8)
    try original.write(to: settingsURL)
    let installed = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .supported
        )
    }
    let registry = AgentRegistry(adapters: [
        ClaudeCodeAgentAdapter(
            readCollection: { .displaying([]) },
            discovery: installed
        ),
        FailingManagedAdapter(),
    ])
    let manager = AgentIntegrationManager(registry: registry)
    do {
        _ = try manager.perform(.install, in: .isolated(at: root))
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch let error as AgentIntegrationManagerError {
        guard error.didRollback else { throw error }
    }
    guard try Data(contentsOf: settingsURL) == original else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationAtomicWriteFailureSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("settings.json")
    let original = Data("original\n".utf8)
    try original.write(to: target)
    do {
        try AgentIntegrationAtomicFileWriter.write(
            Data("replacement\n".utf8),
            to: target,
            replace: { _, _ in
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        )
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    let leftovers = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains("threadhelm") }
    guard try Data(contentsOf: target) == original, leftovers.isEmpty else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationRestoreAtomicitySelfTest(root: URL) throws {
    try runIntegrationRestoreFileAtomicitySelfTest(
        root: root.appendingPathComponent("files", isDirectory: true)
    )
    try runIntegrationRestoreMissingAtomicitySelfTest(
        root: root.appendingPathComponent("missing", isDirectory: true)
    )
    try runIntegrationRestoreDirectoryAtomicitySelfTest(
        root: root.appendingPathComponent("directory", isDirectory: true)
    )
    try runIntegrationRestorePreparationFailureSelfTest(
        root: root.appendingPathComponent("prepare", isDirectory: true)
    )
    try runIntegrationRestoreSymlinkAtomicitySelfTest(
        root: root.appendingPathComponent("symlink", isDirectory: true)
    )
    try runIntegrationRestoreDanglingSymlinkBackupSelfTest(
        root: root.appendingPathComponent(
            "dangling-symlink-backup",
            isDirectory: true
        )
    )
    try runIntegrationRestoreParentBoundarySelfTest(
        root: root.appendingPathComponent(
            "parent-boundary",
            isDirectory: true
        )
    )
    try runIntegrationRestoreParentCleanupSelfTest(
        root: root.appendingPathComponent(
            "parent-cleanup",
            isDirectory: true
        )
    )
    try runIntegrationRestoreSafetyFailureReportingSelfTest(
        root: root.appendingPathComponent(
            "safety-failure-reporting",
            isDirectory: true
        )
    )
    try runIntegrationRestoreUnstatableTargetSelfTest(
        root: root.appendingPathComponent(
            "unstatable-target",
            isDirectory: true
        )
    )
    try runIntegrationRestoreRollbackFailureSelfTest(
        root: root.appendingPathComponent("rollback-failure", isDirectory: true)
    )
}

private func runIntegrationRestoreFileAtomicitySelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let firstURL = root.appendingPathComponent(".restore/first.json")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    try fileManager.createDirectory(
        at: firstURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let backedUpFirst = Data("backed-up-first\n".utf8)
    let backedUpSecond = Data("backed-up-second\n".utf8)
    try backedUpFirst.write(to: firstURL)
    try backedUpSecond.write(to: secondURL)

    let scope = AgentIntegrationScope.isolated(at: root)
    let backupStore = AgentIntegrationBackupStore(scope: scope)
    let backup = try backupStore.create(relativePaths: [
        ".restore/first.json",
        ".restore/second.json",
    ])
    let currentFirst = Data("current-first\n".utf8)
    let currentSecond = Data("current-second\n".utf8)
    try currentFirst.write(to: firstURL)
    try currentSecond.write(to: secondURL)

    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    do {
        try failingStore.restoreContents(id: backup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard try Data(contentsOf: firstURL) == currentFirst,
          try Data(contentsOf: secondURL) == currentSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationRestoreMissingAtomicitySelfTest(root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let missingURL = root.appendingPathComponent(".restore/delete-me.json")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    try fileManager.createDirectory(
        at: secondURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let backedUpSecond = Data("backed-up-second\n".utf8)
    try backedUpSecond.write(to: secondURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let backupStore = AgentIntegrationBackupStore(scope: scope)
    let backup = try backupStore.create(relativePaths: [
        ".restore/delete-me.json",
        ".restore/second.json",
    ])
    let currentMissingTarget = Data("current-delete-me\n".utf8)
    let currentSecond = Data("current-second\n".utf8)
    try currentMissingTarget.write(to: missingURL)
    try currentSecond.write(to: secondURL)
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    do {
        try failingStore.restoreContents(id: backup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard try Data(contentsOf: missingURL) == currentMissingTarget,
          try Data(contentsOf: secondURL) == currentSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
    try backupStore.restoreContents(id: backup.id)
    guard !fileManager.fileExists(atPath: missingURL.path),
          try Data(contentsOf: secondURL) == backedUpSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }

    let absentRelativePath = ".never-created/managed.json"
    let absentParentURL = root.appendingPathComponent(".never-created")
    let missingBackup = try backupStore.create(
        relativePaths: [absentRelativePath]
    )
    try backupStore.restoreContents(id: missingBackup.id)
    guard !fileManager.fileExists(atPath: absentParentURL.path) else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }

    let laterURL = root.appendingPathComponent(".restore/later.json")
    try Data("backed-up-later\n".utf8).write(to: laterURL)
    let missingThenFailureBackup = try backupStore.create(relativePaths: [
        absentRelativePath,
        ".restore/later.json",
    ])
    let currentLater = Data("current-later\n".utf8)
    try currentLater.write(to: laterURL)
    let missingThenFailureStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    do {
        try missingThenFailureStore.restoreContents(
            id: missingThenFailureBackup.id
        )
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard !fileManager.fileExists(atPath: absentParentURL.path),
          try Data(contentsOf: laterURL) == currentLater,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "missing no-op was treated as a rollback failure"
        )
    }
}

private func runIntegrationRestoreDirectoryAtomicitySelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let directoryURL = root.appendingPathComponent(
        ".restore/tree",
        isDirectory: true
    )
    let nestedURL = directoryURL.appendingPathComponent("nested/state.txt")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    try fileManager.createDirectory(
        at: nestedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let backedUpNested = Data("backed-up-directory\n".utf8)
    let backedUpSecond = Data("backed-up-second\n".utf8)
    try backedUpNested.write(to: nestedURL)
    try backedUpSecond.write(to: secondURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let backupStore = AgentIntegrationBackupStore(scope: scope)
    let backup = try backupStore.create(relativePaths: [
        ".restore/tree",
        ".restore/second.json",
    ])
    let currentNested = Data("current-directory\n".utf8)
    let currentSecond = Data("current-second\n".utf8)
    try currentNested.write(to: nestedURL)
    try currentSecond.write(to: secondURL)
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    do {
        try failingStore.restoreContents(id: backup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard try Data(contentsOf: nestedURL) == currentNested,
          try Data(contentsOf: secondURL) == currentSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationRestorePreparationFailureSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let firstURL = root.appendingPathComponent(".restore/first.json")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    try fileManager.createDirectory(
        at: firstURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("backup-first\n".utf8).write(to: firstURL)
    try Data("backup-second\n".utf8).write(to: secondURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [
        ".restore/first.json",
        ".restore/second.json",
    ])
    let currentFirst = Data("current-first\n".utf8)
    let currentSecond = Data("current-second\n".utf8)
    try currentFirst.write(to: firstURL)
    try currentSecond.write(to: secondURL)
    let missingPayload = integrationBackupDirectory(root: root, id: backup.id)
        .appendingPathComponent("payload/1")
    try fileManager.removeItem(at: missingPayload)
    var failedAsExpected = false
    do {
        try store.restoreContents(id: backup.id)
    } catch {
        failedAsExpected = true
    }
    guard failedAsExpected,
          try Data(contentsOf: firstURL) == currentFirst,
          try Data(contentsOf: secondURL) == currentSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationRestoreSymlinkAtomicitySelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let linkURL = root.appendingPathComponent(".restore/managed-link")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    let backupDestination = root.appendingPathComponent("backup-target.txt")
    let currentDanglingDestination = root.appendingPathComponent(
        "current-missing-target.txt"
    )
    try fileManager.createDirectory(
        at: linkURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("backup-target\n".utf8).write(to: backupDestination)
    try fileManager.createSymbolicLink(
        atPath: linkURL.path,
        withDestinationPath: backupDestination.path
    )
    try Data("backup-second\n".utf8).write(to: secondURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [
        ".restore/managed-link",
        ".restore/second.json",
    ])
    try fileManager.removeItem(at: linkURL)
    try fileManager.createSymbolicLink(
        atPath: linkURL.path,
        withDestinationPath: currentDanglingDestination.path
    )
    let currentSecond = Data("current-second\n".utf8)
    try currentSecond.write(to: secondURL)
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    do {
        try failingStore.restoreContents(id: backup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
            == currentDanglingDestination.path,
          try Data(contentsOf: secondURL) == currentSecond,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.expectedFailure
    }
}

private func runIntegrationRestoreDanglingSymlinkBackupSelfTest(
    root: URL
) throws {
    let fileManager = FileManager.default
    let linkURL = root.appendingPathComponent(".restore/managed-link")
    let missingDestination = root.appendingPathComponent("missing-target.txt")
    try fileManager.createDirectory(
        at: linkURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try fileManager.createSymbolicLink(
        atPath: linkURL.path,
        withDestinationPath: missingDestination.path
    )
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [".restore/managed-link"])
    try fileManager.removeItem(at: linkURL)
    try Data("replacement\n".utf8).write(to: linkURL)

    try store.restoreContents(id: backup.id)

    guard try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
            == missingDestination.path,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "dangling symlink backup was not restored"
        )
    }
}

private func runIntegrationRestoreParentBoundarySelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let managedDirectory = root.appendingPathComponent(
        ".redirect",
        isDirectory: true
    )
    let managedURL = managedDirectory.appendingPathComponent("item.json")
    try fileManager.createDirectory(
        at: managedDirectory,
        withIntermediateDirectories: true
    )
    try Data("backup\n".utf8).write(to: managedURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [".redirect/item.json"])
    try fileManager.removeItem(at: managedDirectory)

    let outsideDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "threadhelm-restore-outside-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: outsideDirectory) }
    try fileManager.createDirectory(
        at: outsideDirectory,
        withIntermediateDirectories: true
    )
    try fileManager.createSymbolicLink(
        atPath: managedDirectory.path,
        withDestinationPath: outsideDirectory.path
    )

    var rejected = false
    do {
        try store.restoreContents(id: backup.id)
    } catch AgentIntegrationError.invalidManagedPath {
        rejected = true
    }
    guard rejected,
          !fileManager.fileExists(
              atPath: outsideDirectory.appendingPathComponent("item.json").path
          ),
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "external parent symlink was not rejected"
        )
    }
}

private func runIntegrationRestoreParentCleanupSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let keptDirectory = root.appendingPathComponent(".kept", isDirectory: true)
    let createdDirectory = keptDirectory.appendingPathComponent(
        "new/deep",
        isDirectory: true
    )
    let targetURL = createdDirectory.appendingPathComponent("item.json")
    try fileManager.createDirectory(
        at: createdDirectory,
        withIntermediateDirectories: true
    )
    try Data("backup\n".utf8).write(to: targetURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [".kept/new/deep/item.json"])
    try fileManager.removeItem(
        at: keptDirectory.appendingPathComponent("new", isDirectory: true)
    )
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { _, _ in
            throw IntegrationManagerSelfTestError.injectedWriteFailure
        }
    )
    do {
        try failingStore.restoreContents(id: backup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard fileManager.fileExists(atPath: keptDirectory.path),
          !fileManager.fileExists(
              atPath: keptDirectory.appendingPathComponent("new").path
          ),
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "new restore parent directories were not rolled back"
        )
    }

    let existingDirectory = root.appendingPathComponent(
        ".existing",
        isDirectory: true
    )
    let existingTarget = existingDirectory.appendingPathComponent("item.json")
    try fileManager.createDirectory(
        at: existingDirectory,
        withIntermediateDirectories: true
    )
    try Data("backup\n".utf8).write(to: existingTarget)
    let existingBackup = try store.create(
        relativePaths: [".existing/item.json"]
    )
    try fileManager.removeItem(at: existingTarget)
    do {
        try failingStore.restoreContents(id: existingBackup.id)
        throw IntegrationManagerSelfTestError.expectedFailure
    } catch IntegrationManagerSelfTestError.injectedWriteFailure {
    }
    guard fileManager.fileExists(atPath: existingDirectory.path),
          !fileManager.fileExists(atPath: existingTarget.path),
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "pre-existing restore parent directory was not preserved"
        )
    }
}

private func runIntegrationRestoreSafetyFailureReportingSelfTest(
    root: URL
) throws {
    let fileManager = FileManager.default
    let targetURL = root.appendingPathComponent(".restore/item.json")
    try fileManager.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("backup\n".utf8).write(to: targetURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let normalStore = AgentIntegrationBackupStore(scope: scope)
    let backup = try normalStore.create(relativePaths: [".restore/item.json"])
    let currentData = Data("current\n".utf8)
    try currentData.write(to: targetURL)
    let primaryMessage = "primary restore injected failure"
    let safetyMessage = "safety restore injected failure"
    var primaryOnlyAttempts = 0
    let primaryOnlyStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { _, _ in
            primaryOnlyAttempts += 1
            if primaryOnlyAttempts == 1 {
                throw NSError(
                    domain: "ThreadHelmRestoreSelfTest",
                    code: primaryOnlyAttempts,
                    userInfo: [NSLocalizedDescriptionKey: primaryMessage]
                )
            }
        }
    )
    var safetyRestoreSucceeded = false
    do {
        _ = try primaryOnlyStore.restore(id: backup.id)
    } catch let error as AgentIntegrationBackupError {
        if case .primaryRestoreFailed(let primary, let safetyBackupID) = error {
            safetyRestoreSucceeded = primary.contains(primaryMessage)
                && !safetyBackupID.isEmpty
                && error.restoredSafetyBackup
        }
    }
    guard safetyRestoreSucceeded,
          primaryOnlyAttempts == 2,
          try Data(contentsOf: targetURL) == currentData
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "successful safety restore was not reported"
        )
    }

    var installAttempts = 0
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { _, _ in
            installAttempts += 1
            let message = installAttempts == 1
                ? primaryMessage
                : safetyMessage
            throw NSError(
                domain: "ThreadHelmRestoreSelfTest",
                code: installAttempts,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    )
    var bothFailuresReported = false
    do {
        _ = try failingStore.restore(id: backup.id)
    } catch AgentIntegrationBackupError.safetyRestoreFailed(
        let primary,
        let rollback,
        let safetyBackupID
    ) {
        bothFailuresReported = primary.contains(primaryMessage)
            && rollback.contains(safetyMessage)
            && !safetyBackupID.isEmpty
    }
    guard bothFailuresReported,
          installAttempts == 2,
          try Data(contentsOf: targetURL) == currentData,
          try integrationRestoreTransactionURLs(in: root).isEmpty
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "failed safety restore was not reported"
        )
    }
}

private func runIntegrationRestoreUnstatableTargetSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let parentURL = root.appendingPathComponent(".unstat", isDirectory: true)
    let targetURL = parentURL.appendingPathComponent("item.json")
    let secondURL = root.appendingPathComponent(".restore/second.json")
    try fileManager.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: secondURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("backup-target\n".utf8).write(to: targetURL)
    try Data("backup-second\n".utf8).write(to: secondURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [
        ".unstat/item.json",
        ".restore/second.json",
    ])
    try fileManager.removeItem(at: targetURL)
    try Data("current-second\n".utf8).write(to: secondURL)

    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { index, _ in
            if index == 1 {
                try fileManager.removeItem(at: parentURL)
                try Data("blocking-parent\n".utf8).write(to: parentURL)
                throw IntegrationManagerSelfTestError.injectedWriteFailure
            }
        }
    )
    var rollbackFailureReported = false
    do {
        try failingStore.restoreContents(id: backup.id)
    } catch AgentIntegrationBackupError.restoreRollbackFailed {
        rollbackFailureReported = true
    }
    guard rollbackFailureReported,
          try integrationRestoreTransactionURLs(in: root).count == 1
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "non-ENOENT target lookup was mistaken for a missing no-op"
        )
    }
}

private func runIntegrationRestoreRollbackFailureSelfTest(root: URL) throws {
    let fileManager = FileManager.default
    let targetURL = root.appendingPathComponent(".blocked/item.json")
    let parentURL = targetURL.deletingLastPathComponent()
    try fileManager.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true
    )
    try Data("backup\n".utf8).write(to: targetURL)
    let scope = AgentIntegrationScope.isolated(at: root)
    let store = AgentIntegrationBackupStore(scope: scope)
    let backup = try store.create(relativePaths: [".blocked/item.json"])
    try Data("current\n".utf8).write(to: targetURL)
    let failingStore = AgentIntegrationBackupStore(
        scope: scope,
        beforeRestoredItemInstall: { _, _ in
            try fileManager.removeItem(at: parentURL)
            try Data("blocking-parent\n".utf8).write(to: parentURL)
            throw IntegrationManagerSelfTestError.injectedWriteFailure
        }
    )
    var rollbackFailureTransactionPath: String?
    do {
        try failingStore.restoreContents(id: backup.id)
    } catch AgentIntegrationBackupError.restoreRollbackFailed(
        _,
        let transactionPath
    ) {
        rollbackFailureTransactionPath = transactionPath
    }
    let transactions = try integrationRestoreTransactionURLs(in: root)
    let reportedTransactionURL = rollbackFailureTransactionPath.map {
        URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
    }
    guard let reportedTransactionURL,
          transactions.count == 1,
          transactions[0].standardizedFileURL.resolvingSymlinksInPath()
            == reportedTransactionURL
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "rollback failure transaction was not preserved: reported="
                + "\(rollbackFailureTransactionPath ?? "nil") actual="
                + transactions.map(\.path).joined(separator: ",")
        )
    }
}

private func integrationBackupDirectory(root: URL, id: String) -> URL {
    root.appendingPathComponent(
        "Library/Application Support/ThreadHelm/Integration Backups/\(id)",
        isDirectory: true
    )
}

private func integrationRestoreTransactionURLs(in root: URL) throws -> [URL] {
    let fileManager = FileManager.default
    let backupRoot = root.appendingPathComponent(
        "Library/Application Support/ThreadHelm/Integration Backups",
        isDirectory: true
    )
    guard fileManager.fileExists(atPath: backupRoot.path) else { return [] }
    return try fileManager.contentsOfDirectory(
        at: backupRoot,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".restore-transaction-") }
}

private func runIntegrationCLIParsingSelfTest(root: URL) {
    for operation in ["status", "install", "repair", "uninstall"] {
        guard let command = try? AgentIntegrationCLI.parse(arguments: [
            "ThreadHelm",
            "--agent-integrations",
            operation,
            "--root",
            root.path,
        ]), command.scope.rootDirectory == root.standardizedFileURL,
        !command.scope.permitsLiveConfigurationChanges
        else {
            failIntegrationManagerSelfTest("isolated CLI \(operation)")
        }
    }
    guard (try? AgentIntegrationCLI.parse(arguments: [
        "ThreadHelm", "--agent-integrations", "install",
    ])) == nil,
    (try? AgentIntegrationCLI.parse(arguments: [
        "ThreadHelm", "--agent-integrations", "install", "--root", "/",
    ])) == nil,
    (try? AgentIntegrationCLI.parse(arguments: [
        "ThreadHelm", "--agent-integrations", "install", "--live",
    ]))?.scope.permitsLiveConfigurationChanges == true
    else {
        failIntegrationManagerSelfTest("CLI requires explicit --root/--live")
    }
    // 退出码为 0 说明不了什么：`--agent` 就算被解析后丢弃、仍然全量执行，
    // 这条也照样绿。必须断言解析结果本身，以及作用域真的收窄到了一个 Agent。
    let targeted = [
        "ThreadHelm",
        "--agent-integrations",
        "status",
        "--agent",
        "omp",
        "--root",
        root.path,
    ]
    guard let parsed = try? AgentIntegrationCLI.parse(arguments: targeted),
          parsed.targetAgentID == .omp,
          parsed.operation == .status,
          parsed.scope.rootDirectory.path == root.path
    else {
        failIntegrationManagerSelfTest("CLI --agent 未被解析成目标 Agent")
    }
    guard AgentIntegrationCLI.runIfRequested(arguments: targeted) == 0 else {
        failIntegrationManagerSelfTest("CLI targeted status")
    }
    // 关键：断言**分发的产物**，而不是绕过 CLI 直接调 manager。
    // 目标 Agent 若在分发处漏传，上面的解析断言和退出码都不会变红。
    guard let targetedReport = try? AgentIntegrationCLI.makeReport(
        for: parsed
    ),
        targetedReport.agents.count == 1,
        targetedReport.agents.first?.agentID == .omp
    else {
        failIntegrationManagerSelfTest("CLI 分发必须把作用域收窄到目标 Agent")
    }
    guard let fullCommand = try? AgentIntegrationCLI.parse(arguments: [
        "ThreadHelm", "--agent-integrations", "status", "--root", root.path,
    ]),
        let fullReport = try? AgentIntegrationCLI.makeReport(for: fullCommand),
        fullReport.agents.count == AgentID.builtInOrder.count
    else {
        failIntegrationManagerSelfTest("不传目标时必须保持全量")
    }

    // 四种必须 fail-closed 的组合。任何一条被悄悄放行都比解析错误更危险：
    // 它会让用户以为自己限定了范围，实际却在全量改写厂商配置。
    for rejected in [
        // 未知 Agent
        ["ThreadHelm", "--agent-integrations", "status", "--agent", "nosuchagent", "--root", root.path],
        // --agent 缺参数
        ["ThreadHelm", "--agent-integrations", "status", "--agent", "--root", root.path],
        // restore 不接受目标 Agent（备份是跨 Agent 的）
        ["ThreadHelm", "--agent-integrations", "restore", "FAKE", "--agent", "omp", "--root", root.path],
        // --agent 写在 scope 之后必须报错，不能被静默忽略
        ["ThreadHelm", "--agent-integrations", "status", "--root", root.path, "--agent", "omp"],
    ] {
        guard (try? AgentIntegrationCLI.parse(arguments: rejected)) == nil else {
            failIntegrationManagerSelfTest(
                "CLI 必须拒绝：\(rejected.dropFirst().joined(separator: " "))"
            )
        }
    }
}

private extension AgentIntegrationRunReport {
    func record(for agentID: AgentID) -> AgentIntegrationRunRecord? {
        agents.first(where: { $0.agentID == agentID })
    }
}

private func failIntegrationManagerSelfTest(_ message: String) -> Never {
    fputs("agent integration manager self-test failed: \(message)\n", stderr)
    exit(1)
}
