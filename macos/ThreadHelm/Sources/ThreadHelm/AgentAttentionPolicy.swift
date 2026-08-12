//
//  AgentAttentionPolicy.swift
//  ThreadHelm
//
//  模块职责：集中定义低噪声注意力分类，并在内存中合并短时间内重复的
//  Agent + 原生会话 + 原因；不持久化会话身份或时间线。
//

import Foundation

enum AgentAttentionPolicy {
    static let coalescingInterval: TimeInterval = 60

    static func shouldInterrupt(
        reason: AttentionReason,
        evidenceQuality: EvidenceQuality
    ) -> Bool {
        switch reason {
        case .permission, .question, .planApproval, .taskFailure:
            return true
        case .blocked:
            return [
                EvidenceQuality.officialHook,
                .officialAPI,
                .nativeState,
                .transcript,
            ].contains(evidenceQuality)
        case .reviewReady, .none:
            return false
        }
    }
}

func agentAttentionItems(
    from snapshots: [AgentSessionSnapshot]
) -> [AgentAttentionItem] {
    snapshots.compactMap { snapshot in
        guard snapshot.attentionReason != .none else { return nil }
        return AgentAttentionItem(
            identity: snapshot.identity,
            reason: snapshot.attentionReason,
            actionability: snapshot.actionability,
            evidenceQuality: snapshot.evidenceQuality,
            updatedAt: snapshot.updatedAt,
            isInterrupting: AgentAttentionPolicy.shouldInterrupt(
                reason: snapshot.attentionReason,
                evidenceQuality: snapshot.evidenceQuality
            )
        )
    }
}

func foregroundHandledAgentSessionKeys(
    presentationState: DynamicIslandPresentationState?,
    selectedTaskKey: String?,
    permissionQueue: ClaudePermissionQueueSnapshot
) -> Set<String> {
    switch presentationState {
    case .expanded(.tasks):
        return selectedTaskKey.map { [$0] } ?? []
    case .expanded(.confirmation):
        guard let current = permissionQueue.current else { return [] }
        let nativeID = current.sessionID?.lowercased()
            ?? "request-\(current.requestID.uuidString.lowercased())"
        return [AgentSessionIdentity(
            agentID: .claudeCode,
            nativeID: nativeID
        ).key]
    case nil, .hidden, .capsule, .expanded(.agents), .expanded(.quota):
        return []
    }
}

final class AgentAttentionInterruptionGate {
    private struct Key: Hashable {
        let agentID: AgentID
        let nativeID: String
        let reason: AttentionReason
    }

    private struct Entry {
        var lastHandledAt: Date
        var isActive: Bool
    }

    private let coalescingInterval: TimeInterval
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    init(
        coalescingInterval: TimeInterval = AgentAttentionPolicy
            .coalescingInterval
    ) {
        self.coalescingInterval = max(0, coalescingInterval)
    }

    func evaluate(
        items: [AgentAttentionItem],
        foregroundSessionKeys: Set<String> = [],
        at now: Date = Date()
    ) -> [AgentAttentionItem] {
        lock.lock()
        defer { lock.unlock() }

        let activeKeys = Set(items.compactMap { item -> Key? in
            guard item.isInterrupting else { return nil }
            return key(for: item)
        })
        for key in entries.keys where !activeKeys.contains(key) {
            entries[key]?.isActive = false
        }
        entries = entries.filter { _, entry in
            entry.isActive
                || now < entry.lastHandledAt.addingTimeInterval(
                    coalescingInterval
                )
        }

        return items.map { item in
            guard item.isInterrupting else { return item }
            let key = key(for: item)
            let existing = entries[key]
            let isAlreadyActive = existing?.isActive == true
            let isRecent = existing.map {
                now < $0.lastHandledAt.addingTimeInterval(coalescingInterval)
            } ?? false
            let isHandledInForeground = foregroundSessionKeys.contains(
                item.identity.key
            )
            let shouldInterrupt = !isAlreadyActive
                && !isRecent
                && !isHandledInForeground

            if shouldInterrupt || isHandledInForeground {
                entries[key] = Entry(lastHandledAt: now, isActive: true)
            } else if var existing {
                existing.isActive = true
                entries[key] = existing
            } else {
                entries[key] = Entry(lastHandledAt: now, isActive: true)
            }
            return attentionItem(item, isInterrupting: shouldInterrupt)
        }
    }

    private func key(for item: AgentAttentionItem) -> Key {
        Key(
            agentID: item.identity.agentID,
            nativeID: item.identity.nativeID,
            reason: item.reason
        )
    }

    private func attentionItem(
        _ item: AgentAttentionItem,
        isInterrupting: Bool
    ) -> AgentAttentionItem {
        AgentAttentionItem(
            identity: item.identity,
            reason: item.reason,
            actionability: item.actionability,
            evidenceQuality: item.evidenceQuality,
            updatedAt: item.updatedAt,
            isInterrupting: isInterrupting
        )
    }
}
