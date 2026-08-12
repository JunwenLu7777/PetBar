//
//  AgentEventReducer.swift
//  ThreadHelm
//
//  模块职责：把重复、乱序的归一化事件确定性地归并为会话与注意力快照。
//

import Foundation

enum AgentEventReducer {
    static func reduce(
        events: [AgentEvent],
        previousSnapshots: [AgentSessionSnapshot] = [],
        preservingAgentIDs: Set<AgentID> = []
    ) -> AgentReductionResult {
        let uniqueEvents = deduplicated(events)
        let grouped = Dictionary(grouping: uniqueEvents, by: \.identity.key)
        var snapshots = grouped.values.compactMap { sessionEvents in
            latestEvent(in: sessionEvents).map(makeSnapshot)
        }

        let freshKeys = Set(snapshots.map(\.identity.key))
        snapshots.append(contentsOf: previousSnapshots.filter {
            preservingAgentIDs.contains($0.identity.agentID)
                && !freshKeys.contains($0.identity.key)
        })
        snapshots.sort(by: agentSnapshotIsOrderedBefore)

        let attentionItems = snapshots.compactMap { snapshot -> AgentAttentionItem? in
            guard snapshot.attentionReason != .none else { return nil }
            return AgentAttentionItem(
                identity: snapshot.identity,
                reason: snapshot.attentionReason,
                actionability: snapshot.actionability,
                evidenceQuality: snapshot.evidenceQuality,
                updatedAt: snapshot.updatedAt,
                isInterrupting: snapshot.attentionReason.isInterrupting
            )
        }

        return AgentReductionResult(
            snapshots: snapshots,
            attentionItems: attentionItems,
            processedEventCount: uniqueEvents.count
        )
    }

    private static func deduplicated(_ events: [AgentEvent]) -> [AgentEvent] {
        Dictionary(grouping: events) {
            "\($0.identity.key):\($0.eventID)"
        }.values.compactMap { duplicates in
            duplicates.max(by: deterministicFallbackIsEarlier)
        }
    }

    private static func latestEvent(in events: [AgentEvent]) -> AgentEvent? {
        guard !events.isEmpty else { return nil }
        if events.allSatisfy({ $0.sequence != nil }) {
            return events.max { lhs, rhs in
                if lhs.sequence != rhs.sequence {
                    return (lhs.sequence ?? Int.min) < (rhs.sequence ?? Int.min)
                }
                return deterministicFallbackIsEarlier(lhs, rhs)
            }
        }
        if events.allSatisfy({ $0.monotonicNanoseconds != nil }) {
            return events.max { lhs, rhs in
                if lhs.monotonicNanoseconds != rhs.monotonicNanoseconds {
                    return (lhs.monotonicNanoseconds ?? 0)
                        < (rhs.monotonicNanoseconds ?? 0)
                }
                return deterministicFallbackIsEarlier(lhs, rhs)
            }
        }
        return events.max(by: deterministicFallbackIsEarlier)
    }

    private static func makeSnapshot(_ event: AgentEvent) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            identity: event.identity,
            adapterVersion: event.adapterVersion,
            executionState: event.executionState,
            attentionReason: event.attentionReason,
            actionability: event.actionability,
            evidenceQuality: event.evidenceQuality,
            freshness: event.freshness,
            title: event.title,
            activitySummary: event.activitySummary,
            latestEventID: event.eventID,
            updatedAt: event.observedAt
        )
    }

    private static func deterministicFallbackIsEarlier(
        _ lhs: AgentEvent,
        _ rhs: AgentEvent
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt < rhs.observedAt
        }
        if lhs.identity.key != rhs.identity.key {
            return lhs.identity.key < rhs.identity.key
        }
        if lhs.eventID != rhs.eventID {
            return lhs.eventID < rhs.eventID
        }
        if lhs.executionState.rawValue != rhs.executionState.rawValue {
            return lhs.executionState.rawValue < rhs.executionState.rawValue
        }
        if lhs.attentionReason.rawValue != rhs.attentionReason.rawValue {
            return lhs.attentionReason.rawValue < rhs.attentionReason.rawValue
        }
        return lhs.eventType < rhs.eventType
    }
}
