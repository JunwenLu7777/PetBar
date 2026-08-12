//
//  OverlayNotificationSync.swift
//  ThreadHelm
//
//  模块职责：Codex 原生任务气泡静音状态的准备/恢复/磁盘同步。在 Codex
//  完全退出后改写其全局状态 JSON，为本地任务通知补齐静音偏好，并通过
//  备份文件保证可恢复与写入边界安全。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct PreparedCodexOverlayNotificationState {
    let stateData: Data
    let backupData: Data
}

enum CodexOverlayNotificationState {
    private static let persistedAtomContainerKey = "electron-persisted-atom-state"
    private static let mutedNotificationKey = "avatar-overlay-muted-notification-ids-v1"
    private static let localThreadKeyPrefix = "thread-client-id-v1:local%3A"
    private static let localNotificationPrefix = "local:local:"

    private enum StateError: LocalizedError {
        case invalidJSON(String)
        case invalidArray(String)
        case writeCancelled

        var errorDescription: String? {
            switch self {
            case let .invalidJSON(name):
                return "\(name) 不是有效的 JSON 对象"
            case let .invalidArray(key):
                return "\(key) 不是字符串数组"
            case .writeCancelled:
                return "Codex 已重新启动，已取消原生气泡状态写入"
            }
        }
    }

    static func prepare(
        stateData: Data,
        sessionIndexData: Data?,
        existingBackupData: Data?
    ) throws -> PreparedCodexOverlayNotificationState {
        var root = try jsonObject(from: stateData, name: "Codex 状态")
        var atoms = root[persistedAtomContainerKey] as? [String: Any] ?? [:]
        var backup = try backupObject(from: existingBackupData)

        let mutedKeyExisted = atoms[mutedNotificationKey] != nil
        var muted = try stringArray(in: atoms, key: mutedNotificationKey)
        var addedMuted = backupStringArray(
            in: backup,
            key: "addedMutedNotificationIDs"
        )
        let knownThreadIDs = localThreadIDs(
            atoms: atoms,
            sessionIndexData: sessionIndexData
        )
        for threadID in knownThreadIDs.sorted() {
            let preferenceID = localNotificationPrefix + threadID
            guard !muted.contains(preferenceID) else { continue }
            muted.append(preferenceID)
            if !addedMuted.contains(preferenceID) {
                addedMuted.append(preferenceID)
            }
        }
        atoms[mutedNotificationKey] = muted

        backup["version"] = 1
        backup["createdMutedKey"] =
            (backup["createdMutedKey"] as? Bool ?? false) || !mutedKeyExisted
        backup["addedMutedNotificationIDs"] = addedMuted

        root[persistedAtomContainerKey] = atoms
        return PreparedCodexOverlayNotificationState(
            stateData: try JSONSerialization.data(withJSONObject: root),
            backupData: try JSONSerialization.data(
                withJSONObject: backup,
                options: [.sortedKeys]
            )
        )
    }

    static func restore(stateData: Data, backupData: Data) throws -> Data {
        var root = try jsonObject(from: stateData, name: "Codex 状态")
        guard var atoms = root[persistedAtomContainerKey] as? [String: Any] else {
            return stateData
        }
        let backup = try jsonObject(from: backupData, name: "ThreadHelm 状态备份")
        let addedMuted = Set(
            backupStringArray(in: backup, key: "addedMutedNotificationIDs")
        )

        if atoms[mutedNotificationKey] != nil {
            let restored = try stringArray(in: atoms, key: mutedNotificationKey)
                .filter { !addedMuted.contains($0) }
            if backup["createdMutedKey"] as? Bool == true, restored.isEmpty {
                atoms.removeValue(forKey: mutedNotificationKey)
            } else {
                atoms[mutedNotificationKey] = restored
            }
        }

        root[persistedAtomContainerKey] = atoms
        return try JSONSerialization.data(withJSONObject: root)
    }

