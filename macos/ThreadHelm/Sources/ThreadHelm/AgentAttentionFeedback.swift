//
//  AgentAttentionFeedback.swift
//  ThreadHelm
//
//  模块职责：在本机保存五 Agent 的注意力评价计数；只允许四种固定分类，
//  不保存标题、提示词、命令、路径、session ID、时间戳或时间线。
//

import Darwin
import Foundation

enum AgentAttentionFeedback: String, CaseIterable, Codable, Equatable {
    case useful
    case unnecessary
    case wrongState
    case wrongSession
}

struct AgentAttentionFeedbackTotals: Codable, Equatable {
    fileprivate var ratings: [String: Int]

    static let zero = AgentAttentionFeedbackTotals(ratings: [:])

    var rawCount: Int {
        ratings.values.reduce(0, saturatedAttentionFeedbackSum)
    }

    func count(_ feedback: AgentAttentionFeedback) -> Int {
        ratings[feedback.rawValue] ?? 0
    }

    fileprivate mutating func record(_ feedback: AgentAttentionFeedback) {
        ratings[feedback.rawValue] = saturatedAttentionFeedbackIncrement(
            ratings[feedback.rawValue] ?? 0
        )
    }

    fileprivate func sanitized() -> AgentAttentionFeedbackTotals {
        let allowed = Set(AgentAttentionFeedback.allCases.map(\.rawValue))
        return AgentAttentionFeedbackTotals(ratings: ratings.reduce(
            into: [String: Int]()
        ) { result, entry in
            guard allowed.contains(entry.key), entry.value >= 0 else { return }
            result[entry.key] = entry.value
        })
    }
}

struct AgentAttentionFeedbackSnapshot: Equatable {
    fileprivate let agents: [String: AgentAttentionFeedbackTotals]

    var rawCount: Int {
        agents.values.map(\.rawCount).reduce(0, saturatedAttentionFeedbackSum)
    }

    func count(_ feedback: AgentAttentionFeedback) -> Int {
        agents.values.map { $0.count(feedback) }
            .reduce(0, saturatedAttentionFeedbackSum)
    }

    func totals(for agentID: AgentID) -> AgentAttentionFeedbackTotals {
        agents[agentID.rawValue] ?? .zero
    }
}

private struct AgentAttentionFeedbackDocument: Codable {
    let schemaVersion: Int
    var agents: [String: AgentAttentionFeedbackTotals]

    static var empty: AgentAttentionFeedbackDocument {
        AgentAttentionFeedbackDocument(
            schemaVersion: 1,
            agents: Dictionary(uniqueKeysWithValues: AgentID.builtInOrder.map {
                ($0.rawValue, AgentAttentionFeedbackTotals.zero)
            })
        )
    }

    func sanitized() -> AgentAttentionFeedbackDocument? {
        guard schemaVersion == 1 else { return nil }
        var result = AgentAttentionFeedbackDocument.empty
        for agentID in AgentID.builtInOrder {
            if let totals = agents[agentID.rawValue] {
                result.agents[agentID.rawValue] = totals.sanitized()
            }
        }
        return result
    }
}

final class AgentAttentionFeedbackStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var document: AgentAttentionFeedbackDocument

    init(
        fileURL: URL = defaultAgentAttentionFeedbackURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        document = Self.load(
            from: fileURL.standardizedFileURL,
            fileManager: fileManager
        )
    }

    func snapshot() -> AgentAttentionFeedbackSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AgentAttentionFeedbackSnapshot(agents: document.agents)
    }

    @discardableResult
    func record(
        agentID: AgentID,
        feedback: AgentAttentionFeedback
    ) -> Bool {
        guard AgentID.builtInOrder.contains(agentID) else { return false }
        lock.lock()
        defer { lock.unlock() }

        var candidate = document
        var totals = candidate.agents[agentID.rawValue] ?? .zero
        totals.record(feedback)
        candidate.agents[agentID.rawValue] = totals
        guard persist(candidate) else { return false }
        document = candidate
        return true
    }

    private static func load(
        from fileURL: URL,
        fileManager: FileManager
    ) -> AgentAttentionFeedbackDocument {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                  AgentAttentionFeedbackDocument.self,
                  from: data
              ),
              let sanitized = decoded.sanitized()
        else { return .empty }
        return sanitized
    }

    private func persist(_ document: AgentAttentionFeedbackDocument) -> Bool {
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

enum AgentAttentionFeedbackCLIRequest: Equatable {
    case notRequested
    case invalid
    case printSnapshot
    case record(agentID: AgentID, feedback: AgentAttentionFeedback)
}

func parseAgentAttentionFeedbackCLI(
    _ arguments: [String]
) -> AgentAttentionFeedbackCLIRequest {
    if arguments.contains("--print-attention-feedback") {
        return arguments.count == 2 ? .printSnapshot : .invalid
    }
    guard let flagIndex = arguments.firstIndex(
        of: "--record-attention-feedback"
    ) else { return .notRequested }
    guard arguments.count == 4,
          flagIndex == 1,
          let feedback = AgentAttentionFeedback(
              rawValue: arguments[flagIndex + 2]
          )
    else { return .invalid }
    let agentID = AgentID(rawValue: arguments[flagIndex + 1])
    guard AgentID.builtInOrder.contains(agentID) else { return .invalid }
    return .record(agentID: agentID, feedback: feedback)
}

func runAgentAttentionFeedbackCLIIfRequested(
    arguments: [String] = CommandLine.arguments,
    store: AgentAttentionFeedbackStore? = nil
) -> Int? {
    switch parseAgentAttentionFeedbackCLI(arguments) {
    case .notRequested:
        return nil
    case .invalid:
        fputs(
            "用法：--print-attention-feedback 或 "
                + "--record-attention-feedback AGENT "
                + "{useful|unnecessary|wrongState|wrongSession}\n",
            stderr
        )
        return 2
    case .printSnapshot:
        let activeStore = store ?? AgentAttentionFeedbackStore()
        print(attentionFeedbackDiagnosticText(activeStore.snapshot()))
        return 0
    case .record(let agentID, let feedback):
        let activeStore = store ?? AgentAttentionFeedbackStore()
        guard activeStore.record(agentID: agentID, feedback: feedback) else {
            fputs("ThreadHelm 无法写入本地注意力反馈计数。\n", stderr)
            return 1
        }
        print("attention-feedback: recorded \(agentID.rawValue) \(feedback.rawValue)")
        print(attentionFeedbackDiagnosticText(activeStore.snapshot()))
        return 0
    }
}

func attentionFeedbackDiagnosticText(
    _ snapshot: AgentAttentionFeedbackSnapshot
) -> String {
    let total = snapshot.rawCount
    let useful = snapshot.count(.useful)
    let unnecessary = snapshot.count(.unnecessary)
    let wrongState = snapshot.count(.wrongState)
    let wrongSession = snapshot.count(.wrongSession)
    let raw = "总计 \(total) · 有用 \(useful) · 不必要 \(unnecessary)"
        + " · 状态错误 \(wrongState) · 会话错误 \(wrongSession)"
    let confidence: String
    if total >= 20 {
        confidence = "值得打扰 \(attentionFeedbackPercent(useful, total: total))%"
            + " · 不必要 \(attentionFeedbackPercent(unnecessary, total: total))%"
    } else {
        confidence = "样本不足（至少需要 20 次真实评价）"
    }
    let perAgent = AgentID.builtInOrder.map { agentID in
        let totals = snapshot.totals(for: agentID)
        return "\(agentID.rawValue) \(totals.rawCount)"
    }.joined(separator: " · ")
    return raw + " · " + confidence + "\n按 Agent：" + perAgent
}

func defaultAgentAttentionFeedbackURL(
    fileManager: FileManager = .default
) -> URL {
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("attention-feedback-v1.json")
}

private func attentionFeedbackPercent(_ value: Int, total: Int) -> Int {
    guard total > 0 else { return 0 }
    return Int((Double(value) * 100 / Double(total)).rounded())
}

private func saturatedAttentionFeedbackIncrement(_ value: Int) -> Int {
    value == Int.max ? value : value + 1
}

private func saturatedAttentionFeedbackSum(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}
