//
//  AntigravityPermissionSelfTest.swift
//  ThreadHelm
//
//  模块职责：锁住 Antigravity 审批闸门的契约。三条与别家不同的守则：
//  只读白名单必须用实测的真实工具名（list_dir，不是文档里的
//  list_directory）；共享 hooks.json 会被 IDE 与 Antigravity 2.0 拉起，
//  非 CLI 会话要交回产品自己的权限流程；会话带
//  --dangerously-skip-permissions 时闸门整体放行——agy 自己都不问的
//  会话，我们不该逐条弹窗。
//

import Darwin
import Foundation

func runAntigravityPermissionSelfTest() -> Never {
    func fail(_ message: String) -> Never {
        fputs(
            "antigravity-permission-self-test failed: \(message)\n",
            stderr
        )
        exit(1)
    }

    // MARK: 负载解析

    // 字段形状取自 1.1.22 的实测 PreToolUse 负载。
    func payload(
        toolName: String,
        transcriptPath: String = "/Users/u/.gemini/antigravity-cli/brain/2169d707/.system_generated/logs/transcript_full.jsonl"
    ) -> Data {
        Data("""
        {
          "conversationId": "2169d707-bc08-4cb4-a3dc-01123ed84e30",
          "modelName": "gemini-3.7-flash-high",
          "stepIdx": 2,
          "transcriptPath": "\(transcriptPath)",
          "workspacePaths": [],
          "toolCall": {
            "name": "\(toolName)",
            "args": {
              "toolSummary": "List directory contents"
            }
          }
        }
        """.utf8)
    }

    guard let prompt = try? AntigravityPermissionProtocol.decodePrompt(
        from: payload(toolName: "run_command")
    ),
        prompt.toolName == "run_command",
        prompt.agentID == .antigravity,
        prompt.sessionID == "2169d707-bc08-4cb4-a3dc-01123ed84e30"
    else {
        fail("PreToolUse 负载解析")
    }

    // MARK: 只读白名单

    // list_dir 是实测的真实工具名；文档名 list_directory 也保留。
    guard !antigravityToolNameIsGuarded(in: payload(toolName: "list_dir")),
          !antigravityToolNameIsGuarded(
              in: payload(toolName: "list_directory")
          ),
          antigravityToolNameIsGuarded(in: payload(toolName: "run_command")),
          antigravityToolNameIsGuarded(in: payload(toolName: "write_to_file"))
    else {
        fail("只读白名单判定")
    }
    // 读不懂的负载一律按需要把关处理。
    guard antigravityToolNameIsGuarded(in: Data("not json".utf8)),
          antigravityToolNameIsGuarded(in: Data("{}".utf8))
    else {
        fail("坏负载必须按需要把关处理")
    }

    // MARK: 产品来源过滤

    guard antigravityHookBodyIsCLISession(payload(toolName: "run_command")),
          !antigravityHookBodyIsCLISession(payload(
              toolName: "run_command",
              transcriptPath:
                  "/w/.gemini/antigravity-ide/brain/x/transcript.jsonl"
          )),
          !antigravityHookBodyIsCLISession(payload(
              toolName: "run_command",
              transcriptPath: "/w/.gemini/antigravity/brain/x/transcript.jsonl"
          )),
          // 缺 transcriptPath 或读不懂时按 CLI 宽容处理。
          antigravityHookBodyIsCLISession(Data("{}".utf8)),
          antigravityHookBodyIsCLISession(Data("not json".utf8))
    else {
        fail("transcriptPath 产品过滤")
    }

    // MARK: shortCircuit 组合

    let passThrough = AntigravityPermissionHookConstants.passThroughOutput
    let handBack = AntigravityPermissionHookConstants.handBackOutput
    let yolo = AgentPermissionHookTransport.antigravity(
        invokerSkipsPermissions: { true }
    )
    let gated = AgentPermissionHookTransport.antigravity(
        invokerSkipsPermissions: { false }
    )

    guard yolo.shortCircuit(payload(toolName: "run_command")) == passThrough,
          yolo.shortCircuit(payload(toolName: "list_dir")) == passThrough,
          gated.shortCircuit(payload(toolName: "run_command")) == nil,
          gated.shortCircuit(payload(toolName: "list_dir")) == passThrough
    else {
        fail("YOLO 与普通会话的 shortCircuit 组合")
    }
    let ideBody = payload(
        toolName: "run_command",
        transcriptPath: "/w/.gemini/antigravity-ide/brain/x/transcript.jsonl"
    )
    guard yolo.shortCircuit(ideBody) == handBack,
          gated.shortCircuit(ideBody) == handBack
    else {
        fail("非 CLI 会话必须交回产品自己的权限流程")
    }

    // MARK: 进程链读取

    // 用自身进程验证 KERN_PROCARGS2 解析：argv 必须与 CommandLine 一致。
    guard let ownArguments = processCommandLineArguments(of: getpid()),
          ownArguments == CommandLine.arguments
    else {
        fail("KERN_PROCARGS2 argv 解析")
    }
    guard processParentPID(of: getpid()) == getppid() else {
        fail("父进程 PID 读取")
    }
    // 自检进程的父链上没有 agy，必须判为「没跳过」；链头非法同理。
    guard !antigravityInvokerSkipsPermissions(startingFrom: getpid()),
          !antigravityInvokerSkipsPermissions(startingFrom: 0),
          !antigravityInvokerSkipsPermissions(startingFrom: -1)
    else {
        fail("无 agy 祖先时必须按普通会话处理")
    }

    print(
        "antigravity-permission-self-test: payload=decode+camelCase "
            + "whitelist=list_dir-real-name+malformed-guarded "
            + "product-filter=cli+ide+2.0+lenient "
            + "short-circuit=yolo-allow+gated-forward+non-cli-handback "
            + "process-chain=argv+ppid+no-agy-ancestor"
    )
    exit(0)
}
