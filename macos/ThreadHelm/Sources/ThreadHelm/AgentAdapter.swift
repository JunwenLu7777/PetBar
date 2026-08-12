//
//  AgentAdapter.swift
//  ThreadHelm
//
//  模块职责：定义 Agent 发现、集成生命周期、观察、打开和诊断契约。
//

import Foundation

enum AgentCompatibility: String, Equatable {
    case supported
    case unsupportedVersion
    case unknown
}

struct AgentDiscovery: Equatable {
    let isInstalled: Bool
    let version: String?
    let compatibility: AgentCompatibility
}

enum AgentIntegrationStatus: String, Equatable {
    case notManaged
    case notInstalled
    case installed
    case disabled
    case needsRepair
    case unsupportedVersion
}

enum AgentIntegrationOperationResult: String, Equatable {
    case notManaged
    case unchanged
    case installed
    case repaired
    case uninstalled
}

struct AgentIntegrationScope: Equatable {
    let rootDirectory: URL
    let permitsLiveConfigurationChanges: Bool

    static func isolated(at rootDirectory: URL) -> AgentIntegrationScope {
        AgentIntegrationScope(
            rootDirectory: rootDirectory,
            permitsLiveConfigurationChanges: false
        )
    }
}

struct AgentObservation: Equatable {
    let events: [AgentEvent]
    let snapshots: [AgentSessionSnapshot]
}

enum AgentHealth: String, Equatable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

struct AgentDiagnostics: Equatable {
    let health: AgentHealth
    let summary: String
    let counters: [String: Int]
}

protocol AgentAdapter {
    var metadata: AgentMetadata { get }
    func discover() -> AgentDiscovery
    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus
    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult
    func observe() throws -> AgentObservation
    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness
    func open(session: AgentSessionSnapshot) -> OpenResult
    func diagnostics() -> AgentDiagnostics
}

extension AgentAdapter {
    func discover() -> AgentDiscovery {
        AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        .notManaged
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        .notManaged
    }

    func observe() throws -> AgentObservation {
        AgentObservation(events: [], snapshots: [])
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        snapshot.freshness
    }

    func open(session: AgentSessionSnapshot) -> OpenResult {
        .unavailable
    }

    func diagnostics() -> AgentDiagnostics {
        AgentDiagnostics(
            health: .unknown,
            summary: "尚未检查",
            counters: [:]
        )
    }
}

struct DescriptorAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
}

func builtInAgentAdapters() -> [any AgentAdapter] {
    builtInAgentMetadata().map(DescriptorAgentAdapter.init(metadata:))
}

func builtInAgentMetadata() -> [AgentMetadata] {
    [
        AgentMetadata(
            id: .codex,
            displayName: "Codex",
            shortName: "Codex",
            iconResourceName: "ProviderIcon-codex",
            fallbackSymbolName: "sparkles",
            brandColor: AgentColorComponents(red: 0.06, green: 0.64, blue: 0.50),
            versionSource: "codex --version",
            identityPolicy: "native thread ID",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .stableIdentity,
                    .exactReturn,
                    .nativeNavigation,
                    .quota,
                ]
            )
        ),
        AgentMetadata(
            id: .claudeCode,
            displayName: "Claude Code",
            shortName: "Claude",
            iconResourceName: "ProviderIcon-claude",
            fallbackSymbolName: "terminal",
            brandColor: AgentColorComponents(red: 0.85, green: 0.47, blue: 0.34),
            versionSource: "claude --version",
            identityPolicy: "session ID plus verified live process",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .stableIdentity,
                    .exactReturn,
                    .nativeNavigation,
                    .inAppPermission,
                    .inAppQuestion,
                    .inAppPlanApproval,
                    .quota,
                    .managedIntegration,
                ]
            )
        ),
        AgentMetadata(
            id: .cursor,
            displayName: "Cursor",
            shortName: "Cursor",
            iconResourceName: "ProviderIcon-cursor",
            fallbackSymbolName: "cursorarrow.rays",
            brandColor: AgentColorComponents(red: 0.48, green: 0.72, blue: 1.00),
            versionSource: "Cursor.app and cursor agent --version",
            identityPolicy: "candidate session ID; exact return unverified",
            capabilities: AgentCapabilitySet(
                supported: [
                    .lifecycleObservation,
                    .nativeNavigation,
                    .subagentEvents,
                ],
                unknown: [.stableIdentity, .exactReturn, .managedIntegration]
            )
        ),
        AgentMetadata(
            id: .zcode,
            displayName: "ZCode",
            shortName: "ZCode",
            iconResourceName: "ProviderIcon-zcode",
            fallbackSymbolName: "terminal.fill",
            brandColor: AgentColorComponents(red: 0.64, green: 0.45, blue: 0.96),
            versionSource: "ZCode.app version metadata",
            identityPolicy: "exact session and hot reload unverified",
            capabilities: AgentCapabilitySet(
                supported: [.lifecycleObservation, .nativeNavigation],
                unknown: [
                    .stableIdentity,
                    .exactReturn,
                    .managedIntegration,
                ]
            )
        ),
        AgentMetadata(
            id: .pi,
            displayName: "Pi",
            shortName: "Pi",
            iconResourceName: "ProviderIcon-pi",
            fallbackSymbolName: "waveform.path.ecg",
            brandColor: AgentColorComponents(red: 0.96, green: 0.67, blue: 0.22),
            versionSource: "pi --version",
            identityPolicy: "state-only; native session return unverified",
            capabilities: AgentCapabilitySet(
                supported: [.lifecycleObservation],
                unknown: [.stableIdentity, .exactReturn, .managedIntegration]
            )
        ),
    ]
}
