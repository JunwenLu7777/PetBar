//
//  AgentEventSocketSelfTest.swift
//  ThreadHelm
//
//  模块职责：用隔离 mktemp 目录验证本机 Agent event socket。
//  不触碰真实 Application Support，也不安装任何 vendor hook。
//

import Darwin
import Foundation

func runAgentEventSocketSelfTest() -> Bool {
    do {
        try AgentEventSocketSelfTest().run()
        return true
    } catch {
        FileHandle.standardError.write(
            Data("AgentEventSocketSelfTest failed: \(error)\n".utf8)
        )
        return false
    }
}

private enum AgentEventSocketSelfTestFailure: Error {
    case failed(String)
}

private final class AgentEventSocketSelfTest {
    func run() throws {
        try withTemporarySocketURL { socketURL in
            let received = LockedEnvelopeStore()
            let server = AgentEventSocketServer(
                configuration: AgentEventSocketConfiguration(socketURL: socketURL)
            ) { envelope in
                received.append(envelope)
            }
            try server.start()
            defer { server.stop() }

            try assertOwnerOnlyPermissions(socketURL: socketURL)
            try assertSuccessfulDelivery(socketURL: socketURL, received: received)
            try assertConcurrentAndRepeatedDelivery(
                socketURL: socketURL,
                received: received
            )
            try assertOversizeBecomesMetadataOnly(
                socketURL: socketURL,
                received: received
            )
        }

        try withTemporarySocketURL { socketURL in
            try assertWrongUIDIsRejected(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertMalformedInputFailsOpen(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertDisallowedPayloadIsRejected(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertOversizeRawFrameFailsOpen(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertOfflineFailsOpen(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertSlowReceiverFailsOpen(socketURL: socketURL)
        }

        try withTemporarySocketURL { socketURL in
            try assertExistingRegularFileIsPreserved(socketURL: socketURL)
        }

        try assertFreshNestedDirectoryIsCreated()
        try assertUnsafeExistingDirectoryIsPreserved()
    }

    private func assertOwnerOnlyPermissions(socketURL: URL) throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        var directoryStat = stat()
        var socketStat = stat()
        guard lstat(directoryURL.path, &directoryStat) == 0,
              lstat(socketURL.path, &socketStat) == 0
        else { throw fail("permission stat") }
        guard directoryStat.st_uid == geteuid(),
              (directoryStat.st_mode & S_IRWXG) == 0,
              (directoryStat.st_mode & S_IRWXO) == 0,
              (directoryStat.st_mode & S_IRWXU) == S_IRWXU
        else { throw fail("directory owner-only mode") }
        guard socketStat.st_uid == geteuid(),
              (socketStat.st_mode & S_IRWXG) == 0,
              (socketStat.st_mode & S_IRWXO) == 0
        else { throw fail("socket owner-only mode") }
    }

    private func assertSuccessfulDelivery(
        socketURL: URL,
        received: LockedEnvelopeStore
    ) throws {
        let envelope = makeEnvelope(eventID: "success", sequence: 1)
        let attempt = AgentEventSocketClient.send(envelope, to: socketURL)
        guard attempt.disposition == .delivered,
              attempt.vendorResponse.isEmpty,
              !attempt.usedMetadataOnlyEnvelope
        else { throw fail("successful delivery attempt") }

        try waitUntil {
            received.snapshot().contains { $0.eventID == "success" }
        }
        guard received.snapshot().contains(where: {
            $0.schemaVersion == envelope.schemaVersion
                && $0.agentID == envelope.agentID
                && $0.adapterVersion == envelope.adapterVersion
                && $0.nativeSessionCandidate == envelope.nativeSessionCandidate
                && $0.eventID == envelope.eventID
                && $0.sequence == envelope.sequence
                && $0.eventType == envelope.eventType
                && $0.monotonicNanoseconds == envelope.monotonicNanoseconds
                && $0.redactedPayload == envelope.redactedPayload
        }) else {
            throw fail("successful envelope callback")
        }
    }

    private func assertConcurrentAndRepeatedDelivery(
        socketURL: URL,
        received: LockedEnvelopeStore
    ) throws {
        let count = 24
        let group = DispatchGroup()
        let latencies = LockedLatencyStore()
        for index in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let started = DispatchTime.now().uptimeNanoseconds
                let attempt = AgentEventSocketClient.send(
                    self.makeEnvelope(
                        eventID: "concurrent-\(index % 6)",
                        sequence: index
                    ),
                    to: socketURL
                )
                let elapsed = Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000_000
                if attempt.disposition == .delivered {
                    latencies.append(elapsed)
                }
                group.leave()
            }
        }
        guard group.wait(timeout: .now() + 3.0) == .success else {
            throw fail("concurrent delivery timeout")
        }
        let values = latencies.snapshot().sorted()
        guard values.count == count else {
            throw fail("concurrent delivery disposition")
        }
        let p95 = values[max(0, Int(Double(values.count - 1) * 0.95))]
        guard p95 <= 3.0 else {
            throw fail("local roundtrip p95")
        }
        try waitUntil {
            received.snapshot().filter {
                $0.eventID.hasPrefix("concurrent-")
            }.count >= count
        }
    }

    private func assertOversizeBecomesMetadataOnly(
        socketURL: URL,
        received: LockedEnvelopeStore
    ) throws {
        let envelope = AgentTransportEnvelope(
            agentID: .cursor,
            adapterVersion: "self-test",
            nativeSessionCandidate: "session-oversize",
            eventID: "metadata-only",
            sequence: 99,
            eventType: "running",
            monotonicNanoseconds: 99,
            redactedPayload: [
                "state": String(repeating: "not-allowed-large-value", count: 4_000),
                "rawPrompt": "must-not-cross-socket",
            ]
        )
        let attempt = AgentEventSocketClient.send(envelope, to: socketURL)
        guard attempt.disposition == .delivered,
              attempt.vendorResponse.isEmpty,
              attempt.usedMetadataOnlyEnvelope
        else { throw fail("oversize metadata-only delivery") }
        try waitUntil {
            received.snapshot().contains {
                $0.eventID == "metadata-only"
                    && $0.redactedPayload["payloadDisposition"] == "metadataOnly"
            }
        }
        let text = String(
            data: (try? AgentTransportEncoder.encode(envelope).data) ?? Data(),
            encoding: .utf8
        ) ?? ""
        guard !text.contains("must-not-cross-socket"),
              !text.contains("not-allowed-large-value")
        else { throw fail("oversize raw content redaction") }
    }

    private func assertWrongUIDIsRejected(socketURL: URL) throws {
        let received = LockedEnvelopeStore()
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL),
            peerValidator: { _, _ in false }
        ) { envelope in
            received.append(envelope)
        }
        try server.start()
        defer { server.stop() }

        let attempt = AgentEventSocketClient.send(
            makeEnvelope(eventID: "wrong-uid", sequence: 1),
            to: socketURL
        )
        guard attempt.disposition != .delivered,
              attempt.vendorResponse.isEmpty,
              received.snapshot().isEmpty
        else { throw fail("wrong uid rejection") }
    }

