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
        try runIntegrationAtomicWriteFailureSelfTest(
            root: root.appendingPathComponent("atomic", isDirectory: true)
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

private func makeIntegrationManagerRegistry() -> AgentRegistry {
    let installed = {
        AgentDiscovery(
            isInstalled: true,
            version: "self-test",
            compatibility: .supported
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
