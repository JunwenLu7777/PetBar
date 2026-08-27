//
//  OMPPermissionHook.swift
//  ThreadHelm
//
//  模块职责：把 OMP 的 tool_call 扩展事件接到 ThreadHelm 的审批闸门。
//
//  OMP 的失败语义与另外两家都不同，而且是三家里最安全的一种：handler
//  超时或抛异常时，**OMP 框架自己**回落成 `{block:true, reason}`，工具
//  被拦。这不是我们实现的，是 emitToolCall 里内建的兜底。
//
//  代价是那个兜底只在 handler 真的失败时生效。现有的观测扩展用
//  `catch (_) {}` 吞掉一切异常再返回 undefined——那等于放行。所以闸门
//  handler 绝不能 catch-all 后静默返回，必须显式返回 block。
//
//  另一个约束是超时：extensionHandlers.toolCallTimeoutMs 默认 30000ms，
//  按墙钟计时，等 fetch 也算 active work（只有 OMP 自有对话框不计）。
//  三十秒的人在回路窗口等于要求用户守在屏幕前，所以安装时会把它抬到
//  与另外两家一致的量级，并在卸载时改回原值。
//
//  基线：omp 17.3.5，契约取自其内置 settings schema 与 emitToolCall 实现。
//

import Foundation

enum OMPPermissionHookConstants {
    /// 与另外三家共用监听端口，靠路径区分来源。
    static let path = "/threadhelm/omp/permission"
    static let url = "http://\(ClaudeHookConstants.host):\(ClaudeHookConstants.port)\(path)"
    static let tokenFileName = ".threadhelm-permission-token"
    static let settingsKey = "extensionHandlers.toolCallTimeoutMs"

    /// 抬给 OMP 的 handler 超时。与 Claude/Codex 的 600 秒量级对齐。
    static let desiredToolCallTimeoutMilliseconds = 600_000
    /// 低于这个值就认为窗口短到不足以让人做决定，安装时才去改设置。
    /// 用户若已经把它调得更大，尊重用户，不动。
    static let minimumAcceptableTimeoutMilliseconds = 300_000
    /// 扩展自己的等待上限，比抬高后的 OMP 上限早收手：由我们返回一份
    /// 说得清的拒绝，好过让 OMP 打出 "Extension ... timed out"。
    static let extensionDeadlineMilliseconds = 570_000
}

/// OMP 的配置目录。与受管集成写入的位置保持一致——那条路径由
/// AgentIntegrationScope 决定，固定挂在 home 下。
func ompAgentDirectoryURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent(".omp", isDirectory: true)
        .appendingPathComponent("agent", isDirectory: true)
}

enum OMPPermissionTokenStore {
    static func tokenURL(
        directory: URL = ompAgentDirectoryURL()
    ) -> URL {
        directory.appendingPathComponent(
            OMPPermissionHookConstants.tokenFileName
        )
    }

    /// 只接受 owner-only 的普通文件。放宽这条等于让任何本机进程都能改
    /// 令牌，从而向闸门伪造裁决请求。
    static func token(
        directory: URL = ompAgentDirectoryURL()
    ) -> String? {
        let url = tokenURL(directory: directory)
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0,
              statBuffer.st_uid == geteuid(),
              (statBuffer.st_mode & S_IFMT) == S_IFREG,
              (statBuffer.st_mode & S_IRWXG) == 0,
              (statBuffer.st_mode & S_IRWXO) == 0,
              let data = try? Data(contentsOf: url),
              data.count <= 512,
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    @discardableResult
    static func ensureToken(
        directory: URL = ompAgentDirectoryURL()
    ) throws -> String {
        if let existing = token(directory: directory) { return existing }
        let fresh = AgentPermissionTokenFactory.make()
        let url = tokenURL(directory: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(fresh.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw OMPPermissionSettingsError.writeFailed(
                "无法收紧令牌文件权限"
            )
        }
        return fresh
    }

    static func removeToken(directory: URL = ompAgentDirectoryURL()) {
        try? FileManager.default.removeItem(at: tokenURL(directory: directory))
    }
}

enum OMPPermissionSettingsError: Error, Equatable {
    case writeFailed(String)
}

extension OMPPermissionSettingsError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "写入 OMP 闸门配置失败：\(reason)"
        }
    }
}

/// 决定要不要动用户的 handler 超时设置，以及卸载时还原成什么。
///
/// 通过 `omp config set` 改而不是直接写 config.yml：那是 YAML，OMP 自己
/// 带 schema 与写锁；手写 YAML 既要处理注释与锚点，又要跟它的锁抢。
/// 代价是 `omp config set` 会按 schema 重写整份配置，静默丢弃它当前版本
/// 不认的值——所以 config.yml 被列进受管路径，安装前会先备份。
enum OMPToolCallTimeoutPlan: Equatable {
    /// 现值已经够长，不动用户配置。
    case leaveAsIs(current: Int)
    /// 需要抬高；记下原值以便卸载时还原。
    case raise(from: Int?, to: Int)
}

