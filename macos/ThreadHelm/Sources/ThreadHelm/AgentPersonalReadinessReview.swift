//
//  AgentPersonalReadinessReview.swift
//  ThreadHelm
//
//  模块职责：在主人完成十次真实会话后的单独复核中，只为五个本地 Agent
//  保存可撤销的布尔值；不保存时间、备注、任务内容或会话身份。
//

import Darwin
import Foundation

struct AgentPersonalReadinessReviewSnapshot: Equatable {
    fileprivate var reviewed: [String: Bool]

    static let none = AgentPersonalReadinessReviewSnapshot(reviewed: [:])

    init(reviewed: [String: Bool]) {
        self.reviewed = Dictionary(uniqueKeysWithValues:
            AgentID.builtInOrder.map { agentID in
                (agentID.rawValue, reviewed[agentID.rawValue] ?? false)
            }
        )
    }

    func isReviewed(for agentID: AgentID) -> Bool {
        guard AgentID.builtInOrder.contains(agentID) else { return false }
        return reviewed[agentID.rawValue] ?? false
    }

    fileprivate mutating func setReviewed(
        _ value: Bool,
        for agentID: AgentID
    ) {
        reviewed[agentID.rawValue] = value
    }
}

enum AgentPersonalReadinessReviewMutationResult: Equatable {
    case updated
    case unchanged
    case insufficientPersonalSessions
    case invalidAgent
    case failed
}

final class AgentPersonalReadinessReviewStore {
    private static let maximumReviewFileBytes: off_t = 4_096
    private let fileURL: URL
    private let processLockURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var currentSnapshot: AgentPersonalReadinessReviewSnapshot

    init(
        fileURL: URL = defaultAgentPersonalReadinessReviewURL(),
        fileManager: FileManager = .default
    ) {
        let standardizedFileURL = fileURL.standardizedFileURL
        self.fileURL = standardizedFileURL
        processLockURL = URL(
            fileURLWithPath: standardizedFileURL.path + ".lock"
        )
        self.fileManager = fileManager
        currentSnapshot = Self.load(from: standardizedFileURL)
    }

    func snapshot() -> AgentPersonalReadinessReviewSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }

    func refreshedSnapshot() -> AgentPersonalReadinessReviewSnapshot {
        lock.lock()
        defer { lock.unlock() }
        currentSnapshot = Self.load(from: fileURL)
        return currentSnapshot
    }

    func confirm(
        agentID: AgentID,
        personalSessions: AgentPersonalSessionEvidenceSnapshot
    ) -> AgentPersonalReadinessReviewMutationResult {
        guard AgentID.builtInOrder.contains(agentID) else {
            return .invalidAgent
        }
        guard personalSessions.count(for: agentID)
            >= AgentPersonalReadinessAssessment.requiredPersonalSessionCount
        else {
            return .insufficientPersonalSessions
        }
        return setReviewed(true, for: agentID)
    }

    func revoke(
        agentID: AgentID
    ) -> AgentPersonalReadinessReviewMutationResult {
        guard AgentID.builtInOrder.contains(agentID) else {
            return .invalidAgent
        }
        return setReviewed(false, for: agentID)
    }

    private func setReviewed(
        _ value: Bool,
        for agentID: AgentID
    ) -> AgentPersonalReadinessReviewMutationResult {
        lock.lock()
        defer { lock.unlock() }
        guard prepareStorageDirectory(),
              let processLockDescriptor = openProcessLock()
        else { return .failed }
        defer { close(processLockDescriptor) }
        guard acquireExclusiveLock(processLockDescriptor) else {
            return .failed
        }
        defer { _ = flock(processLockDescriptor, LOCK_UN) }
        guard normalizeProcessLock(processLockDescriptor) else {
            return .failed
        }

        var candidate = Self.load(from: fileURL)
        guard candidate.isReviewed(for: agentID) != value else {
            currentSnapshot = candidate
            return .unchanged
        }
        candidate.setReviewed(value, for: agentID)
        guard persist(candidate) else { return .failed }
        currentSnapshot = candidate
        return .updated
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
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1
        else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func normalizeProcessLock(_ descriptor: Int32) -> Bool {
        fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
            && ftruncate(descriptor, 0) == 0
    }

    private func acquireExclusiveLock(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    private static func load(
        from fileURL: URL
    ) -> AgentPersonalReadinessReviewSnapshot {
        guard let data = readOwnerOnlyRegularFile(from: fileURL),
              let decoded = try? JSONDecoder().decode(
                  [String: Bool].self,
                  from: data
              ),
              Set(decoded.keys)
                  == Set(AgentID.builtInOrder.map(\.rawValue))
        else { return .none }
        return AgentPersonalReadinessReviewSnapshot(reviewed: decoded)
    }

    private static func readOwnerOnlyRegularFile(
        from fileURL: URL
    ) -> Data? {
        let descriptor = open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_nlink == 1,
              fileStatus.st_mode & 0o777 == 0o600,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= Self.maximumReviewFileBytes
        else { return nil }

        let expectedByteCount = Int(fileStatus.st_size)
        guard expectedByteCount > 0 else { return Data() }
        var data = Data(count: expectedByteCount)
        let readComplete = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < expectedByteCount {
                let byteCount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset
                )
                if byteCount < 0 {
                    guard errno == EINTR else { return false }
                    continue
                }
                guard byteCount > 0 else { return false }
                offset += byteCount
            }
            return true
        }
        guard readComplete else { return nil }

        var trailingByte: UInt8 = 0
        while true {
            let trailingByteCount = Darwin.read(
                descriptor,
                &trailingByte,
                1
            )
            if trailingByteCount < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            return trailingByteCount == 0 ? data : nil
        }
    }

    private func persist(
        _ snapshot: AgentPersonalReadinessReviewSnapshot
    ) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            guard prepareStorageDirectory() else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot.reviewed)
            let descriptor = open(
                temporaryURL.path,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { return false }
            var removeTemporaryFile = true
            defer {
                close(descriptor)
                if removeTemporaryFile {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  writeAll(data, to: descriptor),
                  fsync(descriptor) == 0,
                  rename(temporaryURL.path, fileURL.path) == 0
            else { return false }
            removeTemporaryFile = false
            return true
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            return false
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < data.count {
                let byteCount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if byteCount < 0 {
                    guard errno == EINTR else { return false }
                    continue
                }
                guard byteCount > 0 else { return false }
                offset += byteCount
            }
            return true
        }
    }
}

func defaultAgentPersonalReadinessReviewURL(
    fileManager: FileManager = .default
) -> URL {
    let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
        .appendingPathComponent("ThreadHelm", isDirectory: true)
        .appendingPathComponent("personal-readiness-review-v1.json")
}
