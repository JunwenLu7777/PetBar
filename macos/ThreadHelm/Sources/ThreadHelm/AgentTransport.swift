//
//  AgentTransport.swift
//  ThreadHelm
//
//  模块职责：定义 64 KiB、250 ms、默认放行的本地 Agent 事件传输契约。
//

import Foundation

enum AgentTransportContract {
    static let schemaVersion = 1
    static let maximumSerializedBytes = 64 * 1_024
    static let synchronousTimeout: TimeInterval = 0.25
    static let maximumQueuedEvents = 256
    static let maximumQueuedBytes = 1_024 * 1_024
}

struct AgentTransportEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let agentID: AgentID
    let adapterVersion: String
    let nativeSessionCandidate: String?
    let eventID: String
    let sequence: Int?
    let eventType: String
    let monotonicNanoseconds: UInt64
    let redactedPayload: [String: String]
    fileprivate var requiresMetadataOnly = false
    fileprivate var originalPayloadByteCount = 0

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case agentID
        case adapterVersion
        case nativeSessionCandidate
        case eventID
        case sequence
        case eventType
        case monotonicNanoseconds
        case redactedPayload
    }

    init(
        agentID: AgentID,
        adapterVersion: String,
        nativeSessionCandidate: String?,
        eventID: String,
        sequence: Int?,
        eventType: String,
        monotonicNanoseconds: UInt64,
        redactedPayload: [String: String]
    ) {
        schemaVersion = AgentTransportContract.schemaVersion
        self.agentID = agentID
        self.adapterVersion = boundedTransportToken(
            adapterVersion,
            limit: 96,
            fallback: "unknown"
        )
        self.nativeSessionCandidate = nativeSessionCandidate.flatMap {
            optionalTransportToken($0, limit: 192)
        }
        self.eventID = boundedTransportToken(
            eventID,
            limit: 192,
            fallback: "unknown-event"
        )
        self.sequence = sequence
        self.eventType = boundedTransportToken(
            eventType,
            limit: 96,
            fallback: "unknown"
        )
        self.monotonicNanoseconds = monotonicNanoseconds
        originalPayloadByteCount = redactedPayload.reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count
        }
        var rejectedValue = false
        self.redactedPayload = redactedPayload.reduce(into: [:]) { result, item in
            guard let normalized = AgentTransportEnvelope.normalizedPayloadValue(
                item.value,
                for: item.key
            ) else {
                rejectedValue = true
                return
            }
            result[item.key] = normalized
        }
        requiresMetadataOnly = originalPayloadByteCount
            > AgentTransportContract.maximumSerializedBytes
            || rejectedValue
    }

    private static func normalizedPayloadValue(
        _ value: String,
        for key: String
    ) -> String? {
        let allowed: Set<String>
        switch key {
        case "state":
            allowed = Set(ExecutionState.transportAllowedRawValues)
        case "attentionReason":
            allowed = Set(AttentionReason.transportAllowedRawValues)
        case "actionability":
            allowed = Set(Actionability.transportAllowedRawValues)
        case "evidenceQuality":
            allowed = Set(EvidenceQuality.transportAllowedRawValues)
        case "freshness":
            allowed = ["fresh", "stale", "unknown"]
        case "status":
            allowed = [
                "ok", "degraded", "offline", "disabled", "needsRepair",
                "unsupportedVersion", "unknown",
            ]
        case "errorClass":
            guard value.count <= 64,
                  value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression)
                      != nil
            else { return nil }
            return value
        case "durationBucket":
            allowed = ["lt250ms", "250ms-1s", "1s-3s", "3s+"]
        case "payloadDisposition":
            allowed = ["metadataOnly"]
        case "payloadSizeBucket":
            allowed = ["64-128KiB", "128-512KiB", "512KiB+"]
        default:
            return nil
        }
        return allowed.contains(value) ? value : nil
    }

    func metadataOnly(originalByteCount: Int) -> AgentTransportEnvelope {
        AgentTransportEnvelope(
            agentID: agentID,
            adapterVersion: adapterVersion,
            nativeSessionCandidate: nativeSessionCandidate,
            eventID: eventID,
            sequence: sequence,
            eventType: eventType,
            monotonicNanoseconds: monotonicNanoseconds,
            redactedPayload: [
                "payloadDisposition": "metadataOnly",
                "payloadSizeBucket": transportSizeBucket(originalByteCount),
            ]
        )
    }
}

