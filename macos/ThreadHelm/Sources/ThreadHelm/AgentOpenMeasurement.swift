//
//  AgentOpenMeasurement.swift
//  ThreadHelm
//
//  模块职责：在本机记录五 Agent 的打开结果计数；不保存标题、路径、
//  session/thread ID、时间线或时间戳。
//

import Darwin
import Foundation

struct AgentOpenMeasurementTotals: Codable, Equatable {
    fileprivate var results: [String: Int]
    private(set) var exactAttempts: Int
    private(set) var exactSuccesses: Int

    static let zero = AgentOpenMeasurementTotals(
        results: [:],
        exactAttempts: 0,
        exactSuccesses: 0
    )

    func resultCount(_ result: OpenResult) -> Int {
        results[result.rawValue] ?? 0
    }

    fileprivate mutating func record(_ report: AgentOpenReport) {
        results[report.result.rawValue] = incremented(
            results[report.result.rawValue] ?? 0
        )
        if report.exactAttempted {
            exactAttempts = incremented(exactAttempts)
        }
        if report.exactAttempted,
           report.result == .exactSession,
           report.independentlyConfirmedIdentity
        {
            exactSuccesses = incremented(exactSuccesses)
        }
    }

    fileprivate func sanitized() -> AgentOpenMeasurementTotals {
        let allowedResults = Set(OpenResult.allCases.map(\.rawValue))
        let safeResults = results.reduce(into: [String: Int]()) {
            partial, entry in
            guard allowedResults.contains(entry.key), entry.value >= 0 else {
                return
            }
            partial[entry.key] = entry.value
        }
        let safeAttempts = max(0, exactAttempts)
        return AgentOpenMeasurementTotals(
            results: safeResults,
            exactAttempts: safeAttempts,
            exactSuccesses: min(max(0, exactSuccesses), safeAttempts)
        )
    }
}

struct AgentOpenMeasurementSnapshot: Equatable {
    fileprivate let agents: [String: AgentOpenMeasurementTotals]

    func totals(for agentID: AgentID) -> AgentOpenMeasurementTotals {
        agents[agentID.rawValue] ?? .zero
    }
}

private struct AgentOpenMeasurementDocument: Codable {
    let schemaVersion: Int
    var agents: [String: AgentOpenMeasurementTotals]

    static var empty: AgentOpenMeasurementDocument {
        AgentOpenMeasurementDocument(
            schemaVersion: 1,
            agents: Dictionary(uniqueKeysWithValues: AgentID.builtInOrder.map {
                ($0.rawValue, AgentOpenMeasurementTotals.zero)
            })
        )
    }

    func sanitized() -> AgentOpenMeasurementDocument? {
        guard schemaVersion == 1 else { return nil }
        var result = AgentOpenMeasurementDocument.empty
        for agentID in AgentID.builtInOrder {
            if let totals = agents[agentID.rawValue] {
                result.agents[agentID.rawValue] = totals.sanitized()
            }
        }
        return result
    }
}

final class AgentOpenMeasurementStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var document: AgentOpenMeasurementDocument

    init(
        fileURL: URL = defaultAgentOpenMeasurementURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        document = Self.load(
            from: fileURL.standardizedFileURL,
            fileManager: fileManager
        )
    }

    func snapshot() -> AgentOpenMeasurementSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AgentOpenMeasurementSnapshot(agents: document.agents)
    }

    @discardableResult
    func record(_ report: AgentOpenReport) -> Bool {
        guard AgentID.builtInOrder.contains(report.agentID) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }

        var candidate = document
        var totals = candidate.agents[report.agentID.rawValue] ?? .zero
        totals.record(report)
        candidate.agents[report.agentID.rawValue] = totals
        guard persist(candidate) else { return false }
        document = candidate
        return true
    }

    private static func load(
        from fileURL: URL,
        fileManager: FileManager
    ) -> AgentOpenMeasurementDocument {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                  AgentOpenMeasurementDocument.self,
                  from: data
              ),
              let sanitized = decoded.sanitized()
        else { return .empty }
        return sanitized
    }

    private func persist(_ document: AgentOpenMeasurementDocument) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ), chmod(temporaryURL.path, S_IRUSR | S_IWUSR) == 0,
                rename(temporaryURL.path, fileURL.path) == 0,
                chmod(fileURL.path, S_IRUSR | S_IWUSR) == 0
            else {
                try? fileManager.removeItem(at: temporaryURL)
                return false
            }
            return true
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            return false
        }
    }
}

func defaultAgentOpenMeasurementURL(
    fileManager: FileManager = .default
) -> URL {
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("open-measurements-v1.json")
}

private func incremented(_ value: Int) -> Int {
    value == Int.max ? value : value + 1
}
