//
//  AgentPersonalSessionEvidence.swift
//  ThreadHelm
//
//  模块职责：仅在主人显式确认后，为五个本地 Agent 保存真实使用会话
//  的计数；不保存时间、标题、路径、session ID、评分或任务内容。
//

import Darwin
import Foundation

enum AgentPersonalSessionEvidenceSource: Equatable {
    case explicitOwnerRecord
    case truthFixtureReplay
}

enum AgentPersonalReadiness: String, Equatable {
    case experimental
    case personalReady = "personal-ready"
}

struct AgentPersonalReadinessAssessment: Equatable {
    static let requiredPersonalSessionCount = 10

    let personalSessionCount: Int
    let independentlyReviewed: Bool

    init(
        personalSessionCount: Int,
        independentlyReviewed: Bool
    ) {
        self.personalSessionCount = max(0, personalSessionCount)
        self.independentlyReviewed = independentlyReviewed
    }

    var readiness: AgentPersonalReadiness {
        personalSessionCount >= Self.requiredPersonalSessionCount
            && independentlyReviewed
            ? .personalReady
            : .experimental
    }
}

struct AgentValidationProfile: Equatable {
    let agentID: AgentID
    let testedVersion: String
    let supportedCapabilitiesSummary: String
    let knownLimitation: String
}

func builtInAgentValidationProfiles() -> [AgentID: AgentValidationProfile] {
    let profiles = [
        AgentValidationProfile(
            agentID: .codex,
            testedVersion: "0.145.0",
            supportedCapabilitiesSummary:
                "支持：状态、问题提醒、原生线程打开、额度",
            knownLimitation:
                "限制：精确返回未独立确认；权限与计划需回到 Codex 处理"
        ),
        AgentValidationProfile(
            agentID: .claudeCode,
            testedVersion: "2.1.226",
            supportedCapabilitiesSummary:
                "支持：状态、权限/问题/计划确认、原生会话返回、额度",
            knownLimitation:
                "限制：resume 启动不等于精确返回；需匹配存活进程与终端标签"
        ),
        AgentValidationProfile(
            agentID: .cursor,
            testedVersion: "Desktop 3.15.6 · Agent CLI 2026.04.14-ee4b43a",
            supportedCapabilitiesSummary:
                "支持：状态、原生应用/项目打开、子 Agent 事件",
            knownLimitation:
                "限制：精确会话返回及阻塞/输入识别尚未验证"
        ),
        AgentValidationProfile(
            agentID: .zcode,
            testedVersion: "3.7.6 · build 3.7.6.4691",
            supportedCapabilitiesSummary: "支持：状态、原生应用/项目打开",
            knownLimitation:
                "限制：精确会话、问题/计划语义和 SessionEnd 尚未验证"
        ),
        AgentValidationProfile(
            agentID: .pi,
            testedVersion: "0.84.1",
            supportedCapabilitiesSummary: "支持：只读状态",
            knownLimitation:
                "限制：不支持审批、输入、取消或导航；精确返回尚未验证"
        ),
    ]
    return Dictionary(uniqueKeysWithValues: profiles.map {
        ($0.agentID, $0)
    })
}

struct AgentPersonalSessionEvidenceSnapshot: Equatable {
    fileprivate var counts: [String: Int]

    static let zero = AgentPersonalSessionEvidenceSnapshot(counts: [:])

    init(counts: [String: Int]) {
        self.counts = Dictionary(uniqueKeysWithValues:
            AgentID.builtInOrder.map { agentID in
                (agentID.rawValue, max(0, counts[agentID.rawValue] ?? 0))
            }
        )
    }

    func count(for agentID: AgentID) -> Int {
        guard AgentID.builtInOrder.contains(agentID) else { return 0 }
        return counts[agentID.rawValue] ?? 0
    }

    fileprivate mutating func increment(agentID: AgentID) {
        let current = count(for: agentID)
        counts[agentID.rawValue] = current == Int.max
            ? current
            : current + 1
    }
}

final class AgentPersonalSessionEvidenceStore {
    private let fileURL: URL
    private let processLockURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var currentSnapshot: AgentPersonalSessionEvidenceSnapshot

    init(
        fileURL: URL = defaultAgentPersonalSessionEvidenceURL(),
        fileManager: FileManager = .default
    ) {
        let standardizedFileURL = fileURL.standardizedFileURL
        self.fileURL = standardizedFileURL
        processLockURL = URL(
            fileURLWithPath: standardizedFileURL.path + ".lock"
        )
        self.fileManager = fileManager
        currentSnapshot = Self.load(from: self.fileURL)
    }

