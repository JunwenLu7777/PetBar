//
//  AgentModels.swift
//  ThreadHelm
//
//  模块职责：五 Agent 共用的身份、能力、状态、注意力和返回结果模型。
//

import Foundation

struct AgentID: RawRepresentable, Hashable, Codable, Comparable,
    CustomStringConvertible
{
    let rawValue: String

    init(rawValue: String) {
        let candidate = String(rawValue.prefix(64))
        self.rawValue = AgentID.isValid(candidate) ? candidate : "unknown"
    }

    static let codex = AgentID(rawValue: "codex")
    static let claudeCode = AgentID(rawValue: "claudeCode")
    static let cursor = AgentID(rawValue: "cursor")
    static let zcode = AgentID(rawValue: "zcode")
    static let pi = AgentID(rawValue: "pi")

    static let builtInOrder: [AgentID] = [
        .codex,
        .claudeCode,
        .cursor,
        .zcode,
        .pi,
    ]

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let candidate = try container.decode(String.self)
        guard candidate.count <= 64, AgentID.isValid(candidate) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid AgentID"
            )
        }
        rawValue = candidate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil
    }

    static func < (lhs: AgentID, rhs: AgentID) -> Bool {
        let lhsIndex = builtInOrder.firstIndex(of: lhs)
        let rhsIndex = builtInOrder.firstIndex(of: rhs)
        switch (lhsIndex, rhsIndex) {
        case let (lhsIndex?, rhsIndex?):
            return lhsIndex < rhsIndex
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.rawValue < rhs.rawValue
        }
    }
}

enum AgentCapability: String, CaseIterable, Codable, Hashable {
    case lifecycleObservation
    case stableIdentity
    case exactReturn
    case nativeNavigation
    case inAppPermission
    case inAppQuestion
    case inAppPlanApproval
    case quota
    case subagentEvents
    case managedIntegration
    case sessionMutation
    case messageInjection
    case cancellation
}

enum AgentCapabilityStatus: String, Codable, Equatable {
    case supported
    case unsupported
    case unknown
}

struct AgentCapabilitySet: Codable, Equatable {
    private let statuses: [AgentCapability: AgentCapabilityStatus]

    init(
        supported: Set<AgentCapability> = [],
        unknown: Set<AgentCapability> = []
    ) {
        var values = Dictionary(
            uniqueKeysWithValues: AgentCapability.allCases.map {
                ($0, AgentCapabilityStatus.unsupported)
            }
        )
        for capability in unknown {
            values[capability] = .unknown
        }
        for capability in supported {
            values[capability] = .supported
        }
        statuses = values
    }

    func status(for capability: AgentCapability) -> AgentCapabilityStatus {
        statuses[capability] ?? .unsupported
    }

    func supports(_ capability: AgentCapability) -> Bool {
        status(for: capability) == .supported
    }
}

enum ExecutionState: String, Codable, Equatable {
    case discovering
    case idle
    case running
    case completed
    case failed
    case stale
    case offline
}

extension ExecutionState {
    static var transportAllowedRawValues: [String] {
        [
            discovering, idle, running, completed, failed, stale, offline,
        ].map(\.rawValue)
    }
}

enum AttentionReason: String, Codable, Equatable {
    case permission
    case question
    case planApproval
    case blocked
    case reviewReady
    case taskFailure
    case none

    var isInterrupting: Bool {
        switch self {
        case .permission, .question, .planApproval, .blocked, .taskFailure:
            return true
        case .reviewReady, .none:
            return false
        }
    }

    fileprivate var sortPriority: Int {
        switch self {
        case .permission, .question, .planApproval:
            return 5
        case .taskFailure, .blocked:
            return 4
        case .reviewReady:
            return 3
        case .none:
            return 0
        }
    }
}

extension AttentionReason {
    static var transportAllowedRawValues: [String] {
        [
            permission, question, planApproval, blocked, reviewReady,
            taskFailure, none,
        ].map(\.rawValue)
    }
}

enum Actionability: String, Codable, Equatable {
    case inApp
    case openExactNativeSession
    case openNativeApp
    case openWorkingDirectory
    case viewOnly
}

extension Actionability {
    static var transportAllowedRawValues: [String] {
        [
            inApp, openExactNativeSession, openNativeApp,
            openWorkingDirectory, viewOnly,
        ].map(\.rawValue)
    }
}

enum EvidenceQuality: String, Codable, Equatable {
    case officialHook
    case officialAPI
    case nativeState
    case transcript
    case processObservation
    case inferred
    case unknown
}

