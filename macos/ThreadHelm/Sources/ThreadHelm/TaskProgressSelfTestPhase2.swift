//
//  TaskProgressSelfTestPhase2.swift
//  ThreadHelm
//
//  模块职责：--self-test-task-progress 自测（阶段二）——非用户会话过滤、
//  任务符号、Claude 会话合并与进程身份校验、终端导航计划与入口一致性、
//  TTY 进程链解析、iTerm2/otty/Terminal 聚焦脚本与 Claude 恢复命令。
//  由 TaskProgressSelfTest.swift 的入口函数调用。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func runTaskProgressSelfTestPhase2(now: Date, started: String) {
    let preferenceSuite = "threadhelm-task-progress-phase2-\(UUID().uuidString)"
    guard let migratedDefaults = UserDefaults(suiteName: preferenceSuite) else {
        exit(1)
    }
    defer { migratedDefaults.removePersistentDomain(forName: preferenceSuite) }
    let migratedKeys = migrateLegacyThreadHelmPreferences(
        from: [
            [
                "presentation-mode": "pet-panel",
                "pet-enabled": true,
                "selected-quota-provider": QuotaProvider.claudeCode.rawValue,
                "chatbird-pet-origin": [32.0, 64.0],
                "selected-avatar-id": "custom:legacy-chatbird",
            ],
            [
                "selected-quota-provider": QuotaProvider.codex.rawValue,
            ],
        ],
        to: migratedDefaults
    )
    guard threadHelmBundleIdentifier == "dev.threadhelm.app",
          threadHelmLaunchAgentLabel == threadHelmBundleIdentifier,
          legacyThreadHelmBundleIdentifiers == [
              "dev.chatbird.app",
              "dev.chatbird.codex-quota-panel",
          ],
          migratedKeys == ["selected-quota-provider"],
          migratedDefaults.string(forKey: "selected-avatar-id") == nil,
          migratedDefaults.object(forKey: "presentation-mode") == nil,
          migratedDefaults.object(forKey: "pet-enabled") == nil,
          migratedDefaults.object(forKey: "chatbird-pet-origin") == nil,
          QuotaProviderPreference(defaults: migratedDefaults).selectedProvider == .claudeCode
    else {
        fputs("ThreadHelm preference migration scope failed\n", stderr)
        exit(1)
    }

    let topLevelMetadata = #"{"type":"session_meta","payload":{"thread_source":"user","source":{"cli":{}}}}"#
    let subagentMetadata = #"{"type":"session_meta","payload":{"thread_source":"subagent","source":{"subagent":{"thread_spawn":{}}}}}"#
    let automationMetadata = #"{"type":"session_meta","payload":{"thread_source":"automation","source":"vscode"}}"#
    let sourceOnlySubagentMetadata = #"{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{}}}}}"#
    let rolloutVisibilityCases = [
        CodexTaskProgressReader.isUserVisibleSessionMetadata(line: topLevelMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: subagentMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: automationMetadata),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(line: sourceOnlySubagentMetadata),
        CodexTaskProgressReader.isUserVisibleSessionMetadata(
            line: subagentMetadata,
            explicitlyVisible: true
        ),
        !CodexTaskProgressReader.isUserVisibleSessionMetadata(
            line: automationMetadata,
            explicitlyVisible: true
        ),
        CodexTaskProgressReader.isUserVisibleSessionMetadata(line: started),
    ]
    guard rolloutVisibilityCases.allSatisfy({ $0 }) else {
        fputs("task non-user session filtering failed\n", stderr)
        exit(1)
    }

    let pinnedID = "12345678-1234-4abc-8def-1234567890ab"
    let projectlessID = "22345678-1234-4abc-8def-1234567890ab"
    let assignedID = "32345678-1234-4abc-8def-1234567890ab"
    let stateFixture: [String: Any] = [
        "pinned-thread-ids": [pinnedID.uppercased()],
        "projectless-thread-ids": [projectlessID],
        "thread-project-assignments": [assignedID: "project"],
        "electron-persisted-atom-state": [
            "unread-thread-ids-by-host-v1": ["local": [assignedID]],
        ],
    ]
    guard let stateData = try? JSONSerialization.data(withJSONObject: stateFixture),
          let threadState = CodexTaskProgressReader.threadState(from: stateData),
          threadState.ids == [assignedID],
          threadState.explicitlyVisibleIDs == [
              pinnedID,
              projectlessID,
              assignedID,
          ]
    else {
        fputs("Codex explicit user-visible thread state parsing failed\n", stderr)
        exit(1)
    }

    let truncated = TaskProgressSnapshot.displaying((0..<7).map { index in
        TaskProgressItem(
            title: "任务 \(index + 1)",
            kind: .running,
            startedAt: now,
            updatedAt: now.addingTimeInterval(Double(index))
        )
    })
    guard truncated.isScrollable,
          truncated.items.count == 7,
          truncated.items.first?.title == "任务 7",
          truncated.items.last?.title == "任务 1"
    else {
        fputs("task list scrolling data source failed\n", stderr)
        exit(1)
    }

    let completedPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "AI 观点运营台 · Codex Chrome 单条发布与回复",
            kind: .completed,
            startedAt: now,
            statusOverride: "最新"
        ),
        TaskProgressItem(
            title: "  AI 观点运营台 · Codex Chrome 单条发布与回复  ",
            kind: .completed,
            startedAt: now.addingTimeInterval(-300),
            statusOverride: "旧记录"
        ),
        TaskProgressItem(title: "相同标题的实时任务", kind: .running, startedAt: now),
        TaskProgressItem(title: "相同标题的实时任务", kind: .running, startedAt: now),
    ])
    guard completedPresentation.items.count == 2,
          completedPresentation.items[0].kind == .running,
          completedPresentation.items[0].title == "相同标题的实时任务",
          completedPresentation.items[1].kind == .completed,
          completedPresentation.items[1].statusText == "最新"
    else {
        fputs("task presentation deduplication failed\n", stderr)
        exit(1)
    }

    let simultaneousCodexPresentation = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "相同标题的实时任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-1),
            threadID: "11111111-1111-4111-8111-111111111111"
        ),
        TaskProgressItem(
            title: "相同标题的实时任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-30),
            updatedAt: now,
            threadID: "22222222-2222-4222-8222-222222222222"
        ),
        TaskProgressItem(
            title: "相同标题的实时任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-30),
            updatedAt: now,
            threadID: "22222222-2222-4222-8222-222222222222"
        ),
    ])
    guard simultaneousCodexPresentation.items.count == 2,
          simultaneousCodexPresentation.items.map(\.threadID) == [
              "22222222-2222-4222-8222-222222222222",
              "11111111-1111-4111-8111-111111111111",
          ]
    else {
        fputs("simultaneous task identity deduplication failed\n", stderr)
        exit(1)
    }

    let taskSymbolCases: [(TaskProgressKind, String)] = [
        (.running, "arrow.triangle.2.circlepath"),
        (.waitingForInput, "questionmark.circle.fill"),
        (.completed, "checkmark.circle.fill"),
        (.failed, "exclamationmark.triangle.fill"),
        (.reading, "clock"),
        (.idle, "circle"),
    ]
    guard taskSymbolCases.allSatisfy({
        taskProgressSymbolName(for: $0.0) == $0.1
            && NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) != nil
    }) else {
        fputs("task status system symbols failed\n", stderr)
        exit(1)
    }

    let claudeSessionID = "b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6"
    let otherClaudeSessionID = "7fa9c621-795c-47e7-a570-07ee5e0b821d"
    let staleClaudeSessionID = "9fa3f2bd-788e-42e1-bcc9-d288c2e44e65"
    let tiedClaudeSessionID = "9ba02518-76d0-44e6-813c-e1330482baf7"
    let liveClaudeProcessStartIdentity = "Sun Jul 26 18:20:00 2026"
    let duplicateClaudeAgentCandidates = [
        ClaudeAgentSnapshot(
            sessionID: claudeSessionID.uppercased(),
            title: "无法精确定位的重复记录",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "已阻塞"
        ),
        ClaudeAgentSnapshot(
            sessionID: claudeSessionID,
            title: "可精确定位的实时记录",
            workingDirectory: "/tmp/shared-project",
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity,
            kind: .running,
            startedAt: now.addingTimeInterval(-30),
            statusOverride: nil
        ),
    ]
    let duplicateClaudeAgents = claudeAgentsBySessionID(
        duplicateClaudeAgentCandidates,
        isProcessAlive: { $0 == 57_704 }
    )
    let reversedDuplicateClaudeAgents = claudeAgentsBySessionID(
        Array(duplicateClaudeAgentCandidates.reversed()),
        isProcessAlive: { $0 == 57_704 }
    )
    let staleClaudeAgents = claudeAgentsBySessionID([
        ClaudeAgentSnapshot(
            sessionID: staleClaudeSessionID,
            title: "失效 PID 记录",
            workingDirectory: "/tmp/shared-project",
            processID: 42_424,
            processStartIdentity: "Sun Jul 26 17:00:00 2026",
            kind: .running,
            startedAt: now,
            statusOverride: nil
        ),
    ], isProcessAlive: { _ in false })
    let statusTiedClaudeAgentCandidates = [
        ClaudeAgentSnapshot(
            sessionID: tiedClaudeSessionID,
            title: "状态相同优先级",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "等待中"
        ),
        ClaudeAgentSnapshot(
            sessionID: tiedClaudeSessionID,
            title: "状态相同优先级",
            workingDirectory: "/tmp/shared-project",
            processID: nil,
            processStartIdentity: nil,
            kind: .waitingForInput,
            startedAt: now,
            statusOverride: "已阻塞"
        ),
    ]
    let statusTiedClaudeAgents = claudeAgentsBySessionID(
        statusTiedClaudeAgentCandidates,
        isProcessAlive: { _ in false }
    )
    let reversedStatusTiedClaudeAgents = claudeAgentsBySessionID(
        Array(statusTiedClaudeAgentCandidates.reversed()),
        isProcessAlive: { _ in false }
    )
    guard duplicateClaudeAgents == reversedDuplicateClaudeAgents,
          duplicateClaudeAgents.count == 1,
          duplicateClaudeAgents[claudeSessionID]?.processID == 57_704,
          duplicateClaudeAgents[claudeSessionID]?.title == "可精确定位的实时记录",
          staleClaudeAgents[staleClaudeSessionID]?.processID == nil,
          statusTiedClaudeAgents == reversedStatusTiedClaudeAgents
    else {
        fputs("duplicate Claude session merging failed\n", stderr)
        exit(1)
    }

    let preciseClaudeRequest = ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: 57_704,
        processStartIdentity: liveClaudeProcessStartIdentity
    )
    let unverifiedPIDRequest = ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: 57_704
    )
    guard claudeTerminalNavigationPlan(for: preciseClaudeRequest) == [
        .focusProcess(
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity
        ),
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
        .focusWorkingDirectory("/tmp/shared-project"),
    ], claudeTerminalNavigationPlan(for: unverifiedPIDRequest) == [
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
        .focusWorkingDirectory("/tmp/shared-project"),
    ], claudeTerminalNavigationPlan(for: ClaudeTerminalOpenRequest(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/shared-project",
        processID: nil
    )) == [
        .resumeSession(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project"
        ),
        .focusWorkingDirectory("/tmp/shared-project"),
    ], claudeTerminalNavigationPlan(for: ClaudeTerminalOpenRequest(
        sessionID: nil,
        workingDirectory: "/tmp/shared-project",
        processID: nil
    )) == [
        .focusWorkingDirectory("/tmp/shared-project"),
    ], allowsGenericTerminalFallback(for: preciseClaudeRequest) == false,
       allowsGenericTerminalFallback(for: ClaudeTerminalOpenRequest(
           sessionID: claudeSessionID,
           workingDirectory: nil,
           processID: nil
       )) == false,
       allowsGenericTerminalFallback(for: ClaudeTerminalOpenRequest(
           sessionID: nil,
           workingDirectory: nil,
           processID: nil
       ))
    else {
        fputs("Claude terminal navigation precedence failed\n", stderr)
        exit(1)
    }

    let permissionPrompt = ClaudePermissionPrompt(
        requestID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        interactionKind: .toolApproval,
        toolName: "Bash",
        sessionID: claudeSessionID.uppercased(),
        workingDirectory: "/tmp/shared-project",
        title: "Claude 精确导航",
        message: "允许执行测试命令吗？",
        planText: nil,
        questions: [],
        originalToolInput: [:],
        suggestions: []
    )
    let sameDirectoryTaskItems = [
        TaskProgressItem(
            title: "同目录的另一条 Claude 会话",
            kind: .running,
            startedAt: now.addingTimeInterval(-60),
            source: .claudeCode,
            sessionID: otherClaudeSessionID,
            workingDirectory: "/tmp/shared-project",
            processID: 12_345,
            processStartIdentity: "Sun Jul 26 18:19:00 2026"
        ),
        TaskProgressItem(
            title: "Claude 精确导航",
            kind: .waitingForInput,
            startedAt: now,
            source: .claudeCode,
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project",
            processID: 57_704,
            processStartIdentity: liveClaudeProcessStartIdentity
        ),
    ]
    let taskOpenRequest = claudeTerminalOpenRequest(
        for: sameDirectoryTaskItems[1]
    )
    let permissionOpenRequest = claudeTerminalOpenRequest(
        for: permissionPrompt,
        taskItems: sameDirectoryTaskItems
    )
    let taskNavigationPlan = claudeTerminalNavigationPlan(for: taskOpenRequest)
    let permissionNavigationPlan = claudeTerminalNavigationPlan(
        for: permissionOpenRequest
    )
    guard taskOpenRequest == permissionOpenRequest,
          taskOpenRequest == preciseClaudeRequest,
          taskNavigationPlan == permissionNavigationPlan,
          taskNavigationPlan.last
            == .focusWorkingDirectory("/tmp/shared-project")
    else {
        fputs("Claude navigation entry points diverged\n", stderr)
        exit(1)
    }

    let claudeLines = [
        #"{"type":"user","timestamp":"2026-07-25T10:00:00.000Z","message":{"role":"user","content":"兼容 Claude Code"}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private chain"},{"type":"text","text":"正在检查 Claude 任务"}],"stop_reason":null}}"#,
    ]
    let claudeItem = ClaudeTaskProgressReader.parseTranscript(
        lines: claudeLines,
        sessionID: claudeSessionID,
        fallbackTitle: "Claude 会话",
        workingDirectory: "/tmp/claude-project",
        processID: 57_704,
        processStartIdentity: liveClaudeProcessStartIdentity,
        activeKind: .running,
        startedAt: now.addingTimeInterval(-30),
        modificationDate: now
    )
    let sourceMerged = TaskProgressSnapshot.displaying([
        TaskProgressItem(
            title: "Codex 同名任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-40),
            updatedAt: now.addingTimeInterval(-2)
        ),
        TaskProgressItem(
            title: "Codex 同名任务",
            kind: .running,
            startedAt: now.addingTimeInterval(-20),
            updatedAt: now,
            source: .claudeCode,
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/claude-project"
        ),
    ])
    let chainedTTY = controllingTTYFromProcessChain(
        startingAt: 90,
        directTTY: { $0 == 50 ? "/dev/ttys003" : nil },
        parentPID: {
            switch $0 {
            case 90: return 70
            case 70: return 50
            default: return nil
            }
        }
    )
    let cyclicTTY = controllingTTYFromProcessChain(
        startingAt: 90,
        directTTY: { _ in nil },
        parentPID: { $0 == 90 ? 70 : 90 }
    )
    let claudeProcessChainDetected = processChainContainsClaude(
        startingAt: 90,
        commandLine: {
            $0 == 70
                ? "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
                : "/bin/zsh"
        },
        parentPID: { $0 == 90 ? 70 : nil }
    )
    let reusedUnrelatedProcessRejected = processChainContainsClaude(
        startingAt: 90,
        commandLine: { _ in "/usr/bin/python3 unrelated-worker.py" },
        parentPID: { $0 == 90 ? 70 : nil }
    ) == false
    let selfProcessID = ProcessInfo.processInfo.processIdentifier
    let iTermTTYFocus = iTerm2FocusScript(tty: "/dev/ttys003")
    let ottyTTYFocus = ottyFocusScript(tty: "/dev/ttys003")
    let compoundClaudeResumeCommand = claudeResumeCommand(
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/Claude's project",
        executablePath: "/opt/homebrew/bin/claude"
    )
    let ottyCompoundResume = compoundClaudeResumeCommand.flatMap {
        ottyResumeScript(command: $0)
    }
    let escapedCompoundClaudeResumeCommand = compoundClaudeResumeCommand.map(
        appleScriptEscapedString
    )
    let ottyQuotedResume = ottyResumeScript(command: #"printf "Claude""#)
    let liveClaudeTarget = claudeLiveProcessTarget(
        forSessionID: claudeSessionID,
        from: Data(
            #"""
            [
              {
                "sessionId":"b687a9ef-4535-4bb4-a9d5-e692bbcdb0a6",
                "cwd":"/tmp/shared-project",
                "kind":"background",
                "state":"blocked"
              },
              {
                "sessionId":"B687A9EF-4535-4BB4-A9D5-E692BBCDB0A6",
                "cwd":"/tmp/shared-project",
                "kind":"interactive",
                "pid":57704,
                "status":"idle"
              }
            ]
            """#.utf8
        ),
        processStartIdentity: {
            $0 == 57_704 ? liveClaudeProcessStartIdentity : nil
        },
        isProcessAlive: { $0 == 57_704 }
    )
    let refreshedClaudeRequest = refreshedClaudeTerminalOpenRequest(
        ClaudeTerminalOpenRequest(
            sessionID: claudeSessionID,
            workingDirectory: "/tmp/shared-project",
            processID: nil
        ),
        liveProcessTarget: liveClaudeTarget
    )
    let installedOttyResumePreference = claudeResumeTerminalPreference(
        runningBundleIdentifiers: [],
        installedBundleIdentifiers: [
            "io.appmakes.otty",
            "com.apple.Terminal",
        ]
    )
    let runningTerminalResumePreference = claudeResumeTerminalPreference(
        runningBundleIdentifiers: ["com.apple.Terminal"],
        installedBundleIdentifiers: [
            "io.appmakes.otty",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
        ]
    )
    let installedITermResumePreference = claudeResumeTerminalPreference(
        runningBundleIdentifiers: [],
        installedBundleIdentifiers: [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
        ]
    )
    let terminalTTYFocus = terminalFocusScript(tty: "/dev/ttys003")
    let completedClaudeItem = TaskProgressItem(
        title: "已完成的 Claude 会话",
        kind: .completed,
        startedAt: now.addingTimeInterval(-120),
        source: .claudeCode,
        sessionID: claudeSessionID,
        workingDirectory: "/tmp/claude-project"
    )
    guard let compoundClaudeResumeCommand,
          let ottyCompoundResume,
          let escapedCompoundClaudeResumeCommand,
          let ottyQuotedResume,
          claudeItem?.source == .claudeCode,
          claudeItem?.activityText == "正在检查 Claude 任务",
          claudeItem?.activityText?.contains("private chain") == false,
          claudeItem?.sessionID == claudeSessionID,
          claudeItem?.processID == 57_704,
          claudeItem?.processStartIdentity
            == liveClaudeProcessStartIdentity,
          claudeProcessID(
              forSessionID: claudeSessionID.uppercased(),
              in: [claudeItem].compactMap { $0 }
          ) == 57_704,
          claudeItem?.canOpen == true,
          sourceMerged.items.count == 2,
          sourceMerged.items.first?.source == .claudeCode,
          normalizedTerminalTTY("ttys003") == "/dev/ttys003",
          normalizedTerminalTTY("/dev/ttys003") == "/dev/ttys003",
          normalizedTerminalTTY("??") == nil,
          normalizedTerminalTTY("../ttys003") == nil,
          chainedTTY == "/dev/ttys003",
          cyclicTTY == nil,
          claudeProcessChainDetected,
          reusedUnrelatedProcessRejected,
          codexTaskProgressRescanInterval == 5,
          taskAnimationFramesPerSecond == 8,
          taskAnimationDegreesPerTick == 36,
          !shouldRefreshClaudeAgents(
              cachedAgentCount: 0,
              hasRecentlyModifiedTranscript: false
          ),
          shouldRefreshClaudeAgents(
              cachedAgentCount: 0,
              hasRecentlyModifiedTranscript: true
          ),
          shouldRefreshClaudeAgents(
              cachedAgentCount: 1,
              hasRecentlyModifiedTranscript: false
          ),
          claudeAgentRefreshInterval(agentCount: 0) == 15,
          claudeAgentRefreshInterval(agentCount: 1)
            == taskProgressRefreshInterval,
          isClaudeCodeCommandLine("/opt/homebrew/bin/claude") == true,
          isClaudeCodeCommandLine(
              "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
          ) == true,
          isClaudeCodeCommandLine("/bin/zsh") == false,
          currentProcessStartIdentity(forProcessID: selfProcessID) != nil,
          // isLiveClaudeProcess 沿父进程链查找 claude，所以自测进程不能当样本：
          // 自测往往就是从 Claude Code 会话里启动的，父链上必然有 claude，断言
          // 必失败。面板真实运行时由 LaunchAgent 拉起，父链是 launchd。改为按
          // 注入的进程链验证同一性质——面板自身的命令行不算 Claude 进程——
          // 并单独验证非活进程直接判否。
          isLiveClaudeProcess(1) == false,
          processChainContainsClaude(
              startingAt: 4_242,
              commandLine: { candidate in
                  candidate == 4_242
                      ? "/Applications/ChatBird 额度面板.app"
                          + "/Contents/MacOS/ChatBirdQuotaPanel"
                      : nil
              },
              parentPID: { _ in nil }
          ) == false,
          iTermTTYFocus?.contains(
              #"if (tty of aSession as text) is "/dev/ttys003" then"#
          ) == true,
          iTermTTYFocus?.contains("tell aSession to select") == true,
          iTermTTYFocus?.contains("activate") == true,
          iTerm2FocusScript(tty: "not a tty") == nil,
          ottyTTYFocus?.contains(
              #"if (tty of aTab as text) is "/dev/ttys003" then"#
          ) == true,
          ottyTTYFocus?.contains("set selected of aTab to true") == true,
          ottyTTYFocus?.contains("activate") == true,
          ottyFocusScript(tty: "not a tty") == nil,
          ottyQuotedResume.contains(
              #"set targetTab to do script "printf \"Claude\"""#
          ),
          ottyQuotedResume.contains(" in front window") == false,
          ottyQuotedResume.contains(" in targetTab") == false,
          ottyQuotedResume.contains("set targetWindow to front window"),
          ottyQuotedResume.contains("set selected of targetTab to true"),
          ottyQuotedResume.contains("set index of targetWindow to 1"),
          ottyQuotedResume.contains("activate"),
          ottyResumeScript(command: " \n") == nil,
          liveClaudeTarget == ClaudeLiveProcessTarget(
              sessionID: claudeSessionID,
              processID: 57_704,
              processStartIdentity: liveClaudeProcessStartIdentity
          ),
          claudeTerminalNavigationPlan(for: refreshedClaudeRequest).first
            == .focusProcess(
                processID: 57_704,
                processStartIdentity: liveClaudeProcessStartIdentity
            ),
          claudeTerminalFocusStrategy(
              bundleIdentifier: "dev.warp.Warp-Stable"
          ) == .activateHostApplication,
          claudeTerminalFocusStrategy(
              bundleIdentifier: "com.googlecode.iterm2"
          ) == .selectITermTTY,
          installedOttyResumePreference == [
              "io.appmakes.otty",
              "com.apple.Terminal",
          ],
          runningTerminalResumePreference == [
              "com.apple.Terminal",
              "io.appmakes.otty",
              "com.googlecode.iterm2",
          ],
          installedITermResumePreference == [
              "com.googlecode.iterm2",
              "com.apple.Terminal",
          ],
          ottyCompoundResume.contains(
              "set targetTab to do script \"\(escapedCompoundClaudeResumeCommand)\""
          ),
          terminalTTYFocus?.contains(
              #"if (tty of aTab as text) is "/dev/ttys003" then"#
          ) == true,
          terminalTTYFocus?.contains(
              #"set selected tab of aWindow to aTab"#
          ) == true,
          terminalTTYFocus?.contains("activate") == true,
          terminalFocusScript(tty: "not a tty") == nil,
          iTerm2FocusScript(workingDirectory: "/tmp")?.contains(
              #"tell aSession to set sessionPath to variable named "session.path""#
          ) == true,
          iTerm2FocusScript(workingDirectory: "tmp") == nil,
          iTerm2ResumeScript(command: "claude --resume test")?.contains(
              #"tell current window to create tab with default profile command "claude --resume test""#
          ) == true,
          iTerm2ResumeScript(command: "") == nil,
          ottyTabID(
              from: Data(
                  #"""
                  {"ok":true,"data":[
                    {"id":"t_other","cwd":"/tmp/other","active":true},
                    {"id":"t_claude","cwd":"/tmp/Claude's project","active":false}
                  ]}
                  """#.utf8
              ),
              workingDirectory: "/tmp/Claude's project"
          ) == "t_claude",
          ottyHasActiveTab(
              from: Data(
                  #"""
                  {"ok":true,"data":[
                    {"id":"t_active","cwd":"/tmp","active":true}
                  ]}
                  """#.utf8
              )
          ),
          ottyTabFocusArguments(tabID: "t_claude")
              == ["--json", "tab", "focus", "t_claude"],
          compoundClaudeResumeCommand
            == "cd -- '/tmp/Claude'\\''s project' && exec '/opt/homebrew/bin/claude' --resume '\(claudeSessionID)'",
          claudeResumeCommand(
            sessionID: "not-a-uuid",
            workingDirectory: "/tmp",
            executablePath: "/opt/homebrew/bin/claude"
          ) == nil,
          completedClaudeItem.canOpen,
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: "io.appmakes.otty",
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: "com.googlecode.iterm2",
              runningBundleIdentifiers: [
                  "io.appmakes.otty",
                  "com.googlecode.iterm2",
                  "com.apple.Terminal",
              ],
              ottyHasActiveTab: true
          ) == "com.googlecode.iterm2",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["io.appmakes.otty"],
              ottyHasActiveTab: false
          ) == "io.appmakes.otty",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["com.googlecode.iterm2"],
              ottyHasActiveTab: false
          ) == "com.googlecode.iterm2",
          preferredClaudeTerminalBundleIdentifier(
              frontmostBundleIdentifier: nil,
              runningBundleIdentifiers: ["com.apple.Terminal"],
              ottyHasActiveTab: false
          ) == "com.apple.Terminal"
    else {
        fputs("Claude task compatibility failed\n", stderr)
        exit(1)
    }
}