    func snapshot() -> AgentPersonalSessionEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    func refreshedSnapshot() -> AgentPersonalSessionEvidenceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        currentSnapshot = Self.load(from: fileURL)
        return currentSnapshot
    }

    @discardableResult
    func record(
        agentID: AgentID,
        source: AgentPersonalSessionEvidenceSource
    ) -> Bool {
        guard AgentID.builtInOrder.contains(agentID),
              source == .explicitOwnerRecord
        else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard prepareStorageDirectory(),
              let processLockDescriptor = openProcessLock()
        else { return false }
        defer { close(processLockDescriptor) }
        guard acquireExclusiveLock(processLockDescriptor) else { return false }
        defer { _ = flock(processLockDescriptor, LOCK_UN) }

        var candidate = Self.load(from: fileURL)
        candidate.increment(agentID: agentID)
        guard persist(candidate) else { return false }
        currentSnapshot = candidate
        return true
    }

    private func prepareStorageDirectory() -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
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
            return true
        } catch {
            return false
        }
    }

    private func openProcessLock() -> Int32? {
        let descriptor = open(
            processLockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func acquireExclusiveLock(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    private static func load(
        from fileURL: URL
    ) -> AgentPersonalSessionEvidenceSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(
                  [String: Int].self,
                  from: data
              )
        else { return .zero }
        return AgentPersonalSessionEvidenceSnapshot(counts: decoded)
    }

    private func persist(
        _ snapshot: AgentPersonalSessionEvidenceSnapshot
    ) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            guard prepareStorageDirectory() else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot.counts)
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

enum AgentPersonalSessionEvidenceCLIRequest: Equatable {
    case notRequested
    case invalid
    case printSnapshot
    case record(agentID: AgentID)
}

func parseAgentPersonalSessionEvidenceCLI(
    _ arguments: [String]
) -> AgentPersonalSessionEvidenceCLIRequest {
    if arguments.contains("--print-personal-session-evidence") {
        return arguments.count == 2 ? .printSnapshot : .invalid
    }
    guard let flagIndex = arguments.firstIndex(
        of: "--record-personal-session"
    ) else { return .notRequested }
    guard arguments.count == 3, flagIndex == 1 else { return .invalid }
    let agentID = AgentID(rawValue: arguments[flagIndex + 1])
    guard AgentID.builtInOrder.contains(agentID) else { return .invalid }
    return .record(agentID: agentID)
}

func runAgentPersonalSessionEvidenceCLIIfRequested(
    arguments: [String] = CommandLine.arguments,
    store: AgentPersonalSessionEvidenceStore? = nil
) -> Int? {
    switch parseAgentPersonalSessionEvidenceCLI(arguments) {
    case .notRequested:
        return nil
    case .invalid:
        fputs(
            "用法：--print-personal-session-evidence 或 "
                + "--record-personal-session {codex|claudeCode|cursor|zcode|pi}\n",
            stderr
        )
        return 2
    case .printSnapshot:
        let activeStore = store ?? AgentPersonalSessionEvidenceStore()
        print(agentPersonalSessionEvidenceDiagnosticText(activeStore.snapshot()))
        return 0
    case .record(let agentID):
        let activeStore = store ?? AgentPersonalSessionEvidenceStore()
        guard activeStore.record(
            agentID: agentID,
            source: .explicitOwnerRecord
        ) else {
            fputs("ThreadHelm 无法写入本地个人会话计数。\n", stderr)
            return 1
        }
        print("personal-session-evidence: recorded \(agentID.rawValue)")
        print(agentPersonalSessionEvidenceDiagnosticText(activeStore.snapshot()))
        return 0
    }
}

func agentPersonalSessionEvidenceDiagnosticText(
    _ snapshot: AgentPersonalSessionEvidenceSnapshot
) -> String {
    AgentID.builtInOrder.map { agentID in
        "\(agentID.rawValue) " + agentPersonalReadinessText(
            personalSessionCount: snapshot.count(for: agentID),
            independentlyReviewed: false
        )
    }.joined(separator: "\n")
}

func agentPersonalReadinessText(
    personalSessionCount: Int,
    independentlyReviewed: Bool = false
) -> String {
    let assessment = AgentPersonalReadinessAssessment(
        personalSessionCount: personalSessionCount,
        independentlyReviewed: independentlyReviewed
    )
    let count = assessment.personalSessionCount
    var text = "\(assessment.readiness.rawValue) · 真实会话 \(count)/"
        + "\(AgentPersonalReadinessAssessment.requiredPersonalSessionCount)"
    if assessment.readiness == .experimental,
       count >= AgentPersonalReadinessAssessment.requiredPersonalSessionCount
    {
        text += " · 待独立验收"
    }
    return text
}

func defaultAgentPersonalSessionEvidenceURL(
    fileManager: FileManager = .default
) -> URL {
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("personal-session-evidence-v1.json")
}