extension EvidenceQuality {
    static var transportAllowedRawValues: [String] {
        [
            officialHook, officialAPI, nativeState, transcript,
            processObservation, inferred, unknown,
        ].map(\.rawValue)
    }
}

struct Freshness: Codable, Equatable {
    let observedAt: Date
    let expiresAt: Date?
    let staleReason: String?

    init(
        observedAt: Date,
        expiresAt: Date?,
        staleReason: String? = nil
    ) {
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.staleReason = staleReason
    }

    func isStale(at now: Date) -> Bool {
        staleReason != nil || expiresAt.map { now >= $0 } == true
    }
}

struct AgentSessionIdentity: Codable, Hashable {
    let agentID: AgentID
    let nativeID: String
    let processID: Int32?
    let processStartIdentity: String?

    init(
        agentID: AgentID,
        nativeID: String,
        processID: Int32? = nil,
        processStartIdentity: String? = nil
    ) {
        self.agentID = agentID
        self.nativeID = nativeID
        self.processID = processID
        self.processStartIdentity = processStartIdentity
    }

    var key: String {
        "\(agentID.rawValue):\(nativeID)"
    }
}

enum OpenResult: String, Codable, Equatable {
    case exactSession
    case appFocused
    case workingDirectoryFallback
    case unavailable
    case failed
    case notAttempted
    case unknown
}

extension OpenResult {
    var feedbackTitle: String {
        switch self {
        case .exactSession: return "已打开会话"
        case .appFocused: return "已打开应用"
        case .workingDirectoryFallback: return "仅打开目录"
        case .unavailable: return "不可打开"
        case .failed: return "打开失败"
        case .notAttempted: return "未尝试打开"
        case .unknown: return "已尝试恢复"
        }
    }

    var feedbackDescription: String {
        switch self {
        case .exactSession:
            return "已返回同一个原生会话"
        case .appFocused:
            return "只打开了原生应用，未确认具体会话"
        case .workingDirectoryFallback:
            return "只打开了工作目录，不是原来的精确会话"
        case .unavailable:
            return "当前没有安全可用的打开方式"
        case .failed:
            return "已经尝试打开，但操作失败"
        case .notAttempted:
            return "没有执行打开操作"
        case .unknown:
            return "已发起打开，但尚未确认是否回到原会话"
        }
    }
}

struct AgentEvent: Codable, Equatable {
    let identity: AgentSessionIdentity
    let adapterVersion: String
    let eventID: String
    let sequence: Int?
    let eventType: String
    let observedAt: Date
    let monotonicNanoseconds: UInt64?
    let executionState: ExecutionState
    let attentionReason: AttentionReason
    let actionability: Actionability
    let evidenceQuality: EvidenceQuality
    let freshness: Freshness
    let title: String
    let activitySummary: String?
    let workingDirectory: String?
}

struct AgentSessionSnapshot: Codable, Equatable {
    let identity: AgentSessionIdentity
    let adapterVersion: String
    let executionState: ExecutionState
    let attentionReason: AttentionReason
    let actionability: Actionability
    let evidenceQuality: EvidenceQuality
    let freshness: Freshness
    let title: String
    let activitySummary: String?
    let workingDirectory: String?
    let latestEventID: String
    let updatedAt: Date
}

struct AgentAttentionItem: Codable, Equatable {
    let identity: AgentSessionIdentity
    let reason: AttentionReason
    let actionability: Actionability
    let evidenceQuality: EvidenceQuality
    let updatedAt: Date
    let isInterrupting: Bool
}

struct AgentReductionResult: Equatable {
    let snapshots: [AgentSessionSnapshot]
    let attentionItems: [AgentAttentionItem]
    let processedEventCount: Int
}

struct AgentMetadata: Equatable {
    let id: AgentID
    let displayName: String
    let shortName: String
    let iconResourceName: String
    let fallbackSymbolName: String
    let brandColor: AgentColorComponents
    let versionSource: String
    let identityPolicy: String
    let capabilities: AgentCapabilitySet
}

func agentSnapshotIsOrderedBefore(
    _ lhs: AgentSessionSnapshot,
    _ rhs: AgentSessionSnapshot
) -> Bool {
    if lhs.attentionReason.sortPriority != rhs.attentionReason.sortPriority {
        return lhs.attentionReason.sortPriority > rhs.attentionReason.sortPriority
    }
    if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
    }
    if lhs.identity.agentID != rhs.identity.agentID {
        return lhs.identity.agentID < rhs.identity.agentID
    }
    return lhs.identity.key < rhs.identity.key
}
