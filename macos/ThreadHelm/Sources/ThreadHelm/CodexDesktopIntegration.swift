//
//  CodexDesktopIntegration.swift
//  ThreadHelm
//
//  模块职责：Codex 桌面应用识别、AX 标签匹配，以及 Claude 会话的终端
//  集成（TTY 追踪、otty/iTerm2/Terminal 聚焦与恢复脚本）。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func isKnownCodexDesktopBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
    let normalizedIdentifier = bundleIdentifier?.lowercased() ?? ""
    return ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"]
        .contains(normalizedIdentifier)
}

func isCodexDesktopApplication(
    bundleIdentifier: String?,
    localizedName: String?,
    bundleURL: URL?,
    activationPolicy: NSApplication.ActivationPolicy
) -> Bool {
    guard activationPolicy == .regular else { return false }

    if isKnownCodexDesktopBundleIdentifier(bundleIdentifier) {
        return true
    }

    let normalizedName = localizedName?.lowercased() ?? ""
    let normalizedBundleName = bundleURL?
        .deletingPathExtension()
        .lastPathComponent
        .lowercased() ?? ""
    let knownName = normalizedName == "codex" || normalizedName == "chatgpt"
    let knownBundle = normalizedBundleName == "codex" || normalizedBundleName == "chatgpt"
    return knownName && knownBundle
}

func isCodexDesktopRunning() -> Bool {
    let applications = NSWorkspace.shared.runningApplications
    if applications.contains(where: { application in
        isKnownCodexDesktopBundleIdentifier(application.bundleIdentifier)
    }) {
        return true
    }

    // Compatibility fallback for unsigned or legacy builds without a known
    // bundle identifier. Keep the LaunchServices-backed name lookups off the
    // common path because they are comparatively expensive.
    return applications.contains { application in
        isCodexDesktopApplication(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            bundleURL: application.bundleURL,
            activationPolicy: application.activationPolicy
        )
    }
}

func isHideActivityAccessibilityLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "hide activity" || normalized == "隐藏活动"
}

func isShowActivityAccessibilityLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.range(
        of: #"^show activity,\s*[0-9]+\s+items?$"#,
        options: .regularExpression
    ) != nil
        || normalized.range(
            of: #"^显示活动[，,]\s*[0-9]+\s*项$"#,
            options: .regularExpression
        ) != nil
}

func isOpenActivityNotificationAccessibilityLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("open notification")
        || normalized.contains("打开通知")
}

func isMuteTaskMenuItemTitle(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "mute task" || normalized == "静音任务"
}

func codexThreadURL(threadID: String) -> URL? {
    guard UUID(uuidString: threadID) != nil else { return nil }
    return URL(string: "codex://threads/\(threadID.lowercased())")
}

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func claudeResumeCommand(
    sessionID: String,
    workingDirectory: String,
    executablePath: String
) -> String? {
    guard UUID(uuidString: sessionID) != nil,
          workingDirectory.hasPrefix("/"),
          executablePath.hasPrefix("/")
    else { return nil }
    return "cd -- \(shellSingleQuoted(workingDirectory))"
        + " && exec \(shellSingleQuoted(executablePath))"
        + " --resume \(shellSingleQuoted(sessionID.lowercased()))"
}

func normalizedTerminalTTY(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "??" else { return nil }
    let path = trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
    guard path.range(
        of: #"^/dev/tty[A-Za-z0-9._-]+$"#,
        options: .regularExpression
    ) != nil else { return nil }
    return path
}

func directControllingTTY(forProcessID processID: Int32) -> String? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "tty="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          )
    else { return nil }
    return normalizedTerminalTTY(text)
}

func parentProcessID(forProcessID processID: Int32) -> Int32? {
    guard processID > 1 else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(processID)", "-o", "ppid="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          let text = String(
              data: output.fileHandleForReading.readDataToEndOfFile(),
              encoding: .utf8
          ),
          let parent = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          parent > 1,
          parent != processID
    else { return nil }
    return parent
}

func controllingTTYFromProcessChain(
    startingAt processID: Int32,
    directTTY: (Int32) -> String?,
    parentPID: (Int32) -> Int32?
) -> String? {
    var candidate = processID
    var visited = Set<Int32>()
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let tty = directTTY(candidate) {
            return tty
        }
        guard let parent = parentPID(candidate) else { break }
        candidate = parent
    }
    return nil
}

func controllingTTY(forProcessID processID: Int32) -> String? {
    controllingTTYFromProcessChain(
        startingAt: processID,
        directTTY: { directControllingTTY(forProcessID: $0) },
        parentPID: { parentProcessID(forProcessID: $0) }
    )
}

