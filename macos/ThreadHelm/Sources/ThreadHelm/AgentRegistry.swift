//
//  AgentRegistry.swift
//  ThreadHelm
//
//  模块职责：按 AgentID 去重并稳定排序的来源注册表。
//

import Foundation

struct AgentRegistry {
    private let adaptersByID: [AgentID: any AgentAdapter]
    let agentIDs: [AgentID]

    init(adapters: [any AgentAdapter]) {
        var indexed: [AgentID: any AgentAdapter] = [:]
        for adapter in adapters where indexed[adapter.metadata.id] == nil {
            indexed[adapter.metadata.id] = adapter
        }
        adaptersByID = indexed
        agentIDs = indexed.keys.sorted()
    }

    var count: Int { agentIDs.count }

    func adapter(for id: AgentID) -> (any AgentAdapter)? {
        adaptersByID[id]
    }

    func metadata(for id: AgentID) -> AgentMetadata? {
        adaptersByID[id]?.metadata
    }

    var metadata: [AgentMetadata] {
        agentIDs.compactMap { adaptersByID[$0]?.metadata }
    }

    static let builtIn = AgentRegistry(adapters: builtInAgentAdapters())
}
