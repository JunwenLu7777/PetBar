//
//  AgentEventSocket.swift
//  ThreadHelm
//
//  模块职责：提供 owner-only Unix-domain socket，用于本机 Agent hook
//  递交通用 AgentTransportEnvelope。该层只传归一化 envelope 与 ack，
//  不承载 prompt、reasoning、tool 参数、输出、路径或标题。
//

import Darwin
import Foundation

enum AgentEventSocketError: Error, Equatable {
    case invalidSocketPath
    case directoryCreationFailed
    case directoryPermissionFailed
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case alreadyRunning
    case notRunning
    case unsafeExistingPath
    case socketPermissionFailed
}

struct AgentEventSocketConfiguration: Equatable {
    let socketURL: URL
    let allowedUserID: uid_t

    init(socketURL: URL, allowedUserID: uid_t = geteuid()) {
        self.socketURL = socketURL
        self.allowedUserID = allowedUserID
    }
}

struct AgentEventSocketAcknowledgement: Codable, Equatable {
    let schemaVersion: Int
    let accepted: Bool

    static let acceptedData: Data = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(AgentEventSocketAcknowledgement(
            schemaVersion: AgentTransportContract.schemaVersion,
            accepted: true
        ))) ?? Data()
    }()
}

final class AgentEventSocketServer {
    typealias PeerValidator = (_ socket: CInt, _ expectedUID: uid_t) -> Bool
    typealias EnvelopeHandler = (_ envelope: AgentTransportEnvelope) -> Void

    private let configuration: AgentEventSocketConfiguration
    private let peerValidator: PeerValidator
    private let handler: EnvelopeHandler
    private let acceptQueue = DispatchQueue(label: "dev.threadhelm.agent-event-socket.accept")
    private let handlerQueue = DispatchQueue(
        label: "dev.threadhelm.agent-event-socket.handler",
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var listener: CInt = -1
    private var running = false

    init(
        configuration: AgentEventSocketConfiguration,
        peerValidator: @escaping PeerValidator = AgentEventSocketServer.defaultPeerValidator,
        handler: @escaping EnvelopeHandler
    ) {
        self.configuration = configuration
        self.peerValidator = peerValidator
        self.handler = handler
    }

    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { throw AgentEventSocketError.alreadyRunning }

        try AgentEventSocketFileSystem.prepareSocketDirectory(
            configuration.socketURL.deletingLastPathComponent()
        )
        try AgentEventSocketAddress.validate(path: configuration.socketURL.path)
        try AgentEventSocketFileSystem.removeStaleSocket(
            at: configuration.socketURL,
            ownedBy: geteuid()
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentEventSocketError.socketCreationFailed }
        AgentEventSocketOptions.disableSIGPIPE(on: fd)

        do {
            try AgentEventSocketAddress.withSockAddr(
                path: configuration.socketURL.path
            ) { pointer, length in
                guard bind(fd, pointer, length) == 0 else {
                    throw AgentEventSocketError.bindFailed
                }
            }
            guard chmod(configuration.socketURL.path, S_IRUSR | S_IWUSR) == 0,
                  AgentEventSocketFileSystem.socketIsOwnerOnly(
                      at: configuration.socketURL,
                      ownedBy: geteuid()
                  )
            else {
                throw AgentEventSocketError.socketPermissionFailed
            }
            guard listen(fd, 32) == 0 else {
                throw AgentEventSocketError.listenFailed
            }
        } catch {
            close(fd)
            unlink(configuration.socketURL.path)
            throw error
        }

        listener = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop(listener: fd)
        }
    }

    func stop() {
        stateLock.lock()
        let fd = listener
        listener = -1
        running = false
        stateLock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        AgentEventSocketFileSystem.removeOwnedSocketIfPresent(
            at: configuration.socketURL,
            ownedBy: geteuid()
        )
    }

    deinit {
        stop()
    }

    private func acceptLoop(listener: CInt) {
        while isRunning(listener: listener) {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR {
                    continue
                }
                break
            }
            AgentEventSocketOptions.disableSIGPIPE(on: client)
            handlerQueue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handle(client: client)
            }
        }
    }

    private func isRunning(listener: CInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && self.listener == listener
    }

    private func handle(client: CInt) {
        defer { close(client) }
        guard peerValidator(client, configuration.allowedUserID) else {
            return
        }
        let deadline = AgentEventSocketDeadline(
            seconds: AgentTransportContract.synchronousTimeout
        )
        guard let payload = AgentEventSocketFraming.readFrame(
            from: client,
            deadline: deadline
        ), payload.count <= AgentTransportContract.maximumSerializedBytes,
              let decoded = try? JSONDecoder().decode(
                  AgentTransportEnvelope.self,
                  from: payload
              ), let envelope = AgentEventSocketEnvelopeValidator.validate(decoded)
        else {
            return
        }
        handler(envelope)
        _ = AgentEventSocketFraming.writeFrame(
            AgentEventSocketAcknowledgement.acceptedData,
            to: client,
            deadline: deadline
        )
    }

    static func defaultPeerValidator(socket: CInt, expectedUID: uid_t) -> Bool {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(socket, &effectiveUID, &effectiveGID) == 0 else {
            return false
        }
        return effectiveUID == expectedUID
    }
}