    private func assertMalformedInputFailsOpen(socketURL: URL) throws {
        let received = LockedEnvelopeStore()
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { envelope in
            received.append(envelope)
        }
        try server.start()
        defer { server.stop() }

        let response = AgentEventSocketRawClient.sendRawFrame(
            Data("{\"schemaVersion\":1,\"rawPrompt\":\"no\"}".utf8),
            to: socketURL
        )
        guard response == nil,
              received.snapshot().isEmpty
        else { throw fail("malformed input fail-open") }
    }

    private func assertOversizeRawFrameFailsOpen(socketURL: URL) throws {
        let received = LockedEnvelopeStore()
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { envelope in
            received.append(envelope)
        }
        try server.start()
        defer { server.stop() }

        let response = AgentEventSocketRawClient.sendRawFrame(
            Data(repeating: 65, count: AgentTransportContract.maximumSerializedBytes + 1),
            to: socketURL,
            declaredLength: UInt32(AgentTransportContract.maximumSerializedBytes + 1)
        )
        guard response == nil,
              received.snapshot().isEmpty
        else { throw fail("oversize raw frame fail-open") }
    }

    private func assertDisallowedPayloadIsRejected(socketURL: URL) throws {
        let received = LockedEnvelopeStore()
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { envelope in
            received.append(envelope)
        }
        try server.start()
        defer { server.stop() }

        let object: [String: Any] = [
            "schemaVersion": AgentTransportContract.schemaVersion,
            "agentID": "cursor",
            "adapterVersion": "self-test",
            "nativeSessionCandidate": "session-safe",
            "eventID": "event-disallowed",
            "sequence": 1,
            "eventType": "stop",
            "monotonicNanoseconds": 1,
            "redactedPayload": [
                "state": "completed",
                "rawPrompt": "must-not-reach-handler",
            ],
        ]
        let response = AgentEventSocketRawClient.sendRawFrame(
            try JSONSerialization.data(withJSONObject: object),
            to: socketURL
        )
        guard response == nil, received.snapshot().isEmpty else {
            throw fail("disallowed payload reached handler")
        }
    }

    private func assertExistingRegularFileIsPreserved(socketURL: URL) throws {
        let original = Data("do-not-unlink".utf8)
        try original.write(to: socketURL)
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { _ in }
        do {
            try server.start()
            server.stop()
            throw fail("existing regular file was replaced")
        } catch AgentEventSocketError.unsafeExistingPath {
        }
        guard try Data(contentsOf: socketURL) == original else {
            throw fail("existing regular file was not preserved")
        }
    }

    private func assertFreshNestedDirectoryIsCreated() throws {
        let root = URL(
            fileURLWithPath: "/tmp/threadhelm-es-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ThreadHelm", isDirectory: true)
            .appendingPathComponent("AgentEvents", isDirectory: true)
            .appendingPathComponent("events.sock")
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { _ in }
        try server.start()
        defer { server.stop() }
        try assertOwnerOnlyPermissions(socketURL: socketURL)
    }