    @discardableResult
    static func prepareFiles(
        stateURL: URL,
        sessionIndexURL: URL,
        backupURL: URL,
        canWrite: () -> Bool = { true }
    ) throws -> Bool {
        let fileManager = FileManager.default
        let stateData = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : Data("{}".utf8)
        let sessionIndexData = fileManager.fileExists(atPath: sessionIndexURL.path)
            ? try Data(contentsOf: sessionIndexURL)
            : nil
        let existingBackupData = fileManager.fileExists(atPath: backupURL.path)
            ? try Data(contentsOf: backupURL)
            : nil
        let prepared = try prepare(
            stateData: stateData,
            sessionIndexData: sessionIndexData,
            existingBackupData: existingBackupData
        )

        let stateChanged =
            try canonicalJSONData(stateData) != canonicalJSONData(prepared.stateData)
        let backupChanged: Bool
        if let existingBackupData {
            backupChanged =
                try canonicalJSONData(existingBackupData)
                    != canonicalJSONData(prepared.backupData)
        } else {
            backupChanged = true
        }

        func currentInputsMatch() throws -> Bool {
            let currentStateData = fileManager.fileExists(atPath: stateURL.path)
                ? try Data(contentsOf: stateURL)
                : Data("{}".utf8)
            let currentSessionIndexData =
                fileManager.fileExists(atPath: sessionIndexURL.path)
                    ? try Data(contentsOf: sessionIndexURL)
                    : nil
            return currentStateData == stateData
                && currentSessionIndexData == sessionIndexData
        }

        func validateWriteBoundary() throws {
            guard canWrite(), try currentInputsMatch() else {
                throw StateError.writeCancelled
            }
        }

        let hasChanges = stateChanged || backupChanged
        if hasChanges {
            try validateWriteBoundary()
            try fileManager.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var wrotePreparedBackup = false
        if backupChanged {
            try validateWriteBoundary()
            try prepared.backupData.write(to: backupURL, options: .atomic)
            wrotePreparedBackup = true
        }
        do {
            if stateChanged {
                try validateWriteBoundary()
                try prepared.stateData.write(to: stateURL, options: .atomic)
            }
        } catch {
            if wrotePreparedBackup {
                if let existingBackupData {
                    try existingBackupData.write(to: backupURL, options: .atomic)
                } else if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
            }
            throw error
        }
        return hasChanges
    }

    static func restoreFiles(
        stateURL: URL,
        backupURL: URL,
        canWrite: () -> Bool = { true }
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            guard canWrite() else {
                throw StateError.writeCancelled
            }
            try fileManager.removeItem(at: backupURL)
            return
        }
        let stateData = try Data(contentsOf: stateURL)
        let backupData = try Data(contentsOf: backupURL)
        let restored = try restore(
            stateData: stateData,
            backupData: backupData
        )

        guard canWrite(),
              try Data(contentsOf: stateURL) == stateData,
              try Data(contentsOf: backupURL) == backupData
        else {
            throw StateError.writeCancelled
        }
        try restored.write(to: stateURL, options: .atomic)
        guard canWrite(),
              try Data(contentsOf: stateURL) == restored,
              try Data(contentsOf: backupURL) == backupData
        else {
            throw StateError.writeCancelled
        }
        try fileManager.removeItem(at: backupURL)
    }

    private static func jsonObject(from data: Data, name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StateError.invalidJSON(name)
        }
        return object
    }

    private static func canonicalJSONData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private static func backupObject(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        return try jsonObject(from: data, name: "ThreadHelm 状态备份")
    }

    private static func stringArray(
        in object: [String: Any],
        key: String
    ) throws -> [String] {
        guard let value = object[key] else { return [] }
        guard let strings = value as? [String] else {
            throw StateError.invalidArray(key)
        }
        return strings
    }

    private static func backupStringArray(
        in object: [String: Any],
        key: String
    ) -> [String] {
        object[key] as? [String] ?? []
    }

    private static func localThreadIDs(
        atoms: [String: Any],
        sessionIndexData: Data?
    ) -> Set<String> {
        var result = Set<String>()
        for key in atoms.keys where key.hasPrefix(localThreadKeyPrefix) {
            let encoded = String(key.dropFirst(localThreadKeyPrefix.count))
            if let decoded = encoded.removingPercentEncoding, validThreadID(decoded) {
                result.insert(decoded)
            }
        }

        if let sessionIndexData,
           let text = String(data: sessionIndexData, encoding: .utf8)
        {
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData)
                        as? [String: Any],
                      let threadID = object["id"] as? String,
                      validThreadID(threadID)
                else { continue }
                result.insert(threadID)
            }
        }
        return result
    }

    private static func validThreadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
    }
}

struct CodexOverlayNotificationDiskSnapshot: Equatable {
    let stateData: Data
    let sessionIndexData: Data?
}

struct CodexOverlayNotificationPaths {
    let stateURL: URL
    let sessionIndexURL: URL
    let backupURL: URL

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexOverlayNotificationPaths {
        let stateURL: URL
        let codexHomeURL: URL
        if let override = environment["THREADHELM_CODEX_STATE_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            stateURL = URL(fileURLWithPath: override)
            codexHomeURL = stateURL.deletingLastPathComponent()
        } else {
            let configuredHome = environment["CODEX_HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            codexHomeURL = configuredHome.flatMap { value in
                value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
            } ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            stateURL = codexHomeURL.appendingPathComponent(".codex-global-state.json")
        }
        return CodexOverlayNotificationPaths(
            stateURL: stateURL,
            sessionIndexURL: codexHomeURL.appendingPathComponent("session_index.jsonl"),
            backupURL: codexHomeURL.appendingPathComponent(
                "threadhelm-native-notification-backup.json"
            )
        )
    }

    func readSnapshot(
        fileManager: FileManager = .default
    ) throws -> CodexOverlayNotificationDiskSnapshot {
        let stateData = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : Data("{}".utf8)
        let sessionIndexData = fileManager.fileExists(atPath: sessionIndexURL.path)
            ? try Data(contentsOf: sessionIndexURL)
            : nil
        return CodexOverlayNotificationDiskSnapshot(
            stateData: stateData,
            sessionIndexData: sessionIndexData
        )
    }

