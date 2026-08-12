//
//  AgentIntegrationManager.swift
//  ThreadHelm
//
//  模块职责：为五个本地 Agent 提供统一、显式的 status/install/repair/
//  uninstall/restore 入口，并用 owner-only 备份包围整次配置变更。
//

import Darwin
import Foundation

enum AgentIntegrationOperation: String, Codable, Equatable {
    case status
    case install
    case repair
    case uninstall
    case restore
}

struct AgentIntegrationRunRecord: Codable, Equatable {
    let agentID: AgentID
    let statusBefore: AgentIntegrationStatus
    let result: AgentIntegrationOperationResult?
    let statusAfter: AgentIntegrationStatus
}

struct AgentIntegrationRunReport: Codable, Equatable {
    let operation: AgentIntegrationOperation
    let backupID: String?
    let restoredBackupID: String?
    let rolledBack: Bool
    let agents: [AgentIntegrationRunRecord]
}

struct AgentIntegrationManagerError: LocalizedError {
    let operation: AgentIntegrationOperation
    let agentID: AgentID?
    let reason: String
    let didRollback: Bool

    var errorDescription: String? {
        let agent = agentID.map { "（\($0.rawValue)）" } ?? ""
        let rollback = didRollback ? "；原配置已恢复" : "；自动恢复未完成"
        return "Agent 集成 \(operation.rawValue) 失败\(agent)：\(reason)\(rollback)"
    }
}

struct AgentIntegrationManager {
    let registry: AgentRegistry

    func status(in scope: AgentIntegrationScope) -> AgentIntegrationRunReport {
        AgentIntegrationRunReport(
            operation: .status,
            backupID: nil,
            restoredBackupID: nil,
            rolledBack: false,
            agents: registry.agentIDs.compactMap { agentID in
                guard let adapter = registry.adapter(for: agentID) else {
                    return nil
                }
                let status = adapter.integrationStatus(in: scope)
                return AgentIntegrationRunRecord(
                    agentID: agentID,
                    statusBefore: status,
                    result: status == .notManaged ? .notManaged : nil,
                    statusAfter: status
                )
            }
        )
    }

    func perform(
        _ operation: AgentIntegrationOperation,
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationRunReport {
        guard operation == .install
                || operation == .repair
                || operation == .uninstall
        else {
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: nil,
                reason: "该操作不能走配置变更入口",
                didRollback: false
            )
        }

        let backupStore = AgentIntegrationBackupStore(scope: scope)
        let relativePaths = managedRelativePaths()
        let backup: AgentIntegrationBackup
        do {
            backup = try backupStore.create(relativePaths: relativePaths)
        } catch {
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: nil,
                reason: error.localizedDescription,
                didRollback: false
            )
        }

        var records: [AgentIntegrationRunRecord] = []
        var activeAgentID: AgentID?
        do {
            for agentID in registry.agentIDs {
                guard let adapter = registry.adapter(for: agentID) else {
                    continue
                }
                activeAgentID = agentID
                let before = adapter.integrationStatus(in: scope)
                let result: AgentIntegrationOperationResult
                switch operation {
                case .install:
                    result = try adapter.installIntegration(in: scope)
                case .repair:
                    result = try adapter.repairIntegration(in: scope)
                case .uninstall:
                    result = try adapter.uninstallIntegration(in: scope)
                case .status, .restore:
                    preconditionFailure("guarded above")
                }
                let after = adapter.integrationStatus(in: scope)
                records.append(AgentIntegrationRunRecord(
                    agentID: agentID,
                    statusBefore: before,
                    result: result,
                    statusAfter: after
                ))
            }
        } catch {
            let rollbackSucceeded: Bool
            do {
                try backupStore.restoreContents(id: backup.id)
                rollbackSucceeded = true
            } catch {
                rollbackSucceeded = false
            }
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: activeAgentID,
                reason: error.localizedDescription,
                didRollback: rollbackSucceeded
            )
        }

        return AgentIntegrationRunReport(
            operation: operation,
            backupID: backup.id,
            restoredBackupID: nil,
            rolledBack: false,
            agents: records
        )
    }

    func restoreBackup(
        id: String,
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationRunReport {
        let store = AgentIntegrationBackupStore(scope: scope)
        do {
            let safetyBackupID = try store.restore(id: id)
            let current = status(in: scope)
            return AgentIntegrationRunReport(
                operation: .restore,
                backupID: safetyBackupID,
                restoredBackupID: id,
                rolledBack: false,
                agents: current.agents
            )
        } catch {
            throw AgentIntegrationManagerError(
                operation: .restore,
                agentID: nil,
                reason: error.localizedDescription,
                didRollback: false
            )
        }
    }

    private func managedRelativePaths() -> [String] {
        var seen: Set<String> = []
        return registry.agentIDs.flatMap { agentID -> [String] in
            registry.adapter(for: agentID)?.managedIntegrationRelativePaths
                ?? []
        }.filter { seen.insert($0).inserted }
    }
}

