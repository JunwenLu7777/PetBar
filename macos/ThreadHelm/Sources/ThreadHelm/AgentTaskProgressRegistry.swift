//
//  AgentTaskProgressRegistry.swift
//  ThreadHelm
//
//  模块职责：按注册来源读取任务；单个来源失败时保留其上一帧，不清空其他来源。
//

import Foundation

struct AgentTaskProgressSource {
    let agentID: AgentID
    let readItems: () throws -> [TaskProgressItem]
}

final class AgentTaskProgressRegistry {
    private let sources: [AgentTaskProgressSource]
    private let cacheLock = NSLock()
    private var lastItemsByAgentID: [AgentID: [TaskProgressItem]] = [:]

    init(sources: [AgentTaskProgressSource]) {
        var seen = Set<AgentID>()
        self.sources = sources
            .filter { seen.insert($0.agentID).inserted }
            .sorted { $0.agentID < $1.agentID }
    }

    var agentIDs: [AgentID] {
        sources.map(\.agentID)
    }

    func readCollection() -> TaskProgressCollectionSnapshot {
        var items: [TaskProgressItem] = []
        for source in sources {
            do {
                let fresh = try source.readItems().filter {
                    $0.source == source.agentID
                        && $0.kind != .idle
                        && $0.kind != .reading
                }
                store(fresh, for: source.agentID)
                items.append(contentsOf: fresh)
            } catch {
                items.append(contentsOf: cachedItems(for: source.agentID))
            }
        }
        return .displaying(items)
    }

    private func store(_ items: [TaskProgressItem], for agentID: AgentID) {
        cacheLock.lock()
        lastItemsByAgentID[agentID] = items
        cacheLock.unlock()
    }

    private func cachedItems(for agentID: AgentID) -> [TaskProgressItem] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastItemsByAgentID[agentID] ?? []
    }
}

func defaultAgentTaskProgressSources() -> [AgentTaskProgressSource] {
    let codexAdapter = CodexAgentAdapter()
    let claudeAdapter = ClaudeCodeAgentAdapter()
    return [
        AgentTaskProgressSource(agentID: .codex) {
            codexAdapter.readTaskProgressCollection().items
        },
        AgentTaskProgressSource(agentID: .claudeCode) {
            claudeAdapter.readTaskProgressCollection().items
        },
        AgentTaskProgressSource(agentID: .cursor) { [] },
        AgentTaskProgressSource(agentID: .zcode) { [] },
        AgentTaskProgressSource(agentID: .omp) { [] },
    ]
}
