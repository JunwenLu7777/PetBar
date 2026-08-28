//
//  ZCodePermissionHook.swift
//  ThreadHelm
//
//  模块职责：把 ZCode 的 PermissionRequest hook 接到 ThreadHelm 的审批闸门。
//
//  ZCode 的 hook 负载与裁决格式与 Claude 逐字段同形——它自己就带一层
//  snake_case 兼容键（hook_event_name / tool_name / tool_input /
//  tool_use_id / transcript_path / permission_suggestions），裁决也是
//  hookSpecificOutput.decision.behavior 那一套，并且同样支持
//  updatedPermissions 与 updatedInput。所以编解码直接复用 Claude 的，
//  这里只提供常量与转发所需的差异部分；令牌读写走共用的
//  AgentPermissionTokenStore.zcode。
//
//  基线：ZCode 3.9.1 / 内置 CLI 0.16.5，契约取自应用内 zcode.cjs 的
//  运行时 schema 与 hook 负载构造代码。
//

import Foundation

enum ZCodePermissionHookConstants {
    /// 与 Claude、Codex 共用监听端口，靠路径区分来源。
    static let path = "/threadhelm/zcode/permission"
    static let url = "http://\(ClaudeHookConstants.host):\(ClaudeHookConstants.port)\(path)"
    static let flag = "--zcode-permission-hook"
    static let eventName = "PermissionRequest"
    static let statusMessage = "等待 ThreadHelm 确认…"
    static let tokenFileName = ".threadhelm-permission-token"

    /// ZCode 的 hook 超时默认 60000ms，到点后**放行**而不是拦截。人来点
    /// 按钮远不止一分钟，所以必须显式抬高；实测 240 秒不被钳制。
    /// 观测 hook 那点秒级预算在这里是灾难性的——几秒就被杀，然后
    /// fail-open。
    static let hookTimeoutMilliseconds = 600_000

    /// 比 ZCode 的上限早一点收手。让 ZCode 杀掉 hook 永远是 fail-open；
    /// 由我们自己在超时前返回拒绝，才能保住 fail-closed。
    static let selfDenyDeadlineSeconds: TimeInterval = 570
}

/// ZCode 的配置目录。与受管集成写入的位置保持一致——那条路径由
/// AgentIntegrationScope 决定，固定挂在 home 下，不看环境变量。
func zcodeConfigurationDirectoryURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent(".zcode", isDirectory: true)
        .appendingPathComponent("cli", isDirectory: true)
}