enum AgentIntegrationAtomicFileWriter {
    typealias Replacement = (_ temporaryURL: URL, _ targetURL: URL) throws -> Void

    static func write(
        _ data: Data,
        to targetURL: URL,
        permissions: Int = 0o600,
        fileManager: FileManager = .default,
        replace replacement: Replacement? = nil
    ) throws {
        let directory = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directory.appendingPathComponent(
            ".\(targetURL.lastPathComponent).threadhelm-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: temporaryURL.path
            )
            if let replacement {
                try replacement(temporaryURL, targetURL)
            } else {
                guard rename(temporaryURL.path, targetURL.path) == 0 else {
                    let code = errno
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(code),
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                cString: strerror(code)
                            ),
                        ]
                    )
                }
            }
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: targetURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func replaceTemporaryItem(
        at temporaryURL: URL,
        targetURL: URL
    ) throws {
        guard rename(temporaryURL.path, targetURL.path) == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey: String(cString: strerror(code)),
                ]
            )
        }
    }
}

private struct AgentIntegrationBackup {
    let id: String
}

private enum AgentIntegrationBackupKind: String, Codable {
    case missing
    case file
    case directory
}

private struct AgentIntegrationBackupItem: Codable {
    let relativePath: String
    let payloadName: String?
    let kind: AgentIntegrationBackupKind
}

private struct AgentIntegrationBackupManifest: Codable {
    let schemaVersion: Int
    let backupID: String
    let items: [AgentIntegrationBackupItem]
}

private enum AgentIntegrationBackupError: LocalizedError {
    case invalidBackupID
    case invalidManifest
    case missingPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidBackupID: return "备份编号无效"
        case .invalidManifest: return "备份清单无效"
        case .missingPayload(let path): return "备份内容缺失：\(path)"
        }
    }
}

private struct AgentIntegrationBackupStore {
    private let scope: AgentIntegrationScope
    private let fileManager: FileManager

    init(
        scope: AgentIntegrationScope,
        fileManager: FileManager = .default
    ) {
        self.scope = scope
        self.fileManager = fileManager
    }

    func create(relativePaths: [String]) throws -> AgentIntegrationBackup {
        try validateScope()
        let id = UUID().uuidString.lowercased()
        let root = backupRootURL
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let temporaryDirectory = root.appendingPathComponent(
            ".\(id).tmp",
            isDirectory: true
        )
        let finalDirectory = root.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let payloadDirectory = temporaryDirectory.appendingPathComponent(
                "payload",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: payloadDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var items: [AgentIntegrationBackupItem] = []
            for (index, relativePath) in relativePaths.enumerated() {
                let sourceURL = try managedURL(relativePath: relativePath)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    items.append(AgentIntegrationBackupItem(
                        relativePath: relativePath,
                        payloadName: nil,
                        kind: .missing
                    ))
                    continue
                }
                let values = try sourceURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                let payloadName = String(index)
                try fileManager.copyItem(
                    at: sourceURL,
                    to: payloadDirectory.appendingPathComponent(payloadName)
                )
                items.append(AgentIntegrationBackupItem(
                    relativePath: relativePath,
                    payloadName: payloadName,
                    kind: values.isDirectory == true
                        && values.isSymbolicLink != true
                        ? .directory
                        : .file
                ))
            }
            let manifest = AgentIntegrationBackupManifest(
                schemaVersion: 1,
                backupID: id,
                items: items
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AgentIntegrationAtomicFileWriter.write(
                encoder.encode(manifest),
                to: temporaryDirectory.appendingPathComponent("manifest.json")
            )
            try fileManager.moveItem(
                at: temporaryDirectory,
                to: finalDirectory
            )
            return AgentIntegrationBackup(id: id)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    func restore(id: String) throws -> String {
        let manifest = try loadManifest(id: id)
        let safety = try create(
            relativePaths: manifest.items.map(\.relativePath)
        )
        do {
            try restoreContents(id: id)
            return safety.id
        } catch {
            try? restoreContents(id: safety.id)
            throw error
        }
    }

    func restoreContents(id: String) throws {
        let manifest = try loadManifest(id: id)
        let backupDirectory = try backupDirectoryURL(id: id)
        let payloadDirectory = backupDirectory.appendingPathComponent(
            "payload",
            isDirectory: true
        )
        for item in manifest.items {
            let targetURL = try managedURL(relativePath: item.relativePath)
            switch item.kind {
            case .missing:
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
            case .file, .directory:
                guard let payloadName = item.payloadName else {
                    throw AgentIntegrationBackupError.invalidManifest
                }
                let payloadURL = payloadDirectory.appendingPathComponent(
                    payloadName
                )
                guard fileManager.fileExists(atPath: payloadURL.path) else {
                    throw AgentIntegrationBackupError.missingPayload(
                        item.relativePath
                    )
                }
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let stagedURL = targetURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(targetURL.lastPathComponent).threadhelm-restore-"
                            + UUID().uuidString
                    )
                do {
                    try fileManager.copyItem(at: payloadURL, to: stagedURL)
                    if fileManager.fileExists(atPath: targetURL.path) {
                        try fileManager.removeItem(at: targetURL)
                    }
                    try fileManager.moveItem(at: stagedURL, to: targetURL)
                } catch {
                    try? fileManager.removeItem(at: stagedURL)
                    throw error
                }
            }
        }
    }

    private var backupRootURL: URL {
        scope.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(
            "Library/Application Support/ThreadHelm/Integration Backups",
            isDirectory: true
        )
    }

    private func backupDirectoryURL(id: String) throws -> URL {
        try validateScope()
        guard id.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil else {
            throw AgentIntegrationBackupError.invalidBackupID
        }
        return backupRootURL.appendingPathComponent(id, isDirectory: true)
    }

    private func validateScope() throws {
        _ = try scope.managedURL(
            relativePath: ".threadhelm-integration-scope-check"
        )
    }

    private func loadManifest(
        id: String
    ) throws -> AgentIntegrationBackupManifest {
        let directory = try backupDirectoryURL(id: id)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            AgentIntegrationBackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1,
              manifest.backupID == id,
              Set(manifest.items.map(\.relativePath)).count
                == manifest.items.count
        else {
            throw AgentIntegrationBackupError.invalidManifest
        }
        for item in manifest.items {
            _ = try managedURL(relativePath: item.relativePath)
        }
        return manifest
    }

    private func managedURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            throw AgentIntegrationError.invalidManagedPath
        }
        let root = scope.rootDirectory.standardizedFileURL
        let url = try scope.managedURL(relativePath: relativePath)
        guard url.path.hasPrefix(root.path + "/") else {
            throw AgentIntegrationError.invalidManagedPath
        }
        return url
    }
}