func terminalHostApplication(
    forProcessID processID: Int32
) -> NSRunningApplication? {
    var candidate = processID
    var visited = Set<Int32>()
    var firstApplication: NSRunningApplication?
    for _ in 0..<16 {
        guard candidate > 1, visited.insert(candidate).inserted else { break }
        if let application = NSRunningApplication(processIdentifier: candidate),
           application.bundleURL?.pathExtension.lowercased() == "app",
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            firstApplication = firstApplication ?? application
            if application.activationPolicy == .regular {
                return application
            }
        }
        guard let parent = parentProcessID(forProcessID: candidate) else { break }
        candidate = parent
    }
    return firstApplication
}

func ottyExecutablePath() -> String? {
    let candidates = [
        ProcessInfo.processInfo.environment["OTTY_BIN"],
        "/usr/local/bin/otty",
        "/opt/homebrew/bin/otty",
        "/Applications/Otty.app/Contents/MacOS/otty-cli",
    ].compactMap { $0 }
    return candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    })
}

func runOttyCLI(arguments: [String]) -> Data? {
    guard let executablePath = ottyExecutablePath() else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return output.fileHandleForReading.readDataToEndOfFile()
}

func normalizedAbsolutePath(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
        .standardizedFileURL
        .path
}

struct OttyTabSnapshot {
    let id: String
    let workingDirectory: String
    let isActive: Bool
}

func ottyTabSnapshots(from data: Data) -> [OttyTabSnapshot]? {
    guard let root = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
        root["ok"] as? Bool == true,
        let rawTabs = root["data"] as? [[String: Any]]
    else { return nil }
    return rawTabs.compactMap { value in
        guard let id = value["id"] as? String,
              let cwd = value["cwd"] as? String,
              let normalizedCWD = normalizedAbsolutePath(cwd)
        else { return nil }
        return OttyTabSnapshot(
            id: id,
            workingDirectory: normalizedCWD,
            isActive: value["active"] as? Bool ?? false
        )
    }
}

func ottyTabID(from data: Data, workingDirectory: String) -> String? {
    guard let target = normalizedAbsolutePath(workingDirectory),
          let tabs = ottyTabSnapshots(from: data)
    else { return nil }
    return tabs
        .filter { $0.workingDirectory == target }
        .sorted { $0.isActive && !$1.isActive }
        .first?
        .id
}

func ottyHasActiveTab(from data: Data) -> Bool {
    ottyTabSnapshots(from: data)?.contains { $0.isActive } ?? false
}

func ottyTabFocusArguments(tabID: String) -> [String]? {
    guard tabID.range(
        of: #"^[A-Za-z0-9._-]+$"#,
        options: .regularExpression
    ) != nil else { return nil }
    return ["--json", "tab", "focus", tabID]
}

func activateRunningApplication(bundleIdentifier: String) -> Bool {
    guard let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).first else { return false }
    return application.activate(options: [
        .activateAllWindows,
        .activateIgnoringOtherApps,
    ])
}

func preferredClaudeTerminalBundleIdentifier(
    frontmostBundleIdentifier: String?,
    runningBundleIdentifiers: Set<String>,
    ottyHasActiveTab: Bool
) -> String? {
    let supportedBundleIdentifiers: Set<String> = [
        "io.appmakes.otty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]
    if let frontmostBundleIdentifier,
       supportedBundleIdentifiers.contains(frontmostBundleIdentifier),
       runningBundleIdentifiers.contains(frontmostBundleIdentifier)
    {
        return frontmostBundleIdentifier
    }
    if ottyHasActiveTab,
       runningBundleIdentifiers.contains("io.appmakes.otty")
    {
        return "io.appmakes.otty"
    }
    if runningBundleIdentifiers == ["io.appmakes.otty"] {
        return "io.appmakes.otty"
    }
    if runningBundleIdentifiers.contains("com.googlecode.iterm2") {
        return "com.googlecode.iterm2"
    }
    if runningBundleIdentifiers.contains("com.apple.Terminal") {
        return "com.apple.Terminal"
    }
    return nil
}

func focusExistingOttyTerminal(workingDirectory: String) -> Bool {
    guard NSRunningApplication.runningApplications(
        withBundleIdentifier: "io.appmakes.otty"
    ).isEmpty == false,
          let listData = runOttyCLI(arguments: ["--json", "tab", "list"]),
          let tabID = ottyTabID(
              from: listData,
              workingDirectory: workingDirectory
          ),
          let arguments = ottyTabFocusArguments(tabID: tabID),
          runOttyCLI(arguments: arguments) != nil
    else { return false }
    return activateRunningApplication(bundleIdentifier: "io.appmakes.otty")
}

func iTerm2FocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "com.googlecode.iterm2"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                    if (tty of aSession as text) is "\(tty)" then
                        tell aSession to select
                        tell aTab to select
                        tell aWindow to select
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end repeat
        return false
    end tell
    """
}

func ottyFocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "io.appmakes.otty"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                if (tty of aTab as text) is "\(tty)" then
                    set selected of aTab to true
                    activate
                    return true
                end if
            end repeat
        end repeat
        return false
    end tell
    """
}

