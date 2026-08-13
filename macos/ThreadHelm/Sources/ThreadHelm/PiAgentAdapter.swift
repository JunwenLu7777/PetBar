//
//  PiAgentAdapter.swift
//  ThreadHelm
//
//  模块职责：Pi 的本地只读发现、隔离 extension 生命周期和 state-only 事件归一化。
//

import Foundation

struct PiAgentAdapter: AgentAdapter {
    let metadata: AgentMetadata
    private let discoveryProvider: () -> AgentDiscovery
    private let readEvents: () throws -> [AgentEvent]
    private let executablePath: () -> String

    var managedIntegrationRelativePaths: [String] {
        [".pi/agent/extensions/threadhelm-state-observer"]
    }

    init(
        metadata: AgentMetadata? = builtInAgentMetadata().first {
            $0.id == .pi
        },
        discovery: @escaping () -> AgentDiscovery = {
            discoverLocalPiAgent()
        },
        readEvents: @escaping () throws -> [AgentEvent] = { [] },
        executablePath: @escaping () -> String = {
            Bundle.main.executableURL?.path ?? "/usr/bin/true"
        }
    ) {
        self.metadata = metadata!
        discoveryProvider = discovery
        self.readEvents = readEvents
        self.executablePath = executablePath
    }

    func discover() -> AgentDiscovery {
        discoveryProvider()
    }

    func integrationStatus(in scope: AgentIntegrationScope) -> AgentIntegrationStatus {
        do {
            return try PiExtensionConfiguration.status(
                in: scope,
                executablePath: executablePath()
            )
        } catch {
            return .needsRepair
        }
    }

    func installIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let changed = try PiExtensionConfiguration.install(
            in: scope,
            executablePath: executablePath()
        )
        return changed ? .installed : .unchanged
    }

    func repairIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        guard discover().isInstalled else { return .unchanged }
        let changed = try PiExtensionConfiguration.install(
            in: scope,
            executablePath: executablePath()
        )
        return changed ? .repaired : .unchanged
    }

    func uninstallIntegration(
        in scope: AgentIntegrationScope
    ) throws -> AgentIntegrationOperationResult {
        let changed = try PiExtensionConfiguration.uninstall(in: scope)
        return changed ? .uninstalled : .unchanged
    }

    func observe() throws -> AgentObservation {
        let events = try readEvents().compactMap(piStateOnlyEvent)
        return AgentObservation(
            events: events,
            snapshots: AgentEventReducer.reduce(events: events).snapshots
        )
    }

    func freshness(
        for snapshot: AgentSessionSnapshot,
        now: Date
    ) -> Freshness {
        if snapshot.freshness.isStale(at: now) {
            return snapshot.freshness
        }
        guard snapshot.executionState == .running || snapshot.executionState == .idle
        else { return snapshot.freshness }
        let expiresAt = snapshot.freshness.expiresAt
            ?? snapshot.updatedAt.addingTimeInterval(PiAgentDefaults.staleAfter)
        return Freshness(
            observedAt: snapshot.freshness.observedAt,
            expiresAt: expiresAt,
            staleReason: now >= expiresAt ? "pi-session-stale" : nil
        )
    }

    func openValidated(session: AgentSessionSnapshot) -> AgentOpenReport {
        AgentOpenReport(
            agentID: metadata.id,
            advertisedActionability: session.actionability,
            result: .unavailable,
            invokedExactTarget: false,
            independentlyConfirmedIdentity: false
        )
    }

    func diagnostics() -> AgentDiagnostics {
        let discovery = discover()
        return AgentDiagnostics(
            health: discovery.isInstalled ? .healthy : .unavailable,
            summary: discovery.isInstalled ? "已发现 Pi" : "未发现 Pi",
            counters: [:]
        )
    }
}

enum PiAgentDefaults {
    static let adapterVersion = "pi-extension-v1"
    static let staleAfter: TimeInterval = 30 * 60
}

enum PiExtensionConfigurationError: Error, Equatable {
    case notOwned
}

enum PiExtensionConfiguration {
    private static let extensionDirectoryPath =
        ".pi/agent/extensions/threadhelm-state-observer"
    private static let scriptFilename = "index.ts"
    private static let ownershipFilename = ".threadhelm-owner"
    private static let marker = "threadhelm-managed-state-observer-v1"
    private static let ownershipContent = "\(marker)\n"