    private func assertUnsafeExistingDirectoryIsPreserved() throws {
        let root = URL(
            fileURLWithPath: "/tmp/threadhelm-es-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let directory = root.appendingPathComponent("existing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard chmod(directory.path, 0o755) == 0 else {
            throw fail("unsafe directory setup")
        }
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(
                socketURL: directory.appendingPathComponent("events.sock")
            )
        ) { _ in }
        do {
            try server.start()
            server.stop()
            throw fail("unsafe existing directory was accepted")
        } catch AgentEventSocketError.directoryPermissionFailed {
        }
        var directoryStat = stat()
        guard lstat(directory.path, &directoryStat) == 0,
              (directoryStat.st_mode & S_IRWXG) != 0,
              (directoryStat.st_mode & S_IRWXO) != 0
        else {
            throw fail("unsafe existing directory permissions were mutated")
        }
    }

    private func assertOfflineFailsOpen(socketURL: URL) throws {
        let attempt = AgentEventSocketClient.send(
            makeEnvelope(eventID: "offline", sequence: 1),
            to: socketURL
        )
        guard attempt.disposition == .offline,
              attempt.vendorResponse.isEmpty
        else { throw fail("offline fail-open") }
    }

    private func assertSlowReceiverFailsOpen(socketURL: URL) throws {
        let server = AgentEventSocketServer(
            configuration: AgentEventSocketConfiguration(socketURL: socketURL)
        ) { _ in
            Thread.sleep(forTimeInterval: 0.60)
        }
        try server.start()
        defer { server.stop() }

        let started = Date()
        let attempt = AgentEventSocketClient.send(
            makeEnvelope(eventID: "slow", sequence: 1),
            to: socketURL
        )
        let elapsed = Date().timeIntervalSince(started)
        guard attempt.disposition == .timedOut,
              attempt.vendorResponse.isEmpty,
              elapsed < 0.50
        else { throw fail("slow receiver fail-open") }
    }

    private func makeEnvelope(
        eventID: String,
        sequence: Int?
    ) -> AgentTransportEnvelope {
        AgentTransportEnvelope(
            agentID: .zcode,
            adapterVersion: "self-test",
            nativeSessionCandidate: "session-\(eventID)",
            eventID: eventID,
            sequence: sequence,
            eventType: "running",
            monotonicNanoseconds: UInt64(sequence ?? 0),
            redactedPayload: [
                "state": "running",
                "attentionReason": "none",
                "actionability": "viewOnly",
            ]
        )
    }

    private func withTemporarySocketURL(
        _ body: (URL) throws -> Void
    ) throws {
        var template = Array(
            (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("threadhelm-event-socket.XXXXXX")
                .utf8CString
        )
        guard let directoryPath = template.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress)
        }) else {
            throw fail("mktemp")
        }
        let directoryURL = URL(fileURLWithPath: String(cString: directoryPath))
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try body(directoryURL.appendingPathComponent("agent-event.sock"))
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: () -> Bool
    ) throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if predicate() {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw fail("waitUntil")
    }

    private func fail(_ message: String) -> AgentEventSocketSelfTestFailure {
        .failed(message)
    }
}

private final class LockedEnvelopeStore {
    private let lock = NSLock()
    private var envelopes: [AgentTransportEnvelope] = []

    func append(_ envelope: AgentTransportEnvelope) {
        lock.lock()
        envelopes.append(envelope)
        lock.unlock()
    }

    func snapshot() -> [AgentTransportEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return envelopes
    }
}

private final class LockedLatencyStore {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private enum AgentEventSocketRawClient {
    static func sendRawFrame(
        _ payload: Data,
        to socketURL: URL,
        declaredLength: UInt32? = nil
    ) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSIGPIPE: CInt = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSIGPIPE,
            socklen_t(MemoryLayout<CInt>.size)
        )
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(socketURL.path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < pathCapacity else {
            return nil
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: pathCapacity
            ) { rawPointer in
                for index in bytes.indices {
                    rawPointer[index] = CChar(bitPattern: bytes[index])
                }
                rawPointer[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var length = (declaredLength ?? UInt32(payload.count)).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        guard frame.withUnsafeBytes({
            guard let base = $0.baseAddress else { return false }
            return write(fd, base, frame.count) == frame.count
        }) else { return nil }

        var header = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size)
        let headerCount = read(fd, &header, header.count)
        guard headerCount == header.count else { return nil }
        let responseLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard responseLength <= UInt32(AgentTransportContract.maximumSerializedBytes) else {
            return nil
        }
        var response = Data(count: Int(responseLength))
        let responseCount = response.withUnsafeMutableBytes {
            read(fd, $0.baseAddress, Int(responseLength))
        }
        return responseCount == Int(responseLength) ? response : nil
    }
}