struct AgentTransportEncoding: Equatable {
    let data: Data
    let wasReducedToMetadata: Bool
}

enum AgentTransportEncodingError: Error {
    case metadataExceedsLimit
}

enum AgentTransportEncoder {
    static func encode(
        _ envelope: AgentTransportEnvelope
    ) throws -> AgentTransportEncoding {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if envelope.requiresMetadataOnly {
            let metadata = try encoder.encode(
                envelope.metadataOnly(
                    originalByteCount: envelope.originalPayloadByteCount
                )
            )
            guard metadata.count <= AgentTransportContract.maximumSerializedBytes else {
                throw AgentTransportEncodingError.metadataExceedsLimit
            }
            return AgentTransportEncoding(
                data: metadata,
                wasReducedToMetadata: true
            )
        }
        let encoded = try encoder.encode(envelope)
        guard encoded.count > AgentTransportContract.maximumSerializedBytes else {
            return AgentTransportEncoding(
                data: encoded,
                wasReducedToMetadata: false
            )
        }
        let metadata = try encoder.encode(
            envelope.metadataOnly(originalByteCount: encoded.count)
        )
        guard metadata.count <= AgentTransportContract.maximumSerializedBytes else {
            throw AgentTransportEncodingError.metadataExceedsLimit
        }
        return AgentTransportEncoding(
            data: metadata,
            wasReducedToMetadata: true
        )
    }
}

enum AgentTransportDisposition: String, Equatable {
    case delivered
    case offline
    case timedOut
    case malformedResponse
    case encodingFailed
}

struct AgentTransportAttempt: Equatable {
    let disposition: AgentTransportDisposition
    let vendorResponse: Data
    let usedMetadataOnlyEnvelope: Bool
}

private struct AgentTransportAcknowledgement: Codable {
    let schemaVersion: Int
    let accepted: Bool
}

private final class AgentTransportResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Data?

    func store(_ value: Data?) {
        lock.lock()
        response = value
        lock.unlock()
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

enum AgentHookTransport {
    static let validAcknowledgement: Data = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(AgentTransportAcknowledgement(
            schemaVersion: AgentTransportContract.schemaVersion,
            accepted: true
        ))) ?? Data()
    }()

    static func send(
        _ envelope: AgentTransportEnvelope,
        receiver: @escaping (Data) -> Data?
    ) -> AgentTransportAttempt {
        let encoding: AgentTransportEncoding
        do {
            encoding = try AgentTransportEncoder.encode(envelope)
        } catch {
            return AgentTransportAttempt(
                disposition: .encodingFailed,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: false
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = AgentTransportResponseBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.store(receiver(encoding.data))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + AgentTransportContract.synchronousTimeout)
            == .success
        else {
            return AgentTransportAttempt(
                disposition: .timedOut,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }
        guard let response = box.load() else {
            return AgentTransportAttempt(
                disposition: .offline,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }
        guard let acknowledgement = try? JSONDecoder().decode(
            AgentTransportAcknowledgement.self,
            from: response
        ), acknowledgement.schemaVersion == AgentTransportContract.schemaVersion,
              acknowledgement.accepted
        else {
            return AgentTransportAttempt(
                disposition: .malformedResponse,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }
        return AgentTransportAttempt(
            disposition: .delivered,
            vendorResponse: Data(),
            usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
        )
    }
}

private func boundedTransportToken(
    _ value: String,
    limit: Int,
    fallback: String
) -> String {
    optionalTransportToken(value, limit: limit) ?? fallback
}

private func optionalTransportToken(_ value: String, limit: Int) -> String? {
    guard !value.isEmpty, value.count <= limit,
          value.range(
              of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
              options: .regularExpression
          ) != nil
    else { return nil }
    return value
}

private func transportSizeBucket(_ byteCount: Int) -> String {
    switch byteCount {
    case ..<(128 * 1_024):
        return "64-128KiB"
    case ..<(512 * 1_024):
        return "128-512KiB"
    default:
        return "512KiB+"
    }
}