    static func status(
        in scope: AgentIntegrationScope,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> AgentIntegrationStatus {
        let directoryURL = try extensionDirectoryURL(in: scope)
        let scriptURL = directoryURL.appendingPathComponent(scriptFilename)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .notInstalled
        }
        guard isOwned(directoryURL: directoryURL) else {
            return .needsRepair
        }
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8)
        else {
            return .needsRepair
        }
        return script == scriptContent(executablePath: executablePath)
            ? .installed
            : .needsRepair
    }

    @discardableResult
    static func install(
        in scope: AgentIntegrationScope,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directoryURL = try extensionDirectoryURL(in: scope)
        if fileManager.fileExists(atPath: directoryURL.path),
           !isOwned(directoryURL: directoryURL)
        {
            throw PiExtensionConfigurationError.notOwned
        }
        if try status(
            in: scope,
            executablePath: executablePath,
            fileManager: fileManager
        ) == .installed {
            return false
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try atomicWrite(
            Data(ownershipContent.utf8),
            to: directoryURL.appendingPathComponent(ownershipFilename),
            fileManager: fileManager
        )
        try atomicWrite(
            Data(scriptContent(executablePath: executablePath).utf8),
            to: directoryURL.appendingPathComponent(scriptFilename),
            fileManager: fileManager
        )
        return true
    }

    @discardableResult
    static func uninstall(
        in scope: AgentIntegrationScope,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directoryURL = try extensionDirectoryURL(in: scope)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return false
        }
        guard isOwned(directoryURL: directoryURL) else {
            throw PiExtensionConfigurationError.notOwned
        }
        try fileManager.removeItem(at: directoryURL)
        return true
    }

    static func extensionDirectoryURL(
        in scope: AgentIntegrationScope
    ) throws -> URL {
        try scope.managedURL(relativePath: extensionDirectoryPath)
    }

    static func generatedFilesForSelfTest(
        executablePath: String = "/tmp/ThreadHelm"
    ) -> [String: String] {
        [
            scriptFilename: scriptContent(executablePath: executablePath),
            ownershipFilename: ownershipContent,
        ]
    }

    private static func isOwned(directoryURL: URL) -> Bool {
        let ownershipURL = directoryURL.appendingPathComponent(ownershipFilename)
        return (try? String(contentsOf: ownershipURL, encoding: .utf8))
            == ownershipContent
    }

    private static func scriptContent(executablePath: String) -> String {
        let encodedPath = (try? JSONEncoder().encode(executablePath))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"/usr/bin/true\""
        return """
        // \(marker)
        import type {
          ExtensionAPI,
          ExtensionContext
        } from "@earendil-works/pi-coding-agent";
        import { spawn } from "node:child_process";

        const THREADHELM = \(encodedPath);
        let sequence = 0;

        function safeText(value: unknown, fallback: string): string {
          const text = typeof value === "string" ? value : "";
          return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(text)
            ? text
            : fallback;
        }

        function emit(kind: string, ctx: ExtensionContext): void {
          try {
            const session = safeText(
              ctx.sessionManager.getSessionId(),
              "pi-session-unknown"
            );
            sequence += 1;
            const body = {
              session_id: session,
              event_id: safeText(
                `${kind}:${session}:${sequence}`,
                `pi-event-${sequence}`
              ),
              sequence
            };
            const child = spawn(
              THREADHELM,
              ["--agent-hook", "pi", kind],
              { stdio: ["pipe", "ignore", "ignore"] }
            );
            child.on("error", () => {});
            child.stdin.on("error", () => {});
            child.stdin.end(JSON.stringify(body));
          } catch (_) {
            // Observation is best-effort and must never affect Pi.
          }
        }

        export default function threadHelmStateObserver(pi: ExtensionAPI): void {
          pi.on("session_start", (_event, ctx) => emit("session_start", ctx));
          pi.on("agent_start", (_event, ctx) => emit("agent_start", ctx));
          pi.on("agent_end", (_event, ctx) => emit("agent_end", ctx));
          pi.on("tool_call", (_event, ctx) => emit("tool_call", ctx));
          pi.on("tool_result", (_event, ctx) => emit("tool_result", ctx));
          pi.on("session_compact", (_event, ctx) => emit("session_compact", ctx));
          pi.on("agent_settled", (_event, ctx) => emit("agent_settled", ctx));
          pi.on("session_shutdown", (_event, ctx) => emit("session_shutdown", ctx));
        }
        """
    }

    private static func atomicWrite(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try AgentIntegrationAtomicFileWriter.write(
            data,
            to: url,
            fileManager: fileManager
        )
    }
}

private let piStateOnlyEventTypes: Set<String> = [
    "session_start",
    "agent_start",
    "agent_end",
    "tool_call",
    "tool_result",
    "session_compact",
    "agent_settled",
    "session_shutdown",
]