    @discardableResult
    func synchronize(canWrite: () -> Bool = { true }) throws -> Bool {
        try CodexOverlayNotificationState.prepareFiles(
            stateURL: stateURL,
            sessionIndexURL: sessionIndexURL,
            backupURL: backupURL,
            canWrite: canWrite
        )
    }
}

enum CodexOverlayNotificationSyncDecision: Equatable {
    case waitForCodexExit
    case waitForStableFiles
    case synchronize
}

struct CodexOverlayNotificationSyncProbe {
    private let requiredStableSampleCount: Int
    private var lastSnapshot: CodexOverlayNotificationDiskSnapshot?
    private var stableSampleCount = 0

    init(requiredStableSampleCount: Int) {
        self.requiredStableSampleCount = max(1, requiredStableSampleCount)
    }

    mutating func observe(
        codexRunning: Bool,
        snapshot: CodexOverlayNotificationDiskSnapshot?
    ) -> CodexOverlayNotificationSyncDecision {
        guard !codexRunning else {
            reset()
            return .waitForCodexExit
        }
        guard let snapshot else {
            reset()
            return .waitForStableFiles
        }
        if snapshot == lastSnapshot {
            stableSampleCount += 1
        } else {
            lastSnapshot = snapshot
            stableSampleCount = 1
        }
        return stableSampleCount >= requiredStableSampleCount
            ? .synchronize
            : .waitForStableFiles
    }

    mutating func reset() {
        lastSnapshot = nil
        stableSampleCount = 0
    }
}

final class CodexOverlayNotificationSynchronizer {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let maximumAttempts: Int
    private let checkInterval: TimeInterval
    private let isCodexRunning: () -> Bool
    private let readSnapshot: () throws -> CodexOverlayNotificationDiskSnapshot
    private let synchronize: () throws -> Bool
    private let schedule: Schedule
    private let log: (String) -> Void
    private var probe: CodexOverlayNotificationSyncProbe
    private var observedCodexRunning: Bool?
    private var attemptCount = 0
    private var generation = 0

    init(
        requiredStableSampleCount: Int = 2,
        maximumAttempts: Int = 80,
        checkInterval: TimeInterval = 0.25,
        isCodexRunning: @escaping () -> Bool,
        readSnapshot: @escaping () throws -> CodexOverlayNotificationDiskSnapshot,
        synchronize: @escaping () throws -> Bool,
        schedule: @escaping Schedule,
        log: @escaping (String) -> Void
    ) {
        probe = CodexOverlayNotificationSyncProbe(
            requiredStableSampleCount: requiredStableSampleCount
        )
        self.maximumAttempts = max(1, maximumAttempts)
        self.checkInterval = max(0, checkInterval)
        self.isCodexRunning = isCodexRunning
        self.readSnapshot = readSnapshot
        self.synchronize = synchronize
        self.schedule = schedule
        self.log = log
    }

    func codexRunningStateDidChange(_ isRunning: Bool) {
        guard observedCodexRunning != isRunning else { return }
        observedCodexRunning = isRunning
        generation &+= 1
        probe.reset()
        attemptCount = 0
        guard !isRunning else { return }
        scheduleCheck(for: generation, after: 0)
    }

    func stop() {
        generation &+= 1
        observedCodexRunning = nil
        probe.reset()
        attemptCount = 0
    }

    private func scheduleCheck(
        for expectedGeneration: Int,
        after delay: TimeInterval? = nil
    ) {
        schedule(delay ?? checkInterval) { [weak self] in
            self?.runCheck(for: expectedGeneration)
        }
    }

    private func runCheck(for expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        guard !isCodexRunning() else {
            codexRunningStateDidChange(true)
            return
        }

        attemptCount += 1
        do {
            let snapshot = try readSnapshot()
            switch probe.observe(codexRunning: false, snapshot: snapshot) {
            case .waitForCodexExit:
                return
            case .waitForStableFiles:
                retryOrStop(for: expectedGeneration)
            case .synchronize:
                guard !isCodexRunning() else {
                    codexRunningStateDidChange(true)
                    return
                }
                let changed = try synchronize()
                guard generation == expectedGeneration else { return }
                generation &+= 1
                log(
                    changed
                        ? "ThreadHelm 已在 Codex 完全退出后同步原生任务气泡静音状态。"
                        : "ThreadHelm 已确认 Codex 原生任务气泡静音状态为最新。"
                )
            }
        } catch {
            retryOrStop(for: expectedGeneration)
        }
    }

    private func retryOrStop(for expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        guard attemptCount < maximumAttempts else {
            generation &+= 1
            log("ThreadHelm 暂时无法同步 Codex 原生任务气泡；将在下次 Codex 退出后重试。")
            return
        }
        scheduleCheck(for: expectedGeneration)
    }
}
