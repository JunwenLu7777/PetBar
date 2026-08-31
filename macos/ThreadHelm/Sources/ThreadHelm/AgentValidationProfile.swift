//
//  AgentValidationProfile.swift
//  ThreadHelm
//
//  模块职责：描述六个固定版本的本机真值档案，并在版本缺失或漂移时
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
            testedVersion: "Desktop 3.17.21 · Agent CLI 2026.04.14-ee4b43a",
            testedVersionComponents: [
                AgentVersionComponent(
                    key: "desktop",
                    label: "Desktop",
                    value: "3.17.21"
                ),
                AgentVersionComponent(
                    key: "agentCLI",
                    label: "Agent CLI",
                    value: "2026.04.14-ee4b43a"
                ),
            ],
            supportedCapabilitiesSummary:
                "支持：状态、权限确认、原生应用/项目打开、子 Agent 事件、受管集成",
            knownLimitation:
                "限制：精确会话返回未验证；Cursor 没有 PermissionRequest 事件，闸门走 preToolUse，只拦 Shell 与 Write，只读工具直接放行以免确认框沦为噪音；hook 失败默认放行，已在配置里开启 failClosed 由 Cursor 判 deny；Cursor 真机发起的审批尚未端到端验证，契约取自其 hooks 模块实现"
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
            testedVersion: "17.3.5",
            supportedCapabilitiesSummary:
                "支持：状态、权限确认、原生会话跳转、受管集成",
            knownLimitation:
                "限制：跳转通过 resume 发起，精确落点未独立确认；handler 超时默认 30 秒且按墙钟计，安装时会抬到 600 秒并在卸载时还原；扩展加载失败时闸门不存在而 OMP 只打一行告警；OMP 真机发起的审批尚未在本机端到端验证，契约取自其 settings schema 与 emitToolCall 实现"
        ),
        AgentValidationProfile(
            agentID: .antigravity,
            testedVersion: "1.1.22",
            supportedCapabilitiesSummary:
                "支持：状态、权限确认、原生会话恢复、额度、受管集成",
            knownLimitation:
                "限制：--conversation 恢复的是新终端会话，回到用户原终端窗口未验证；agy 只有 PreToolUse/PostToolUse/PreInvocation/PostInvocation/Stop 五个 hook 事件，没有问题回答与计划审批入口；hook 同步阻塞 agent 循环且默认超时 30 秒；PostToolUse 实测带完整 toolCall，与官方文档只列 stepIdx/error 不符，解析按实测负载兜底；只注册用户级 hooks.json，项目级 .agents/hooks.json 受工作区信任门控"
        ),
    ]
    return Dictionary(uniqueKeysWithValues: profiles.map {
        ($0.agentID, $0)
    })
}
