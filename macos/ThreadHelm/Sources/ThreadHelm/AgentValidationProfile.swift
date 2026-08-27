//
//  AgentValidationProfile.swift
//  ThreadHelm
//
//  模块职责：描述五个固定版本的本机真值档案，并在版本缺失或漂移时
//  将尚未重新验证的能力降级为 unknown。
//

import Foundation

struct AgentValidationProfile: Equatable {
    let agentID: AgentID
    let testedVersion: String
    let testedVersionComponents: [AgentVersionComponent]
    let supportedCapabilitiesSummary: String
    let knownLimitation: String

    init(
        agentID: AgentID,
        testedVersion: String,
        testedVersionComponents: [AgentVersionComponent]? = nil,
        supportedCapabilitiesSummary: String,
        knownLimitation: String
    ) {
        self.agentID = agentID
        self.testedVersion = testedVersion
        self.testedVersionComponents = testedVersionComponents ?? [
            AgentVersionComponent(
                key: "version",
                label: "Version",
                value: testedVersion
            ),
        ]
        self.supportedCapabilitiesSummary = supportedCapabilitiesSummary
        self.knownLimitation = knownLimitation
    }

    func effectiveCapabilities(
        metadata: AgentMetadata,
        discovery: AgentDiscovery
    ) -> AgentCapabilitySet {
        guard metadata.id == agentID,
              discovery.compatibility == .validated
        else {
            return AgentCapabilitySet(
                unknown: Set(AgentCapability.allCases.filter {
                    metadata.capabilities.status(for: $0) != .unsupported
                })
            )
        }
        return metadata.capabilities
    }
}

func validationBoundedAgentMetadata(
    _ metadata: AgentMetadata,
    discovery: AgentDiscovery,
    profiles: [AgentID: AgentValidationProfile] = builtInAgentValidationProfiles()
) -> AgentMetadata {
    guard let profile = profiles[metadata.id] else { return metadata }
    return AgentMetadata(
        id: metadata.id,
        displayName: metadata.displayName,
        shortName: metadata.shortName,
        iconResourceName: metadata.iconResourceName,
        fallbackSymbolName: metadata.fallbackSymbolName,
        brandColor: metadata.brandColor,
        versionSource: metadata.versionSource,
        identityPolicy: metadata.identityPolicy,
        capabilities: profile.effectiveCapabilities(
            metadata: metadata,
            discovery: discovery
        )
    )
}

func builtInAgentValidationProfiles() -> [AgentID: AgentValidationProfile] {
    let profiles = [
        AgentValidationProfile(
            agentID: .codex,
            testedVersion: "0.150.1",
            supportedCapabilitiesSummary:
                "支持：状态、权限确认、原生线程打开、额度、受管集成",
            knownLimitation:
                "限制：精确返回未独立确认；权限闸门需在 Codex 中信任一次 hooks.json 才生效，未信任时 hook 静默不加载；Codex 不支持问题回答与计划审批 hook"
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
            testedVersion: "Desktop 3.15.19 · Agent CLI 2026.04.15-dccdccd",
            testedVersionComponents: [
                AgentVersionComponent(
                    key: "desktop",
                    label: "Desktop",
                    value: "3.15.19"
                ),
                AgentVersionComponent(
                    key: "agentCLI",
                    label: "Agent CLI",
                    value: "2026.04.15-dccdccd"
                ),
            ],
            supportedCapabilitiesSummary:
                "支持：状态、原生应用/项目打开、子 Agent 事件",
            knownLimitation:
                "限制：精确会话返回未验证；preToolUse 可返回 deny，但 ThreadHelm 尚未接入且无运行时实证"
        ),
        AgentValidationProfile(
            agentID: .zcode,
            testedVersion: "3.9.1 · build 3.9.1.5853",
            testedVersionComponents: [
                AgentVersionComponent(
                    key: "version",
                    label: "Version",
                    value: "3.9.1"
                ),
                AgentVersionComponent(
                    key: "build",
                    label: "build",
                    value: "3.9.1.5853"
                ),
            ],
            supportedCapabilitiesSummary:
                "支持：状态、权限确认、原生应用/项目打开、受管集成",
            knownLimitation:
                "限制：精确会话与 SessionEnd 未验证；yolo 模式不请求批准，闸门不会触发；ZCode 真机发起的审批尚未在本机端到端验证，契约取自应用内 schema 与负载构造代码；hook 失败在 ZCode 一侧一律放行，闸门够不着时由 ThreadHelm 主动拒绝兜底；仅注册用户级 hook，项目级受工作区信任门控"
        ),
        AgentValidationProfile(
            agentID: .omp,
            testedVersion: "17.3.2",
            supportedCapabilitiesSummary: "支持：状态、原生会话跳转",
            knownLimitation:
                "限制：跳转通过 resume 发起，精确落点未独立确认；tool_call 可阻断且为 fail-closed，ThreadHelm 的 handler 目前只观测"
        ),
    ]
    return Dictionary(uniqueKeysWithValues: profiles.map {
        ($0.agentID, $0)
    })
}