func terminalFocusScript(tty: String) -> String? {
    guard let tty = normalizedTerminalTTY(tty) else { return nil }
    return """
    tell application id "com.apple.Terminal"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                if (tty of aTab as text) is "\(tty)" then
                    set selected tab of aWindow to aTab
                    set index of aWindow to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
        return false
    end tell
    """
}

func appleScriptEscapedString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

func ottyResumeScript(command: String) -> String? {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let escapedCommand = appleScriptEscapedString(command)
    return """
    tell application id "io.appmakes.otty"
        set targetTab to do script "\(escapedCommand)"
        set targetWindow to front window
        set selected of targetTab to true
        set index of targetWindow to 1
        activate
        return true
    end tell
    """
}

func iTerm2FocusScript(workingDirectory: String) -> String? {
    var isDirectory: ObjCBool = false
    guard workingDirectory.hasPrefix("/"),
          FileManager.default.fileExists(
              atPath: workingDirectory,
              isDirectory: &isDirectory
          ),
          isDirectory.boolValue
    else { return nil }
    let escapedPath = appleScriptEscapedString(workingDirectory)
    return """
    tell application id "com.googlecode.iterm2"
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aSession in sessions of aTab
                    try
                        tell aSession to set sessionPath to variable named "session.path"
                        if sessionPath is "\(escapedPath)" or sessionPath is "file://\(escapedPath)" then
                            tell aSession to select
                            tell aTab to select
                            tell aWindow to select
                            activate
                            return true
                        end if
                    end try
                end repeat
            end repeat
        end repeat
        return false
    end tell
    """
}

func iTerm2ResumeScript(command: String) -> String? {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    let escapedCommand = appleScriptEscapedString(command)
    return """
    tell application id "com.googlecode.iterm2"
        activate
        if (count of windows) is 0 then
            create window with default profile command "\(escapedCommand)"
        else
            tell current window to create tab with default profile command "\(escapedCommand)"
        end if
        return true
    end tell
    """
}