func ompToolCallTimeoutPlan(
    currentValue: Int?,
    desired: Int = OMPPermissionHookConstants.desiredToolCallTimeoutMilliseconds,
    minimumAcceptable: Int = OMPPermissionHookConstants
        .minimumAcceptableTimeoutMilliseconds
) -> OMPToolCallTimeoutPlan {
    if let currentValue, currentValue >= minimumAcceptable {
        return .leaveAsIs(current: currentValue)
    }
    return .raise(from: currentValue, to: desired)
}

/// 安装时记下被我们改过的原值，卸载时据此还原。放在 OMP 目录下、
/// owner-only，与令牌同级。
enum OMPManagedSettingsRecord {
    static let filename = ".threadhelm-managed-settings.json"

    static func url(directory: URL = ompAgentDirectoryURL()) -> URL {
        directory.appendingPathComponent(filename)
    }

    static func previousTimeout(
        directory: URL = ompAgentDirectoryURL()
    ) -> Int?? {
        let fileURL = url(directory: directory)
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 8 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              payload["managedToolCallTimeout"] as? Bool == true
        else { return nil }
        // 双层 Optional：外层 nil 表示「我们没改过」，内层 nil 表示
        // 「改之前用户根本没设过这个键」——那两种情况的还原动作不同。
        if let previous = payload["previousToolCallTimeoutMs"] as? Int {
            return .some(.some(previous))
        }
        return .some(.none)
    }

    static func write(
        previousTimeout: Int?,
        directory: URL = ompAgentDirectoryURL()
    ) throws {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "managedToolCallTimeout": true,
        ]
        if let previousTimeout {
            payload["previousToolCallTimeoutMs"] = previousTimeout
        }
        let fileURL = url(directory: directory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
            guard chmod(fileURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw OMPPermissionSettingsError.writeFailed("无法收紧记录文件权限")
            }
        } catch let error as OMPPermissionSettingsError {
            throw error
        } catch {
            throw OMPPermissionSettingsError.writeFailed(
                error.localizedDescription
            )
        }
    }

    static func remove(directory: URL = ompAgentDirectoryURL()) {
        try? FileManager.default.removeItem(at: url(directory: directory))
    }
}

/// 把用户裁决翻成 OMP 的 tool_call 返回值。
///
/// `{block:true, reason}` 拦截并把 reason 逐字交给模型；返回空表示放行。
/// OMP 不接受「改写入参」或「长期授权」这类回执，所以那两类裁决只能
/// 落到最接近的语义上。
enum OMPPermissionProtocol {
    static func responseBody(
        for decision: ClaudePermissionUserDecision
    ) -> Data? {
        let payload: [String: Any]
        switch decision {
        case .allowOnce, .allowWithSuggestion:
            // OMP 没有长期授权回执，建议只能落成「这次放行」。
            payload = ["block": false]
        case .deny(let message):
            payload = [
                "block": true,
                "reason": boundedReason(
                    message,
                    fallback: "用户拒绝了这次操作"
                ),
            ]
        case .planFeedback(let feedback):
            payload = [
                "block": true,
                "reason": boundedReason(
                    feedback,
                    fallback: "请修改计划后再次确认"
                ),
            ]
        case .submitAnswers:
            // OMP 不接受改写后的入参，发过去也只会被忽略。当作放行更诚实。
            payload = ["block": false]
        case .nativeFallback:
            // OMP 没有可回落的原生批准界面。交还等于放行，而用户此刻
            // 恰恰是选择了「不在这里决定」——只能拦下来让他回 OMP 处理。
            payload = [
                "block": true,
                "reason": "用户选择回到 OMP 处理这次操作。",
            ]
        }
        return try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }

    private static func boundedReason(
        _ value: String,
        fallback: String
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(2_000))
    }
}

/// 受管的 OMP agent 目录。走 scope 而不是直接拼 home，隔离自测才能把
/// 写入关在临时目录里。
func ompManagedAgentDirectory(
    in scope: AgentIntegrationScope
) throws -> URL {
    try scope.managedURL(relativePath: ".omp/agent")
}