struct AgentIntegrationCLICommand {
    let operation: AgentIntegrationOperation
    let backupID: String?
    let scope: AgentIntegrationScope
}

enum AgentIntegrationCLIError: LocalizedError {
    case invalidArguments
    case explicitScopeRequired
    case liveRootMustUseLiveFlag

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "用法：--agent-integrations <status|install|repair|uninstall|restore BACKUP_ID> (--root ABSOLUTE_PATH|--live)"
        case .explicitScopeRequired:
            return "必须明确指定隔离 --root 或真实本机 --live"
        case .liveRootMustUseLiveFlag:
            return "真实主目录只能通过明确的 --live 使用"
        }
    }
}

enum AgentIntegrationCLI {
    static func parse(arguments: [String]) throws -> AgentIntegrationCLICommand {
        guard let flag = arguments.firstIndex(of: "--agent-integrations"),
              arguments.indices.contains(flag + 1),
              let operation = AgentIntegrationOperation(
                  rawValue: arguments[flag + 1]
              ), operation != .restore || arguments.indices.contains(flag + 2)
        else {
            throw AgentIntegrationCLIError.invalidArguments
        }
        let backupID = operation == .restore ? arguments[flag + 2] : nil
        let scopeStart = operation == .restore ? flag + 3 : flag + 2
        let trailing = Array(arguments.dropFirst(scopeStart))
        let scope: AgentIntegrationScope
        if trailing == ["--live"] {
            scope = AgentIntegrationScope(
                rootDirectory: FileManager.default.homeDirectoryForCurrentUser,
                permitsLiveConfigurationChanges: true
            )
        } else if trailing.count == 2,
                  trailing[0] == "--root",
                  trailing[1].hasPrefix("/")
        {
            let root = URL(fileURLWithPath: trailing[1], isDirectory: true)
                .standardizedFileURL
            guard root.path != "/",
                  root != FileManager.default.homeDirectoryForCurrentUser
                    .standardizedFileURL
            else {
                throw AgentIntegrationCLIError.liveRootMustUseLiveFlag
            }
            scope = .isolated(at: root)
        } else if trailing.isEmpty {
            throw AgentIntegrationCLIError.explicitScopeRequired
        } else {
            throw AgentIntegrationCLIError.invalidArguments
        }
        return AgentIntegrationCLICommand(
            operation: operation,
            backupID: backupID,
            scope: scope
        )
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        registry: AgentRegistry = .builtIn
    ) -> Int32? {
        guard arguments.contains("--agent-integrations") else { return nil }
        do {
            let command = try parse(arguments: arguments)
            let manager = AgentIntegrationManager(registry: registry)
            let report: AgentIntegrationRunReport
            switch command.operation {
            case .status:
                report = manager.status(in: command.scope)
            case .install, .repair, .uninstall:
                report = try manager.perform(command.operation, in: command.scope)
            case .restore:
                guard let backupID = command.backupID else {
                    throw AgentIntegrationCLIError.invalidArguments
                }
                report = try manager.restoreBackup(
                    id: backupID,
                    in: command.scope
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report)
            guard let output = String(data: data, encoding: .utf8) else {
                throw AgentIntegrationCLIError.invalidArguments
            }
            print(output)
            return 0
        } catch {
            fputs("Agent 集成命令失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