func claudeResumeTerminalPreference(
    runningBundleIdentifiers: Set<String>,
    installedBundleIdentifiers: Set<String>
) -> [String] {
    let priority = [
        "io.appmakes.otty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]
    let running = priority.filter(runningBundleIdentifiers.contains)
    let installed = priority.filter {
        !runningBundleIdentifiers.contains($0)
            && installedBundleIdentifiers.contains($0)
    }
    return running + installed
}

struct ClaudeLiveProcessTarget: Equatable {
    let sessionID: String
    let processID: Int32
    let processStartIdentity: String
}

func claudeLiveProcessTarget(
    forSessionID sessionID: String,
    from data: Data,
    processStartIdentity: (Int32) -> String? =
        currentProcessStartIdentity(forProcessID:),
    isProcessAlive: (Int32) -> Bool = isLiveClaudeProcess
) -> ClaudeLiveProcessTarget? {
    let normalizedSessionID = sessionID
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard UUID(uuidString: normalizedSessionID) != nil,
          let values = try? JSONSerialization.jsonObject(with: data)
            as? [[String: Any]]
    else { return nil }

    return values.compactMap { value -> (Double, ClaudeLiveProcessTarget)? in
        guard let rawSessionID = value["sessionId"] as? String,
              rawSessionID.lowercased() == normalizedSessionID,
              let rawProcessID = value["pid"] as? Int
                ?? (value["pid"] as? NSNumber)?.intValue,
              let processID = Int32(exactly: rawProcessID),
              processID > 1,
              isProcessAlive(processID),
              let identity = processStartIdentity(processID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty
        else { return nil }
        let startedAt = value["startedAt"] as? Double
            ?? (value["startedAt"] as? NSNumber)?.doubleValue
            ?? 0
        return (
            startedAt,
            ClaudeLiveProcessTarget(
                sessionID: normalizedSessionID,
                processID: processID,
                processStartIdentity: identity
            )
        )
    }
    .max { $0.0 < $1.0 }?
    .1
}

func currentClaudeLiveProcessTarget(
    forSessionID sessionID: String
) -> ClaudeLiveProcessTarget? {
    guard let executableURL = locateClaudeExecutable(),
          let data = captureClaudeAgentsJSON(
              executableURL: executableURL,
              timeout: 1
          )
    else { return nil }
    return claudeLiveProcessTarget(
        forSessionID: sessionID,
        from: data
    )
}

func refreshedClaudeTerminalOpenRequest(
    _ request: ClaudeTerminalOpenRequest,
    liveProcessTarget: ClaudeLiveProcessTarget?
) -> ClaudeTerminalOpenRequest {
    guard let sessionID = request.sessionID,
          let liveProcessTarget,
          liveProcessTarget.sessionID.caseInsensitiveCompare(sessionID)
            == .orderedSame
    else { return request }
    return ClaudeTerminalOpenRequest(
        sessionID: sessionID,
        workingDirectory: request.workingDirectory,
        processID: liveProcessTarget.processID,
        processStartIdentity: liveProcessTarget.processStartIdentity
    )
}

enum ClaudeTerminalFocusStrategy: Equatable {
    case selectOttyTTY
    case selectITermTTY
    case selectTerminalTTY
    case activateHostApplication
}

func claudeTerminalFocusStrategy(
    bundleIdentifier: String?
) -> ClaudeTerminalFocusStrategy {
    switch bundleIdentifier {
    case "io.appmakes.otty":
        return .selectOttyTTY
    case "com.googlecode.iterm2":
        return .selectITermTTY
    case "com.apple.Terminal":
        return .selectTerminalTTY
    default:
        return .activateHostApplication
    }
}

func executeAppleScriptReturningBoolean(_ source: String) -> Bool {
    guard let script = NSAppleScript(source: source) else { return false }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    return error == nil && result.booleanValue
}

func focusExistingClaudeTerminal(
    processID: Int32,
    processStartIdentity: String
) -> OpenResult {
    guard isLiveClaudeProcess(processID),
          currentProcessStartIdentity(forProcessID: processID)
            == processStartIdentity,
          let hostApplication = terminalHostApplication(forProcessID: processID)
    else { return .failed }

    let source: String?
    switch claudeTerminalFocusStrategy(
        bundleIdentifier: hostApplication.bundleIdentifier
    ) {
    case .selectOttyTTY:
        guard let tty = controllingTTY(forProcessID: processID) else {
            return .failed
        }
        source = ottyFocusScript(tty: tty)
    case .selectITermTTY:
        guard let tty = controllingTTY(forProcessID: processID) else {
            return .failed
        }
        source = iTerm2FocusScript(tty: tty)
    case .selectTerminalTTY:
        guard let tty = controllingTTY(forProcessID: processID) else {
            return .failed
        }
        source = terminalFocusScript(tty: tty)
    case .activateHostApplication:
        return hostApplication.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps,
        ]) ? .appFocused : .failed
    }
    guard let source else { return .failed }
    return executeAppleScriptReturningBoolean(source) ? .exactSession : .failed
}

func focusExistingClaudeTerminal(workingDirectory: String) -> Bool {
    if focusExistingOttyTerminal(workingDirectory: workingDirectory) {
        return true
    }
    guard NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.googlecode.iterm2"
    ).isEmpty == false,
          let source = iTerm2FocusScript(workingDirectory: workingDirectory)
    else { return false }
    return executeAppleScriptReturningBoolean(source)
}

func openClaudeSession(
    sessionID: String,
    workingDirectory: String
) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: workingDirectory,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else { return false }
    guard let executablePath = locateClaudeExecutable()?.path,
          let command = claudeResumeCommand(
        sessionID: sessionID,
        workingDirectory: workingDirectory,
        executablePath: executablePath
    ) else { return false }

    let supportedBundleIdentifiers = [
        "io.appmakes.otty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]
    let runningBundleIdentifiers = Set(
        supportedBundleIdentifiers.filter {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: $0
            ).isEmpty == false
        }
    )
    let installedBundleIdentifiers = Set(
        supportedBundleIdentifiers.filter {
            $0 == "com.apple.Terminal"
                || NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: $0
                ) != nil
        }
    )

    for bundleIdentifier in claudeResumeTerminalPreference(
        runningBundleIdentifiers: runningBundleIdentifiers,
        installedBundleIdentifiers: installedBundleIdentifiers
    ) {
        switch bundleIdentifier {
        case "io.appmakes.otty":
            if let source = ottyResumeScript(command: command),
               executeAppleScriptReturningBoolean(source)
            {
                return true
            }
        case "com.googlecode.iterm2":
            if let source = iTerm2ResumeScript(command: command),
               executeAppleScriptReturningBoolean(source)
            {
                return true
            }
        case "com.apple.Terminal":
            let escapedCommand = appleScriptEscapedString(command)
            let source = """
            tell application "Terminal"
                activate
                do script "\(escapedCommand)"
            end tell
            """
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { continue }
            _ = script.executeAndReturnError(&error)
            if error == nil {
                return true
            }
        default:
            continue
        }
    }
    return false
}
