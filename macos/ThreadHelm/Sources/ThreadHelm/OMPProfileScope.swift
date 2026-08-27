//
//  OMPProfileScope.swift
//  ThreadHelm
//
//  模块职责：枚举 OMP 的 agent 目录。`--profile` 会把整套配置搬到另一个
//  目录，所以受管集成的目标是一组目录，不是一个。
//

import Foundation

/// 一个 OMP agent 目录，也就是一套独立的闸门。
struct OMPAgentTarget: Equatable {
    /// nil 表示默认会话（没有 `--profile`）。
    let profile: String?
    /// 相对 scope 根的 agent 目录，例如 `.omp/agent`。
    let agentRelativePath: String

    var extensionRelativePath: String {
        "\(agentRelativePath)/\(OMPProfileScope.extensionDirectoryName)"
    }
}

/// OMP 的 agent 目录随 `--profile` 走。
///
/// 扩展、config.yml、令牌、我们自己的还原记录全都挂在这个目录下，因此每个
/// profile 都是一套完全独立的闸门：装了默认那一套，不代表 `--profile` 的
/// 会话有闸门，也不代表它的 handler 超时被抬高过。而且两边都不会报错——
/// OMP 只是在另一个目录里找扩展，没找到就当没有。
///
/// 契约取自 omp 17.3.5 自身实现：
/// `agentDir = configRoot + "/agent"`，
/// `configRoot = profile ? ~/.omp/profiles/<name> : ~/.omp`，
/// 用户级扩展目录 = `agentDir + "/extensions"`，
/// 主配置 = `agentDir + "/config.yml"`。
/// profile 名取自 `OMP_PROFILE` / `PI_PROFILE`（`--profile` 就是设它们），
/// 且经过 `^[a-z0-9][a-z0-9._-]{0,63}$` 校验，`default` 等同于不带 profile。
///
/// 实测确认过不继承：默认目录的 `extensionHandlers.toolCallTimeoutMs` 是
/// 我们抬到的 600000，同一台机器上新建 profile 读回来是出厂的 30000。
enum OMPProfileScope {
    static let defaultAgentRelativePath = ".omp/agent"
    static let profilesRelativePath = ".omp/profiles"
    static let extensionDirectoryName = "extensions/threadhelm-state-observer"

    static let defaultTarget = OMPAgentTarget(
        profile: nil,
        agentRelativePath: defaultAgentRelativePath
    )

    /// 默认目录，加上所有**已经存在**的 profile 目录。
    ///
    /// 只枚举真实存在的：profile 目录由 OMP 惰性创建，还没建出来的 profile
    /// 没有会话可保护，替它建目录反而是往用户家目录里塞垃圾。代价是新 profile
    /// 建立之后要等下一次状态巡检才会被发现——那时状态会诚实地掉成
    /// needsRepair，而不是继续假装装好了。
    static func agentTargets(
        in scope: AgentIntegrationScope,
        fileManager: FileManager = .default
    ) -> [OMPAgentTarget] {
        [defaultTarget] + profileNames(in: scope, fileManager: fileManager).map {
            OMPAgentTarget(
                profile: $0,
                agentRelativePath: "\(profilesRelativePath)/\($0)/agent"
            )
        }
    }

    static func profileNames(
        in scope: AgentIntegrationScope,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let root = try? scope.managedURL(
            relativePath: profilesRelativePath,
            for: .read
        ) else { return [] }
        // 目录枚举器不跟随符号链接根，不解析就会把被搬走的 profiles 目录
        // 当成空目录。
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry -> String? in
            let name = entry.lastPathComponent
            guard isValidProfileName(name) else { return nil }
            // isDirectoryKey 会解析符号链接，指向目录的链接照样算 profile：
            // OMP 那边也只是当普通路径去 join。
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            else { return nil }
            return name
        }.sorted()
    }

    /// 与 OMP 自己的 profile 名校验保持一致。不合法的名字它会直接抛错，
    /// 那种目录不可能有会话，替它装闸门只是白写文件。
    static func isValidProfileName(_ name: String) -> Bool {
        // `default` 在 OMP 里等同于「不带 profile」，会落到默认目录；
        // 当成独立 profile 处理会把默认那套重复装一遍。
        guard name != "default" else { return false }
        guard (1...64).contains(name.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard name.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = name.first,
              first.isLetter || first.isNumber
        else { return false }
        return true
    }
}

/// 把每个目标的状态并成一个。
///
/// 混合状态必须报 needsRepair 而不是 installed：默认目录装好、某个 profile
/// 没装，正是这次要修的那个静默失效，报 installed 等于把它藏回去。
func ompAggregatedIntegrationStatus(
    _ statuses: [AgentIntegrationStatus]
) -> AgentIntegrationStatus {
    guard let first = statuses.first else { return .notInstalled }
    if statuses.contains(.checkFailed) { return .checkFailed }
    guard statuses.allSatisfy({ $0 == first }) else { return .needsRepair }
    return first
}
