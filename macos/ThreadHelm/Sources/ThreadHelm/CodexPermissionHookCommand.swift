//
//  CodexPermissionHookCommand.swift
//  ThreadHelm
//
//  模块职责：Codex 只支持 command 类型的 hook，拿不到 Claude 那种直连
//  HTTP 的能力。ThreadHelm 二进制带 --codex-permission-hook 旗标运行时
//  就充当这段转发：读 stdin 的 PermissionRequest，POST 给常驻面板，
//  阻塞等用户裁决，再把裁决原样写回 stdout。
//
//  失败一律回落到「不给裁决」。对 Codex 而言这不是放行——它会转回自己
//  的原生批准 UI 继续问用户。闸门掉线只是把提问搬回终端，不会让工具
//  绕过审批。
//

import Foundation

enum CodexPermissionHookOutcome: Equatable {
    /// 拿到裁决，原样写回 Codex。
    case decision(Data)
    /// 不给裁决，Codex 回落原生批准 UI。
    case noDecision
}

@discardableResult
func runCodexPermissionHookCommandIfRequested(
    arguments: [String] = CommandLine.arguments,
    readInput: () -> Data? = { readCodexPermissionHookInput() },
    postDecision: (Data, String?) -> CodexPermissionHookOutcome = {
        postCodexPermissionRequest(body: $0, token: $1)
    },
    resolveToken: () -> String? = { CodexHookConfiguration.authenticationToken() },
    writeOutput: (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }
) -> Bool {
    guard arguments.contains(CodexHookConstants.hookCommandFlag) else {
        return false
    }

    guard let body = readInput(), !body.isEmpty else {
        writeOutput(CodexHookConstants.noDecisionOutput)
        return true
    }

    switch postDecision(body, resolveToken()) {
    case .decision(let data):
        let text = String(data: data, encoding: .utf8)
            ?? CodexHookConstants.noDecisionOutput
        writeOutput(text.isEmpty ? CodexHookConstants.noDecisionOutput : text)
    case .noDecision:
        writeOutput(CodexHookConstants.noDecisionOutput)
    }
    return true
}

/// 一直读到 EOF。Codex 写完 payload 就关 stdin，所以这里不需要另设
/// 读超时——真正的等待发生在 HTTP 那一段，由服务端的过期时钟兜底。
func readCodexPermissionHookInput(
    fileHandle: FileHandle = .standardInput,
    limit: Int = CodexHookConstants.maximumInputBytes
) -> Data? {
    var data = Data()
    while true {
        let chunk = fileHandle.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
        // 超限直接放弃：截断后的 JSON 只会在服务端解析失败，
        // 与其发一份坏 payload，不如让 Codex 回落原生 UI。
        if data.count > limit { return nil }
    }
    return data.isEmpty ? nil : data
}

func postCodexPermissionRequest(
    body: Data,
    token: String?,
    url: URL? = URL(string: CodexHookConstants.url),
    timeout: TimeInterval = CodexHookConstants.requestTimeoutSeconds
) -> CodexPermissionHookOutcome {
    guard let url, let token, !token.isEmpty else { return .noDecision }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
        token,
        forHTTPHeaderField: ClaudeHookConstants.authenticationHeader
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }

    var outcome = CodexPermissionHookOutcome.noDecision
    let semaphore = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
        defer { semaphore.signal() }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data,
              !data.isEmpty
        else { return }
        outcome = .decision(data)
    }
    task.resume()
    // 比 URLSession 自身的超时多留一点余量，避免两个时钟同时到点时
    // 信号量先醒、回调后写 outcome 造成竞态。
    if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
        task.cancel()
        return .noDecision
    }
    return outcome
}
