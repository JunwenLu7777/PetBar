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
              status.record(for: .codex)?.statusAfter == .notManaged,
              status.record(for: .claudeCode)?.statusAfter == .notInstalled,
              status.record(for: .cursor)?.statusAfter == .notInstalled,
              status.record(for: .zcode)?.statusAfter == .notInstalled,
              status.record(for: .pi)?.statusAfter == .notInstalled
        else {
            failIntegrationManagerSelfTest("five-agent status")
        }

        let installed = try manager.perform(.install, in: scope)
        guard installed.operation == .install,
              installed.backupID != nil,
              installed.record(for: .codex)?.result == .notManaged,
              installed.record(for: .claudeCode)?.statusAfter == .installed,
              installed.record(for: .cursor)?.statusAfter == .installed,
              installed.record(for: .zcode)?.statusAfter == .installed,
              installed.record(for: .pi)?.statusAfter == .installed,
              !fileManager.fileExists(
                  atPath: root.appendingPathComponent(".codex").path
              )
        else {
            failIntegrationManagerSelfTest("five-agent install/Codex no-op")
        }

        let repeated = try manager.perform(.install, in: scope)
        guard repeated.agents.filter({ $0.agentID != .codex }).allSatisfy({
            $0.result == .unchanged
        }) else {
            failIntegrationManagerSelfTest("repeated install")
        }

        let uninstalled = try manager.perform(.uninstall, in: scope)
        guard uninstalled.agents.allSatisfy({ record in
            record.agentID == .codex
                ? record.result == .notManaged
                : record.result == .uninstalled
                    && record.statusAfter == .notInstalled
        }), try fixtures.unrelatedConfigurationIsPreserved()
        else {
            failIntegrationManagerSelfTest("five-agent uninstall/preservation")
        }

        let repaired = try manager.perform(.repair, in: scope)
        guard repaired.agents.allSatisfy({ record in
            record.agentID == .codex
                ? record.result == .notManaged
                : record.result == .repaired
                    && record.statusAfter == .installed
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
                  atPath: fixtures.piManagedDirectory.path
              )
        else {
            failIntegrationManagerSelfTest("backup restore drill")
        }

        try runIntegrationManagerRollbackSelfTest(
            root: root.appendingPathComponent("rollback", isDirectory: true)
        )
        try runIntegrationManagerVersionGateSelfTest(
            root: root.appendingPathComponent("version-gate", isDirectory: true)
        )
        try runLegacyClaudeHookVersionGateSelfTest(
            root: root.appendingPathComponent(
                "legacy-claude-version-gate",
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
        runIntegrationCLIParsingSelfTest(root: root)
    } catch {
        failIntegrationManagerSelfTest("unexpected error: \(error)")
    }
}

private struct IntegrationManagerFixtures {
    let root: URL
    let originalClaude: Data
    let originalCursor: Data
    let originalZCode: Data
    let unrelatedPi: Data

    var claudeURL: URL {
        root.appendingPathComponent(".claude/settings.json")
    }

    var cursorURL: URL {
        root.appendingPathComponent(".cursor/hooks.json")
    }

    var zcodeURL: URL {
        root.appendingPathComponent(".zcode/cli/config.json")
    }

    var piUnrelatedURL: URL {
        root.appendingPathComponent(
            ".pi/agent/extensions/user-owned/index.ts"
        )
    }

    var piManagedDirectory: URL {
        root.appendingPathComponent(
            ".pi/agent/extensions/threadhelm-state-observer",
            isDirectory: true
        )
    }

    func matchesOriginalBytes() throws -> Bool {
        try Data(contentsOf: claudeURL) == originalClaude
            && Data(contentsOf: cursorURL) == originalCursor
            && Data(contentsOf: zcodeURL) == originalZCode
            && Data(contentsOf: piUnrelatedURL) == unrelatedPi
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
        let piData = try Data(contentsOf: piUnrelatedURL)
        return claude?["model"] as? String == "keep-claude"
            && cursor?["keep"] as? String == "keep-cursor"
            && zcode?["keep"] as? String == "keep-zcode"
            && piData == unrelatedPi
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
    let unrelatedPi = Data("export default 'keep-pi'\n".utf8)
    let fixtures = IntegrationManagerFixtures(
        root: root,
        originalClaude: originalClaude,
        originalCursor: originalCursor,
        originalZCode: originalZCode,
        unrelatedPi: unrelatedPi
    )
    for (url, data) in [
        (fixtures.claudeURL, originalClaude),
        (fixtures.cursorURL, originalCursor),
        (fixtures.zcodeURL, originalZCode),
        (fixtures.piUnrelatedURL, unrelatedPi),
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
    compatibility: AgentCompatibility = .validated
) -> AgentRegistry {
    let installed = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
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
        PiAgentAdapter(
            discovery: installed,
            executablePath: { "/tmp/ThreadHelm" }
        ),
    ])
}

private func runIntegrationManagerVersionGateSelfTest(root: URL) throws {
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
          !fileManager.fileExists(atPath: fixtures.piManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "status must remain read-only for drifted versions"
        )
    }

    for operation in [
        AgentIntegrationOperation.install,
        AgentIntegrationOperation.repair,
    ] {
        let report = try driftedManager.perform(operation, in: scope)
        let managedRecords = report.agents.filter { $0.agentID != .codex }
        guard report.operation == operation,
              report.backupID != nil,
              managedRecords.count == 4,
              managedRecords.allSatisfy({
                  $0.result == .unchanged
                      && $0.statusBefore == .notInstalled
                      && $0.statusAfter == .notInstalled
              }),
              try fixtures.matchesOriginalBytes(),
              !fileManager.fileExists(atPath: fixtures.piManagedDirectory.path)
        else {
            throw IntegrationManagerSelfTestError.assertion(
                "\(operation.rawValue) changed drifted-version configuration"
            )
        }
    }

    let validatedManager = AgentIntegrationManager(
        registry: makeIntegrationManagerRegistry()
    )
    _ = try validatedManager.perform(.install, in: scope)
    let uninstalled = try driftedManager.perform(.uninstall, in: scope)
    guard uninstalled.agents.allSatisfy({ record in
        record.agentID == .codex
            ? record.result == .notManaged
            : record.result == .uninstalled
                && record.statusAfter == .notInstalled
    }),
    try fixtures.unrelatedConfigurationIsPreserved(),
    !fileManager.fileExists(atPath: fixtures.piManagedDirectory.path)
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "drifted-version uninstall must remove only ThreadHelm-owned entries"
        )
    }
}

private func runLegacyClaudeHookVersionGateSelfTest(root: URL) throws {
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
    guard process.terminationStatus == 0,
          message.contains("版本未验证"),
          !fileManager.fileExists(
              atPath: configDirectory.appendingPathComponent("settings.json").path
          )
    else {
        throw IntegrationManagerSelfTestError.assertion(
            "legacy Claude install wrote configuration for a drifted version"
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