enum AgentEventSocketClient {
    static func send(
        _ envelope: AgentTransportEnvelope,
        to socketURL: URL,
        timeout: TimeInterval = AgentTransportContract.synchronousTimeout
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

        guard encoding.data.count <= AgentTransportContract.maximumSerializedBytes else {
            return AgentTransportAttempt(
                disposition: .encodingFailed,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }

        guard timeout > 0 else {
            return AgentTransportAttempt(
                disposition: .timedOut,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let response = sendEncoded(
            encoding.data,
            to: socketURL,
            timeout: timeout
        )
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000_000
        guard let response else {
            return AgentTransportAttempt(
                disposition: elapsed
                    >= timeout * 0.80
                    ? .timedOut
                    : .offline,
                vendorResponse: Data(),
                usedMetadataOnlyEnvelope: encoding.wasReducedToMetadata
            )
        }
        guard let acknowledgement = try? JSONDecoder().decode(
            AgentEventSocketAcknowledgement.self,
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

    static func sendEncoded(
        _ data: Data,
        to socketURL: URL,
        timeout: TimeInterval = AgentTransportContract.synchronousTimeout
    ) -> Data? {
        guard data.count <= AgentTransportContract.maximumSerializedBytes else {
            return nil
        }
        guard timeout > 0 else { return nil }
        let deadline = AgentEventSocketDeadline(
            seconds: timeout
        )
        guard AgentEventSocketFileSystem.socketIsOwnerOnly(
            at: socketURL,
            ownedBy: geteuid()
        ) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        AgentEventSocketOptions.disableSIGPIPE(on: fd)
        defer { close(fd) }

        guard AgentEventSocketConnector.connect(
            fd: fd,
            path: socketURL.path,
            deadline: deadline
        ) else {
            return nil
        }
        guard AgentEventSocketFraming.writeFrame(data, to: fd, deadline: deadline) else {
            return nil
        }
        return AgentEventSocketFraming.readFrame(from: fd, deadline: deadline)
    }
}

private enum AgentEventSocketFileSystem {
    static func prepareSocketDirectory(_ directoryURL: URL) throws {
        var isDirectory: ObjCBool = false
        let existed = FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        )
        if !existed {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AgentEventSocketError.directoryCreationFailed
            }
            guard chmod(directoryURL.path, S_IRWXU) == 0 else {
                throw AgentEventSocketError.directoryPermissionFailed
            }
        } else if !isDirectory.boolValue {
            throw AgentEventSocketError.directoryCreationFailed
        }
        var statBuffer = stat()
        guard lstat(directoryURL.path, &statBuffer) == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFDIR,
              statBuffer.st_uid == geteuid(),
              (statBuffer.st_mode & S_IRWXU) == S_IRWXU,
              (statBuffer.st_mode & S_IRWXG) == 0,
              (statBuffer.st_mode & S_IRWXO) == 0
        else {
            throw AgentEventSocketError.directoryPermissionFailed
        }
    }

    static func removeStaleSocket(at url: URL, ownedBy userID: uid_t) throws {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            if errno == ENOENT { return }
            throw AgentEventSocketError.unsafeExistingPath
        }
        guard statBuffer.st_uid == userID,
              (statBuffer.st_mode & S_IFMT) == S_IFSOCK,
              unlink(url.path) == 0
        else {
            throw AgentEventSocketError.unsafeExistingPath
        }
    }

    static func socketIsOwnerOnly(at url: URL, ownedBy userID: uid_t) -> Bool {
        var statBuffer = stat()
        return lstat(url.path, &statBuffer) == 0
            && statBuffer.st_uid == userID
            && (statBuffer.st_mode & S_IFMT) == S_IFSOCK
            && (statBuffer.st_mode & S_IRWXG) == 0
            && (statBuffer.st_mode & S_IRWXO) == 0
            && (statBuffer.st_mode & (S_IRUSR | S_IWUSR))
                == (S_IRUSR | S_IWUSR)
    }

    static func removeOwnedSocketIfPresent(at url: URL, ownedBy userID: uid_t) {
        guard socketIsOwnerOnly(at: url, ownedBy: userID) else { return }
        unlink(url.path)
    }
}

private enum AgentEventSocketOptions {
    static func disableSIGPIPE(on fd: CInt) {
        var value: CInt = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<CInt>.size)
        )
    }
}

private enum AgentEventSocketAddress {
    static func validate(path: String) throws {
        guard !path.isEmpty,
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        else {
            throw AgentEventSocketError.invalidSocketPath
        }
    }

