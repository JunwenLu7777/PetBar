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

    func status(
        targetAgentID: AgentID? = nil,
        in scope: AgentIntegrationScope
    ) -> AgentIntegrationRunReport {
        let candidateAgentIDs = targetAgentID.map { [$0] } ?? registry.agentIDs
        return AgentIntegrationRunReport(
            operation: .status,
            backupID: nil,
            restoredBackupID: nil,
            rolledBack: false,
            agents: candidateAgentIDs.compactMap { agentID in
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
        targetAgentID: AgentID? = nil,
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

        if let targetAgentID, registry.adapter(for: targetAgentID) == nil {
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: targetAgentID,
                reason: "未找到指定的 Agent：\(targetAgentID.rawValue)",
                didRollback: false
            )
        }

        let backupStore = AgentIntegrationBackupStore(scope: scope)
        let relativePaths = managedRelativePaths(
            in: scope,
            for: targetAgentID
        )
        let backup: AgentIntegrationBackup
        do {
            backup = try backupStore.create(relativePaths: relativePaths)
        } catch {
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: targetAgentID,
                reason: error.localizedDescription,
                didRollback: false
            )
        }

        var records: [AgentIntegrationRunRecord] = []
        var activeAgentID: AgentID?
        let candidateAgentIDs = targetAgentID.map { [$0] } ?? registry.agentIDs
        do {
            for agentID in candidateAgentIDs {
                guard let adapter = registry.adapter(for: agentID) else {
                    continue
                }
                activeAgentID = agentID
                let before = adapter.integrationStatus(in: scope)
                let result: AgentIntegrationOperationResult
                let requiresValidatedVersion = operation != .uninstall
                    && !adapter.managedIntegrationRelativePaths.isEmpty
                if requiresValidatedVersion,
                   adapter.discover().compatibility != .validated
                {
                    result = .unchanged
                } else {
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
            let primaryError = error
            let rollbackSucceeded: Bool
            let rollbackFailure: String?
            do {
                try backupStore.restoreContents(id: backup.id)
                rollbackSucceeded = true
                rollbackFailure = nil
            } catch {
                rollbackSucceeded = false
                rollbackFailure = error.localizedDescription
            }
            throw AgentIntegrationManagerError(
                operation: operation,
                agentID: activeAgentID,
                reason: rollbackFailure.map {
                    "\(primaryError.localizedDescription)；自动恢复失败：\($0)"
                } ?? primaryError.localizedDescription,
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
            let didRollback = (error as? AgentIntegrationBackupError)?
                .restoredSafetyBackup == true
            throw AgentIntegrationManagerError(
                operation: .restore,
                agentID: nil,
                reason: error.localizedDescription,
                didRollback: didRollback
            )
        }
    }

    private func managedRelativePaths(
        in scope: AgentIntegrationScope,
        for targetAgentID: AgentID? = nil
    ) -> [String] {
        var seen: Set<String> = []
        let candidateIDs = targetAgentID.map { [$0] } ?? registry.agentIDs
        return candidateIDs.flatMap { agentID -> [String] in
            registry.adapter(for: agentID)?
                .managedIntegrationRelativePaths(in: scope) ?? []
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

struct AgentIntegrationBackup {
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

enum AgentIntegrationBackupError: LocalizedError {
    case invalidBackupID
    case invalidManifest
    case missingPayload(String)
    case primaryRestoreFailed(primary: String, safetyBackupID: String)
    case safetyRestoreFailed(
        primary: String,
        rollback: String,
        safetyBackupID: String
    )
    case restoreRollbackFailed(primary: String, transactionPath: String)

    var restoredSafetyBackup: Bool {
        if case .primaryRestoreFailed = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidBackupID: return "备份编号无效"
        case .invalidManifest: return "备份清单无效"
        case .missingPayload(let path): return "备份内容缺失：\(path)"
        case .primaryRestoreFailed(let primary, let safetyBackupID):
            return "恢复目标备份失败：\(primary)（安全备份：\(safetyBackupID)）"
        case .safetyRestoreFailed(
            let primary,
            let rollback,
            let safetyBackupID
        ):
            return "恢复目标备份失败：\(primary)；安全备份 "
                + "\(safetyBackupID) 自动恢复也失败：\(rollback)"
        case .restoreRollbackFailed(let primary, let transactionPath):
            return "恢复失败：\(primary)；撤销暂存未能完整放回，恢复材料保留在："
                + transactionPath
        }
    }
}

private struct AgentIntegrationPreparedRestoreItem {
    let index: Int
    let relativePath: String
    let targetURL: URL
    let stagedURL: URL?
    let undoURL: URL
}

private struct AgentIntegrationAppliedRestoreItem {
    let prepared: AgentIntegrationPreparedRestoreItem
    let hadOriginal: Bool
}

struct AgentIntegrationBackupStore {
    private let scope: AgentIntegrationScope
    private let fileManager: FileManager
    private let beforeRestoredItemInstall: (_ index: Int, _ path: String) throws -> Void

    init(
        scope: AgentIntegrationScope,
        fileManager: FileManager = .default,
        beforeRestoredItemInstall: @escaping (
            _ index: Int,
            _ path: String
        ) throws -> Void = { _, _ in }
    ) {
        self.scope = scope
        self.fileManager = fileManager
        self.beforeRestoredItemInstall = beforeRestoredItemInstall
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
                guard try integrationPathState(sourceURL) == .exists else {
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
            let primaryDescription = error.localizedDescription
            do {
                try restoreContents(id: safety.id)
            } catch {
                throw AgentIntegrationBackupError.safetyRestoreFailed(
                    primary: primaryDescription,
                    rollback: error.localizedDescription,
                    safetyBackupID: safety.id
                )
            }
            throw AgentIntegrationBackupError.primaryRestoreFailed(
                primary: primaryDescription,
                safetyBackupID: safety.id
            )
        }
    }

    func restoreContents(id: String) throws {
        let manifest = try loadManifest(id: id)
        let backupDirectory = try backupDirectoryURL(id: id)
        let payloadDirectory = backupDirectory.appendingPathComponent(
            "payload",
            isDirectory: true
        )
        let transactionDirectory = backupRootURL.appendingPathComponent(
            ".restore-transaction-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let stagedDirectory = transactionDirectory.appendingPathComponent(
            "staged",
            isDirectory: true
        )
        let undoDirectory = transactionDirectory.appendingPathComponent(
            "undo",
            isDirectory: true
        )
        var preserveTransaction = false
        defer {
            if !preserveTransaction {
                try? fileManager.removeItem(at: transactionDirectory)
            }
        }

        try fileManager.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: undoDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var preparedItems: [AgentIntegrationPreparedRestoreItem] = []
        for (index, item) in manifest.items.enumerated() {
            let targetURL = try managedURL(relativePath: item.relativePath)
            let stagedURL: URL?
            switch item.kind {
            case .missing:
                guard item.payloadName == nil else {
                    throw AgentIntegrationBackupError.invalidManifest
                }
                stagedURL = nil
            case .file, .directory:
                guard let payloadName = item.payloadName,
                      payloadName.range(
                          of: #"^[0-9]+$"#,
                          options: .regularExpression
                      ) != nil
                else {
                    throw AgentIntegrationBackupError.invalidManifest
                }
                let payloadURL = payloadDirectory.appendingPathComponent(
                    payloadName
                )
                guard try integrationPathState(payloadURL) == .exists else {
                    throw AgentIntegrationBackupError.missingPayload(
                        item.relativePath
                    )
                }
                let destination = stagedDirectory.appendingPathComponent(
                    String(index)
                )
                try fileManager.copyItem(at: payloadURL, to: destination)
                stagedURL = destination
            }
            preparedItems.append(AgentIntegrationPreparedRestoreItem(
                index: index,
                relativePath: item.relativePath,
                targetURL: targetURL,
                stagedURL: stagedURL,
                undoURL: undoDirectory.appendingPathComponent(String(index))
            ))
        }

        var appliedItems: [AgentIntegrationAppliedRestoreItem] = []
        var createdParentDirectories: [URL] = []
        var createdParentPaths: Set<String> = []
        do {
            for prepared in preparedItems {
                let missingDirectories = try managedParentDirectoriesToCreate(
                    for: prepared.targetURL
                )
                if prepared.stagedURL != nil {
                    for directory in missingDirectories
                    where createdParentPaths.insert(directory.path).inserted {
                        createdParentDirectories.append(directory)
                    }
                    try fileManager.createDirectory(
                        at: prepared.targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    guard try managedParentDirectoriesToCreate(
                        for: prepared.targetURL
                    ).isEmpty else {
                        throw AgentIntegrationError.invalidManagedPath
                    }
                }
                let hadOriginal = try integrationPathState(
                    prepared.targetURL
                ) == .exists
                if hadOriginal {
                    try fileManager.moveItem(
                        at: prepared.targetURL,
                        to: prepared.undoURL
                    )
                }
                appliedItems.append(AgentIntegrationAppliedRestoreItem(
                    prepared: prepared,
                    hadOriginal: hadOriginal
                ))
                try beforeRestoredItemInstall(
                    prepared.index,
                    prepared.relativePath
                )
                if let stagedURL = prepared.stagedURL {
                    guard try managedParentDirectoriesToCreate(
                        for: prepared.targetURL
                    ).isEmpty else {
                        throw AgentIntegrationError.invalidManagedPath
                    }
                    try fileManager.moveItem(
                        at: stagedURL,
                        to: prepared.targetURL
                    )
                }
            }
        } catch {
            let primaryError = error
            var rollbackFailed = false
            for applied in appliedItems.reversed() {
                do {
                    let targetExists = try integrationPathState(
                        applied.prepared.targetURL
                    ) == .exists
                    if !applied.hadOriginal && !targetExists {
                        continue
                    }
                    guard try managedParentDirectoriesToCreate(
                        for: applied.prepared.targetURL
                    ).isEmpty else {
                        throw AgentIntegrationError.invalidManagedPath
                    }
                    if targetExists {
                        try fileManager.removeItem(at: applied.prepared.targetURL)
                    }
                    if applied.hadOriginal {
                        try fileManager.moveItem(
                            at: applied.prepared.undoURL,
                            to: applied.prepared.targetURL
                        )
                    }
                } catch {
                    rollbackFailed = true
                }
            }
            for directory in createdParentDirectories.reversed() {
                do {
                    try removeCreatedParentDirectoryIfEmpty(directory)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                preserveTransaction = true
                throw AgentIntegrationBackupError.restoreRollbackFailed(
                    primary: primaryError.localizedDescription,
                    transactionPath: transactionDirectory.path
                )
            }
            throw primaryError
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
        let root = managedRootURL
        let url = try scope.managedURL(relativePath: relativePath)
        guard url.path.hasPrefix(root.path + "/") else {
            throw AgentIntegrationError.invalidManagedPath
        }
        _ = try managedParentDirectoriesToCreate(for: url)
        return url
    }

    private var managedRootURL: URL {
        scope.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func managedParentDirectoriesToCreate(
        for targetURL: URL
    ) throws -> [URL] {
        let root = managedRootURL
        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        guard integrationPath(parent, isWithin: root) else {
            throw AgentIntegrationError.invalidManagedPath
        }
        let rootComponents = root.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.starts(with: rootComponents) else {
            throw AgentIntegrationError.invalidManagedPath
        }

        var current = root
        var foundMissingParent = false
        var missingDirectories: [URL] = []
        for component in parentComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if foundMissingParent {
                missingDirectories.append(current)
                continue
            }
            var pathStat = stat()
            if lstat(current.path, &pathStat) != 0 {
                let code = errno
                guard code == ENOENT else {
                    throw integrationPOSIXError(code)
                }
                foundMissingParent = true
                missingDirectories.append(current)
                continue
            }
            let type = pathStat.st_mode & S_IFMT
            if type == S_IFLNK {
                var destinationStat = stat()
                guard stat(current.path, &destinationStat) == 0,
                      (destinationStat.st_mode & S_IFMT) == S_IFDIR
                else {
                    throw AgentIntegrationError.invalidManagedPath
                }
            } else if type != S_IFDIR {
                throw AgentIntegrationError.invalidManagedPath
            }
            let resolved = current.resolvingSymlinksInPath()
                .standardizedFileURL
            guard integrationPath(resolved, isWithin: root) else {
                throw AgentIntegrationError.invalidManagedPath
            }
        }
        return missingDirectories
    }

    private func removeCreatedParentDirectoryIfEmpty(_ url: URL) throws {
        _ = try managedParentDirectoriesToCreate(for: url)
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw integrationPOSIXError(code)
        }
        guard (pathStat.st_mode & S_IFMT) == S_IFDIR,
              try fileManager.contentsOfDirectory(atPath: url.path).isEmpty
        else {
            throw AgentIntegrationError.invalidManagedPath
        }
        try fileManager.removeItem(at: url)
    }
}

private enum IntegrationPathState {
    case missing
    case exists
}

private func integrationPathState(_ url: URL) throws -> IntegrationPathState {
    var statBuffer = stat()
    if lstat(url.path, &statBuffer) == 0 {
        return .exists
    }
    let code = errno
    if code == ENOENT {
        return .missing
    }
    throw integrationPOSIXError(code)
}

private func integrationPath(_ candidate: URL, isWithin root: URL) -> Bool {
    candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
}

private func integrationPOSIXError(_ code: Int32) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [
            NSLocalizedDescriptionKey: String(cString: strerror(code)),
        ]
    )
}

struct AgentIntegrationCLICommand {
    let operation: AgentIntegrationOperation
    let backupID: String?
    let targetAgentID: AgentID?
    let scope: AgentIntegrationScope
}

enum AgentIntegrationCLIError: LocalizedError {
    case invalidArguments
    case explicitScopeRequired
    case liveRootMustUseLiveFlag

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            // restore 刻意不列在接受 --agent 的那一组里：备份是跨 Agent 的，
            // 按单个 Agent 恢复没有意义，解析器也会拒绝。
            return "用法：--agent-integrations <status|install|repair|uninstall> [--agent ID] (--root ABSOLUTE_PATH|--live)"
                + " 或 --agent-integrations restore BACKUP_ID (--root ABSOLUTE_PATH|--live)"
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
        var scopeStart = operation == .restore ? flag + 3 : flag + 2
        var targetAgentID: AgentID?
        if arguments.indices.contains(scopeStart),
           arguments[scopeStart] == "--agent"
        {
            guard arguments.indices.contains(scopeStart + 1),
                  let parsedAgentID = AgentID.builtInOrder.first(where: {
                      $0.rawValue == arguments[scopeStart + 1]
                  }),
                  operation != .restore
            else {
                throw AgentIntegrationCLIError.invalidArguments
            }
            targetAgentID = parsedAgentID
            scopeStart += 2
        }
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
            targetAgentID: targetAgentID,
            scope: scope
        )
    }

    /// 从已解析的命令构造报告。
    ///
    /// 与 `runIfRequested` 分开是为了让自测能断言**分发的产物**：
    /// 只断言解析结果和退出码是不够的——`targetAgentID` 被解析出来却在这里
    /// 漏传，解析断言照样绿、退出码照样 0，而作用域已经悄悄放大到全部 Agent。
    static func makeReport(
        for command: AgentIntegrationCLICommand,
        registry: AgentRegistry = .builtIn
    ) throws -> AgentIntegrationRunReport {
        let manager = AgentIntegrationManager(registry: registry)
        switch command.operation {
        case .status:
            return manager.status(
                targetAgentID: command.targetAgentID,
                in: command.scope
            )
        case .install, .repair, .uninstall:
            return try manager.perform(
                command.operation,
                targetAgentID: command.targetAgentID,
                in: command.scope
            )
        case .restore:
            guard let backupID = command.backupID else {
                throw AgentIntegrationCLIError.invalidArguments
            }
            return try manager.restoreBackup(id: backupID, in: command.scope)
        }
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        registry: AgentRegistry = .builtIn
    ) -> Int32? {
        guard arguments.contains("--agent-integrations") else { return nil }
        do {
            let command = try parse(arguments: arguments)
            let report = try makeReport(for: command, registry: registry)
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
