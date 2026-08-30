//
//  PermissionDecisionHistory.swift
//  ThreadHelm
//
//  模块职责：保存有界、metadata-only 的本机审批历史。记录不包含请求
//  正文、工具参数、回答、拒绝理由、目录或 session ID。
//

import Darwin
import Foundation

enum PermissionHistoryRequestKind: String, Codable, Equatable {
    case tool
    case question
    case plan

    init(_ kind: ClaudePermissionInteractionKind) {
        switch kind {
        case .toolApproval: self = .tool
        case .askUserQuestion: self = .question
        case .exitPlanMode: self = .plan
        }
    }

    var displayTitle: String {
        switch self {
        case .tool: return "工具授权"
        case .question: return "问题回答"
        case .plan: return "计划审批"
        }
    }
}

enum PermissionHistoryOutcome: String, Codable, Equatable {
    case allowOnce
    case allowWithSuggestion
    case deny
    case submitAnswers
    case planFeedback
    case nativeFallback
    case expired

    var displayTitle: String {
        switch self {
        case .allowOnce: return "允许一次"
        case .allowWithSuggestion: return "长期允许"
        case .deny: return "已拒绝"
        case .submitAnswers: return "已回答"
        case .planFeedback: return "要求修改"
        case .nativeFallback: return "回到原生处理"
        case .expired: return "已过期"
        }
    }
}

func permissionHistoryOutcome(
    for decision: ClaudePermissionUserDecision
) -> PermissionHistoryOutcome {
    switch decision {
    case .allowOnce: return .allowOnce
    case .allowWithSuggestion: return .allowWithSuggestion
    case .deny: return .deny
    case .submitAnswers: return .submitAnswers
    case .planFeedback: return .planFeedback
    case .nativeFallback: return .nativeFallback
    }
}

struct PermissionDecisionHistoryRecord: Codable, Equatable {
    let agentID: AgentID
    let requestKind: PermissionHistoryRequestKind
    let outcome: PermissionHistoryOutcome
    let receivedAt: Date
    let decidedAt: Date
    let agentVersionSignature: String?

    init(
        agentID: AgentID,
        interactionKind: ClaudePermissionInteractionKind,
        outcome: PermissionHistoryOutcome,
        receivedAt: Date,
        decidedAt: Date,
        agentVersionSignature: String?
    ) {
        self.agentID = agentID
        requestKind = PermissionHistoryRequestKind(interactionKind)
        self.outcome = outcome
        self.receivedAt = receivedAt
        self.decidedAt = max(receivedAt, decidedAt)
        self.agentVersionSignature = sanitizedPermissionVersionSignature(
            agentVersionSignature
        )
    }

    var durationSeconds: Int {
        max(0, Int(decidedAt.timeIntervalSince(receivedAt).rounded(.down)))
    }

    fileprivate func sanitized() -> PermissionDecisionHistoryRecord? {
        let received = receivedAt.timeIntervalSinceReferenceDate
        let decided = decidedAt.timeIntervalSinceReferenceDate
        guard AgentID.builtInOrder.contains(agentID),
              received.isFinite,
              decided.isFinite,
              decided >= received,
              decided - received <= 24 * 60 * 60
        else { return nil }
        return PermissionDecisionHistoryRecord(
            agentID: agentID,
            interactionKind: requestKind.interactionKind,
            outcome: outcome,
            receivedAt: receivedAt,
            decidedAt: decidedAt,
            agentVersionSignature: agentVersionSignature
        )
    }
}

private extension PermissionHistoryRequestKind {
    var interactionKind: ClaudePermissionInteractionKind {
        switch self {
        case .tool: return .toolApproval
        case .question: return .askUserQuestion
        case .plan: return .exitPlanMode
        }
    }
}

private struct PermissionDecisionHistoryDocument: Codable {
    let schemaVersion: Int
    var records: [PermissionDecisionHistoryRecord]

    static let empty = PermissionDecisionHistoryDocument(
        schemaVersion: 1,
        records: []
    )
}

final class PermissionDecisionHistoryStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumRecords: Int
    private let lock = NSLock()
    private var document: PermissionDecisionHistoryDocument

    init(
        fileURL: URL = defaultPermissionDecisionHistoryURL(),
        fileManager: FileManager = .default,
        maximumRecords: Int = 200
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.maximumRecords = min(1_000, max(1, maximumRecords))
        document = Self.load(
            from: fileURL.standardizedFileURL,
            fileManager: fileManager,
            maximumRecords: self.maximumRecords
        )
    }

    func snapshot() -> [PermissionDecisionHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(document.records.reversed())
    }

    @discardableResult
    func record(_ requestedRecord: PermissionDecisionHistoryRecord) -> Bool {
        guard let record = requestedRecord.sanitized() else { return false }
        lock.lock()
        defer { lock.unlock() }

        var candidate = document
        candidate.records.append(record)
        if candidate.records.count > maximumRecords {
            candidate.records.removeFirst(
                candidate.records.count - maximumRecords
            )
        }
        guard persist(candidate) else { return false }
        document = candidate
        return true
    }

    private static func load(
        from fileURL: URL,
        fileManager: FileManager,
        maximumRecords: Int
    ) -> PermissionDecisionHistoryDocument {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                  PermissionDecisionHistoryDocument.self,
                  from: data
              ),
              decoded.schemaVersion == 1
        else { return .empty }
        let records = decoded.records.compactMap { $0.sanitized() }
        return PermissionDecisionHistoryDocument(
            schemaVersion: 1,
            records: Array(records.suffix(maximumRecords))
        )
    }

    private func persist(_ document: PermissionDecisionHistoryDocument) -> Bool {
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

func defaultPermissionDecisionHistoryURL(
    fileManager: FileManager = .default
) -> URL {
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("permission-history-v1.json")
}

private func sanitizedPermissionVersionSignature(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 256,
          trimmed.range(
              of: #"^[A-Za-z0-9._=;+() -]+$"#,
              options: .regularExpression
          ) != nil
    else { return nil }
    return trimmed
}