    static func withSockAddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        try validate(path: path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
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
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

private enum AgentEventSocketConnector {
    static func connect(
        fd: CInt,
        path: String,
        deadline: AgentEventSocketDeadline
    ) -> Bool {
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0
        else { return false }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        let connected: CInt
        do {
            connected = try AgentEventSocketAddress.withSockAddr(path: path) {
                pointer, length in
                Darwin.connect(fd, pointer, length)
            }
        } catch {
            return false
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS || errno == EAGAIN,
              AgentEventSocketFraming.waitFor(
                  fd: fd,
                  write: true,
                  deadline: deadline
              )
        else { return false }

        var socketError: CInt = 0
        var errorLength = socklen_t(MemoryLayout<CInt>.size)
        guard getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &errorLength
        ) == 0 else { return false }
        return socketError == 0
    }
}

private enum AgentEventSocketEnvelopeValidator {
    static func validate(
        _ candidate: AgentTransportEnvelope
    ) -> AgentTransportEnvelope? {
        guard candidate.schemaVersion == AgentTransportContract.schemaVersion,
              [.cursor, .zcode, .omp].contains(candidate.agentID)
        else { return nil }
        let canonical = AgentTransportEnvelope(
            agentID: candidate.agentID,
            adapterVersion: candidate.adapterVersion,
            nativeSessionCandidate: candidate.nativeSessionCandidate,
            eventID: candidate.eventID,
            sequence: candidate.sequence,
            eventType: candidate.eventType,
            monotonicNanoseconds: candidate.monotonicNanoseconds,
            redactedPayload: candidate.redactedPayload
        )
        guard let encoding = try? AgentTransportEncoder.encode(canonical),
              !encoding.wasReducedToMetadata,
              let validated = try? JSONDecoder().decode(
                  AgentTransportEnvelope.self,
                  from: encoding.data
              )
        else { return nil }
        return validated
    }
}

private struct AgentEventSocketDeadline {
    private let end: UInt64

    init(seconds: TimeInterval) {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        end = DispatchTime.now().uptimeNanoseconds + nanoseconds
    }

    var remainingMicroseconds: Int {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return 0 }
        return Int((end - now) / 1_000)
    }
}

private enum AgentEventSocketFraming {
    static func writeFrame(
        _ payload: Data,
        to fd: CInt,
        deadline: AgentEventSocketDeadline
    ) -> Bool {
        guard payload.count <= AgentTransportContract.maximumSerializedBytes else {
            return false
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return writeAll(frame, to: fd, deadline: deadline)
    }

    static func readFrame(
        from fd: CInt,
        deadline: AgentEventSocketDeadline
    ) -> Data? {
        guard let header = readExact(
            byteCount: MemoryLayout<UInt32>.size,
            from: fd,
            deadline: deadline
        ), header.count == MemoryLayout<UInt32>.size
        else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(AgentTransportContract.maximumSerializedBytes) else {
            return nil
        }
        return readExact(byteCount: Int(length), from: fd, deadline: deadline)
    }

    private static func writeAll(
        _ data: Data,
        to fd: CInt,
        deadline: AgentEventSocketDeadline
    ) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            while offset < data.count {
                guard waitFor(fd: fd, write: true, deadline: deadline) else {
                    return false
                }
                let written = write(
                    fd,
                    base.advanced(by: offset),
                    data.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readExact(
        byteCount: Int,
        from fd: CInt,
        deadline: AgentEventSocketDeadline
    ) -> Data? {
        var data = Data(count: byteCount)
        var offset = 0
        let success = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            while offset < byteCount {
                guard waitFor(fd: fd, write: false, deadline: deadline) else {
                    return false
                }
                let count = read(
                    fd,
                    base.advanced(by: offset),
                    byteCount - offset
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return success ? data : nil
    }

    fileprivate static func waitFor(
        fd: CInt,
        write: Bool,
        deadline: AgentEventSocketDeadline
    ) -> Bool {
        var readSet = fd_set()
        var writeSet = fd_set()
        fdZero(&readSet)
        fdZero(&writeSet)
        if write {
            fdSet(fd, &writeSet)
        } else {
            fdSet(fd, &readSet)
        }
        var timeout = timeval(
            tv_sec: deadline.remainingMicroseconds / 1_000_000,
            tv_usec: Int32(deadline.remainingMicroseconds % 1_000_000)
        )
        if timeout.tv_sec == 0 && timeout.tv_usec == 0 {
            return false
        }
        let result: CInt
        if write {
            result = select(fd + 1, nil, &writeSet, nil, &timeout)
        } else {
            result = select(fd + 1, &readSet, nil, nil, &timeout)
        }
        if result == -1 && errno == EINTR {
            return waitFor(fd: fd, write: write, deadline: deadline)
        }
        return result > 0
    }
}

private func fdZero(_ set: inout fd_set) {
    memset(&set, 0, MemoryLayout<fd_set>.size)
}

private func fdSet(_ fd: CInt, _ set: inout fd_set) {
    let bitsPerInt = MemoryLayout<Int32>.size * 8
    let intOffset = Int(fd) / bitsPerInt
    let bitOffset = Int(fd) % bitsPerInt
    let mask = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
    let bitsetCapacity = MemoryLayout.size(ofValue: set.fds_bits)
        / MemoryLayout<Int32>.size
    guard intOffset >= 0, intOffset < bitsetCapacity else { return }
    withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
        pointer.withMemoryRebound(
            to: Int32.self,
            capacity: bitsetCapacity
        ) {
            $0[intOffset] |= mask
        }
    }
}