/// 读写 handler 超时都经 `omp config`，不直接改 config.yml。
///
/// 那是 YAML，OMP 自带 schema 校验和一个写锁（config.yml.lock）。手写
/// YAML 既要处理注释、锚点与流式/块式差异，又要跟它的锁抢——让 OMP 改
/// 自己的配置更稳妥。实测在真实配置上只会把流式序列展开成块式，语义无损。
enum OMPConfigCommand {
    static func read(
        key: String = OMPPermissionHookConstants.settingsKey,
        run: (URL, [String]) -> (status: Int32, output: String)? = runOMPProcess
    ) -> Int? {
        guard let executable = locateOMPExecutable(),
              let result = run(executable, ["config", "get", key]),
              result.status == 0
        else { return nil }
        return parseTimeoutOutput(result.output)
    }

    @discardableResult
    static func write(
        _ value: Int,
        key: String = OMPPermissionHookConstants.settingsKey,
        run: (URL, [String]) -> (status: Int32, output: String)? = runOMPProcess
    ) -> Bool {
        guard let executable = locateOMPExecutable(),
              let result = run(executable, ["config", "set", key, "\(value)"])
        else { return false }
        return result.status == 0
    }

    @discardableResult
    static func reset(
        key: String = OMPPermissionHookConstants.settingsKey,
        run: (URL, [String]) -> (status: Int32, output: String)? = runOMPProcess
    ) -> Bool {
        guard let executable = locateOMPExecutable(),
              let result = run(executable, ["config", "reset", key])
        else { return false }
        return result.status == 0
    }

    /// 输出带 ANSI 颜色码，而颜色码本身含数字（`ESC[36m` 里的 36）。
    /// 必须先剥转义序列再取数字，否则读到的是颜色编号。
    static func parseTimeoutOutput(_ output: String) -> Int? {
        var plain = ""
        var index = output.startIndex
        while index < output.endIndex {
            let character = output[index]
            guard character == "\u{1B}" else {
                plain.append(character)
                index = output.index(after: index)
                continue
            }
            // CSI 序列：ESC [ 参数… 终止字母。跳到终止字母之后。
            var cursor = output.index(after: index)
            if cursor < output.endIndex, output[cursor] == "[" {
                cursor = output.index(after: cursor)
                while cursor < output.endIndex, !output[cursor].isLetter {
                    cursor = output.index(after: cursor)
                }
            }
            index = cursor < output.endIndex
                ? output.index(after: cursor)
                : output.endIndex
        }
        var digits = ""
        for character in plain {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}

private func runOMPProcess(
    executable: URL,
    arguments: [String]
) -> (status: Int32, output: String)? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let capture = captureProcessOutput(
        process: process,
        output: pipe.fileHandleForReading,
        timeout: 10,
        maximumOutputBytes: 8 * 1_024
    )
    guard capture.termination == .exited else { return nil }
    return (
        process.terminationStatus,
        String(data: capture.data, encoding: .utf8) ?? ""
    )
}

/// handler 超时的读写口子。抽成协议是因为它的副作用**跨不出进程边界**：
/// `omp config set` 改的是用户真实配置，AgentIntegrationScope 那套隔离
/// 只管得住文件写入，管不住子进程。自测必须能换成内存实现，否则跑一次
/// 自测就会改掉本机 OMP 的设置。
protocol OMPToolCallTimeoutStore {
    func read() -> Int?
    func write(_ value: Int) -> Bool
    func reset() -> Bool
}

struct OMPConfigCommandTimeoutStore: OMPToolCallTimeoutStore {
    private let isSelfTest: Bool

    init(
        isSelfTest: Bool = CommandLine.arguments.contains {
            $0.hasPrefix("--self-test")
        }
    ) {
        self.isSelfTest = isSelfTest
    }

    func read() -> Int? { OMPConfigCommand.read() }

    // 自测里漏注入内存实现太容易了——这条路径真的发生过，一次自测就
    // 改掉了本机 OMP 的设置。护栏放在最靠近副作用的地方：自测进程一律
    // 不许写。漏注入会让断言失败，而不是悄悄改用户配置。
    func write(_ value: Int) -> Bool {
        guard !isSelfTest else { return false }
        return OMPConfigCommand.write(value)
    }

    func reset() -> Bool {
        guard !isSelfTest else { return false }
        return OMPConfigCommand.reset()
    }
}

/// 只在内存里记账的实现，供隔离自测使用。
final class InMemoryOMPToolCallTimeoutStore: OMPToolCallTimeoutStore {
    private(set) var value: Int?
    private(set) var writeCount = 0
    private(set) var resetCount = 0

    init(value: Int? = nil) {
        self.value = value
    }

    func read() -> Int? { value }

    func write(_ newValue: Int) -> Bool {
        value = newValue
        writeCount += 1
        return true
    }

    func reset() -> Bool {
        value = nil
        resetCount += 1
        return true
    }
}