private func piStateOnlyEvent(_ event: AgentEvent) -> AgentEvent? {
    guard event.identity.agentID == .pi,
          piStateOnlyEventTypes.contains(event.eventType)
    else { return nil }
    let state: ExecutionState
    let reason: AttentionReason
    switch event.eventType {
    case "session_start":
        state = .idle
        reason = .none
    case "agent_settled":
        state = event.executionState == .failed ? .failed : .completed
        reason = state == .failed ? .taskFailure : .reviewReady
    case "session_shutdown":
        state = .offline
        reason = .none
    default:
        state = .running
        reason = .none
    }
    return AgentEvent(
        identity: event.identity,
        adapterVersion: event.adapterVersion,
        eventID: event.eventID,
        sequence: event.sequence,
        eventType: event.eventType,
        observedAt: event.observedAt,
        monotonicNanoseconds: event.monotonicNanoseconds,
        executionState: state,
        attentionReason: reason,
        actionability: .viewOnly,
        evidenceQuality: event.evidenceQuality,
        freshness: event.freshness,
        title: "Pi 会话",
        activitySummary: nil,
        workingDirectory: nil
    )
}

func piAgentEvent(
    from envelope: AgentTransportEnvelope,
    observedAt: Date
) -> AgentEvent? {
    guard envelope.agentID == .pi else { return nil }
    let state = envelope.redactedPayload["state"].flatMap {
        ExecutionState(rawValue: $0)
    }
        ?? .running
    let rawReason = envelope.redactedPayload["attentionReason"]
        .flatMap { AttentionReason(rawValue: $0) } ?? .none
    let reason: AttentionReason
    if envelope.eventType == "agent_settled",
       state == .failed,
       rawReason == .taskFailure
    {
        reason = .taskFailure
    } else if envelope.eventType == "agent_settled",
              state == .completed
    {
        reason = .reviewReady
    } else {
        reason = .none
    }
    let actionability = Actionability.viewOnly
    let evidence = envelope.redactedPayload["evidenceQuality"]
        .flatMap { EvidenceQuality(rawValue: $0) } ?? .officialHook
    let freshnessClass = envelope.redactedPayload["freshness"] ?? "fresh"
    let stale = freshnessClass == "stale" || state == .offline || state == .stale
    let nativeID = envelope.nativeSessionCandidate ?? "pi-session-unknown"
    return AgentEvent(
        identity: AgentSessionIdentity(agentID: .pi, nativeID: nativeID),
        adapterVersion: envelope.adapterVersion,
        eventID: envelope.eventID,
        sequence: envelope.sequence,
        eventType: envelope.eventType,
        observedAt: observedAt,
        monotonicNanoseconds: envelope.monotonicNanoseconds,
        executionState: state,
        attentionReason: reason,
        actionability: actionability,
        evidenceQuality: evidence,
        freshness: Freshness(
            observedAt: observedAt,
            expiresAt: stale ? observedAt : observedAt.addingTimeInterval(
                PiAgentDefaults.staleAfter
            ),
            staleReason: stale ? "pi-session-shutdown-or-stale" : nil
        ),
        title: "Pi session",
        activitySummary: nil,
        workingDirectory: nil
    )
}

func discoverLocalPiAgent(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> AgentDiscovery {
    guard let executable = locatePiExecutable(
        environment: environment,
        fileManager: fileManager
    ) else {
        return AgentDiscovery(
            isInstalled: false,
            version: nil,
            compatibility: .unknown
        )
    }
    let version = piVersion(executableURL: executable)
    return versionValidatedAgentDiscovery(
        agentID: .pi,
        isInstalled: true,
        components: version.map {
            [AgentVersionComponent(key: "version", label: "Version", value: $0)]
        } ?? []
    )
}

func locatePiExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> URL? {
    if let override = environment["THREADHELM_PI_EXECUTABLE"],
       !override.isEmpty,
       fileManager.isExecutableFile(atPath: override)
    {
        return URL(fileURLWithPath: override)
    }
    let pathCandidates = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map { String($0) }
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    for directory in pathCandidates {
        let candidate = URL(fileURLWithPath: directory)
            .appendingPathComponent("pi")
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func piVersion(executableURL: URL) -> String? {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["--version"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let capture = captureProcessOutput(
        process: process,
        output: output.fileHandleForReading,
        timeout: 0.75,
        maximumOutputBytes: 4_096
    )
    guard capture.termination == .exited || capture.termination == .outputClosed,
          let text = String(data: capture.data, encoding: .utf8)
    else { return nil }
    let firstLine = text
        .split(whereSeparator: \.isNewline)
        .first
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    return firstLine.flatMap { normalizedAgentVersion(from: $0) }
}
