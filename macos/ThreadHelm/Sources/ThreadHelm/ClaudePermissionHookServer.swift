import Foundation
import Network

/// 一条按路径区分的审批线路。Claude 与 Codex 共用同一个监听端口，
/// 但各有各的令牌来源与线协议：令牌不共享，任一方的配置泄漏都不会
/// 让攻击者能向另一方伪造裁决请求。
struct PermissionHookRoute {
    let agentID: AgentID
    let path: String
    let expectedToken: () -> String?
    let decode: (Data) throws -> ClaudePermissionPrompt
    let encode: (ClaudePermissionUserDecision, ClaudePermissionPrompt) -> Data?

    static func claude(
        token: @escaping () -> String? = { ClaudeHookConfiguration.authenticationToken() }
    ) -> PermissionHookRoute {
        PermissionHookRoute(
            agentID: .claudeCode,
            path: ClaudeHookConstants.path,
            expectedToken: token,
            decode: { try ClaudePermissionProtocol.decodePrompt(from: $0) },
            encode: { ClaudePermissionProtocol.responseBody(for: $0, prompt: $1) }
        )
    }

    static func codex(
        token: @escaping () -> String? = { CodexHookConfiguration.authenticationToken() }
    ) -> PermissionHookRoute {
        PermissionHookRoute(
            agentID: .codex,
            path: CodexHookConstants.path,
            expectedToken: token,
            decode: { try CodexPermissionProtocol.decodePrompt(from: $0) },
            encode: { decision, _ in
                CodexPermissionProtocol.responseBody(for: decision)
            }
        )
    }

    /// ZCode 的 hook 负载与裁决格式与 Claude 逐字段同形，编解码直接复用。
    /// 差别只在于谁在问、令牌从哪来。
    static func zcode(
        token: @escaping () -> String? = { ZCodePermissionTokenStore.token() }
    ) -> PermissionHookRoute {
        PermissionHookRoute(
            agentID: .zcode,
            path: ZCodePermissionHookConstants.path,
            expectedToken: token,
            decode: {
                try ClaudePermissionProtocol.decodePrompt(
                    from: $0,
                    agentID: .zcode
                )
            },
            encode: { ClaudePermissionProtocol.responseBody(for: $0, prompt: $1) }
        )
    }

    /// OMP 的扩展自己把 tool_call 事件整形成 Claude 那套字段名再发过来，
    /// 所以入向复用同一个解析器；出向必须换成 OMP 的 {block, reason}。
    static func omp(
        token: @escaping () -> String? = { OMPPermissionTokenStore.token() }
    ) -> PermissionHookRoute {
        PermissionHookRoute(
            agentID: .omp,
            path: OMPPermissionHookConstants.path,
            expectedToken: token,
            decode: {
                try ClaudePermissionProtocol.decodePrompt(
                    from: $0,
                    agentID: .omp
                )
            },
            encode: { decision, _ in
                OMPPermissionProtocol.responseBody(for: decision)
            }
        )
    }
}

final class ClaudePermissionHookServer {
    typealias PromptHandler = (
        ClaudePermissionPrompt,
        @escaping (ClaudePermissionUserDecision) -> Void
    ) -> Void

    enum State: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onPrompt: PromptHandler?
    var onRequestExpired: ((UUID) -> Void)?

    private let routes: [String: PermissionHookRoute]
    /// 只有服务端能证明闸门真的连通了：hook 被厂商拉起、找到了令牌、
    /// 请求送达并解析成功。hook 进程自己记不了这件事——它连不上的时候
    /// 恰恰就是最需要如实记录「没连通」的时候。
    private let liveness: PermissionGateLivenessStore?
    private let queue = DispatchQueue(
        label: "dev.threadhelm.claude-permission-hook",
        qos: .userInitiated
    )
    private var listener: NWListener?
    private var pendingRequests: [UUID: PendingRequest] = [:]
    private(set) var state: State = .stopped

    init(
        routes: [PermissionHookRoute] = [.claude(), .codex(), .zcode(), .omp()],
        liveness: PermissionGateLivenessStore? = nil
    ) {
        self.routes = Dictionary(
            routes.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.liveness = liveness
    }

    convenience init(expectedAuthenticationToken: String?) {
        self.init(routes: [
            .claude(token: { expectedAuthenticationToken }),
        ])
    }

    static func isAuthenticated(
        headers: [String: String],
        expectedToken: String?
    ) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty,
              let actualToken = headers[ClaudeHookConstants.authenticationHeader.lowercased()]
        else { return false }
        return constantTimeEquals(actualToken, expectedToken)
    }

    static func canAcceptRequest(pendingCount: Int) -> Bool {
        pendingCount < ClaudeHookConstants.maximumPendingRequests
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }

    func start() throws {
        guard listener == nil else { return }

        guard let port = NWEndpoint.Port(rawValue: ClaudeHookConstants.port) else {
            throw NSError(
                domain: "ThreadHelmClaudeHook",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无效的 Hook 端口"]
            )
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(ClaudeHookConstants.host),
            port: port
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        updateState(.starting)

        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            guard let self, let listener, self.listener === listener else { return }
            switch newState {
            case .ready:
                self.updateState(.ready)
            case .failed(let error):
                self.updateState(.failed(error.localizedDescription))
                self.stop()
            case .cancelled:
                self.updateState(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            let pending = Array(self.pendingRequests.values)
            self.pendingRequests.removeAll()
            pending.forEach { request in
                request.timeoutWorkItem?.cancel()
                request.connection.cancel()
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestExpired?(request.prompt.requestID)
                }
            }
            self.updateState(.stopped)
        }
    }

    private func accept(_ connection: NWConnection) {
        let reader = HTTPRequestReader(connection: connection)
        connection.stateUpdateHandler = { [weak reader] newState in
            switch newState {
            case .failed, .cancelled:
                reader?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        reader.read { [weak self, reader] result in
            _ = reader
            guard let self else {
                connection.cancel()
                return
            }
            switch result {
            case .success(let request):
                self.handle(request, connection: connection)
            case .failure:
                self.sendHTTPResponse(
                    status: 400,
                    reason: "Bad Request",
                    body: Data(),
                    connection: connection
                )
            }
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        guard request.method == "POST",
              let route = routes[request.path]
        else {
            sendHTTPResponse(
                status: 404,
                reason: "Not Found",
                body: Data(),
                connection: connection
            )
            return
        }

        guard Self.isAuthenticated(
            headers: request.headers,
            expectedToken: route.expectedToken()
        ) else {
            sendHTTPResponse(
                status: 403,
                reason: "Forbidden",
                body: Data(),
                connection: connection
            )
            return
        }

        guard Self.canAcceptRequest(pendingCount: pendingRequests.count) else {
            sendHTTPResponse(
                status: 503,
                reason: "Service Unavailable",
                body: Data(),
                connection: connection
            )
            return
        }

        let prompt: ClaudePermissionPrompt
        do {
            prompt = try route.decode(request.body)
        } catch {
            sendNoDecision(connection: connection)
            return
        }

        // 记在解码成功之后：能解析出一个提示，才说明这条链路真的通了，
        // 而不是端口上碰巧有人在敲。
        liveness?.recordRequest(agentID: route.agentID)

        let pending = PendingRequest(
            prompt: prompt,
            route: route,
            connection: connection
        )
        let timeout = DispatchWorkItem { [weak self] in
            self?.expire(requestID: prompt.requestID)
        }
        pending.timeoutWorkItem = timeout
        pendingRequests[prompt.requestID] = pending
        watchForClientDisconnect(
            requestID: prompt.requestID,
            connection: connection
        )
        queue.asyncAfter(
            deadline: .now() + ClaudeHookConstants.requestTimeoutSeconds,
            execute: timeout
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let handler = self.onPrompt else {
                self.resolve(
                    requestID: prompt.requestID,
                    decision: .nativeFallback
                )
                return
            }
            handler(prompt) { [weak self] decision in
                self?.resolve(requestID: prompt.requestID, decision: decision)
            }
        }
    }

    private func resolve(
        requestID: UUID,
        decision: ClaudePermissionUserDecision
    ) {
        queue.async { [weak self] in
            guard let self,
                  let pending = self.pendingRequests.removeValue(forKey: requestID)
            else { return }
            pending.timeoutWorkItem?.cancel()
            if let body = pending.route.encode(decision, pending.prompt) {
                self.liveness?.recordDecision(agentID: pending.route.agentID)
                self.sendHTTPResponse(
                    status: 200,
                    reason: "OK",
                    body: body,
                    contentType: "application/json",
                    connection: pending.connection
                )
            } else {
                self.sendNoDecision(connection: pending.connection)
            }
        }
    }

    private func expire(requestID: UUID) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutWorkItem?.cancel()
        sendNoDecision(connection: pending.connection)
        DispatchQueue.main.async { [weak self] in
            self?.onRequestExpired?(requestID)
        }
    }

    private func watchForClientDisconnect(
        requestID: UUID,
        connection: NWConnection
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.removeDisconnectedRequest(
                    requestID: requestID,
                    connection: connection
                )
                return
            }
            if data != nil {
                self.watchForClientDisconnect(
                    requestID: requestID,
                    connection: connection
                )
            }
        }
    }

    private func removeDisconnectedRequest(
        requestID: UUID,
        connection: NWConnection
    ) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutWorkItem?.cancel()
        connection.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.onRequestExpired?(requestID)
        }
    }

    private func sendNoDecision(connection: NWConnection) {
        sendHTTPResponse(
            status: 204,
            reason: "No Content",
            body: Data(),
            connection: connection
        )
    }

    private func sendHTTPResponse(
        status: Int,
        reason: String,
        body: Data,
        contentType: String? = nil,
        connection: NWConnection
    ) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "X-ThreadHelm-Hook: claude-permission-v1\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func updateState(_ nextState: State) {
        state = nextState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(nextState)
        }
    }
}

private final class PendingRequest {
    let prompt: ClaudePermissionPrompt
    /// 记住来路：裁决必须按提问方的线协议编码，而请求挂起期间
    /// 路由表本身可能已经变了。
    let route: PermissionHookRoute
    let connection: NWConnection
    var timeoutWorkItem: DispatchWorkItem?

    init(
        prompt: ClaudePermissionPrompt,
        route: PermissionHookRoute,
        connection: NWConnection
    ) {
        self.prompt = prompt
        self.route = route
        self.connection = connection
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum HTTPRequestReaderError: Error {
    case disconnected
    case oversized
    case malformed
}

private final class HTTPRequestReader {
    private let connection: NWConnection
    private var buffer = Data()
    private var completion: ((Result<HTTPRequest, Error>) -> Void)?
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func read(completion: @escaping (Result<HTTPRequest, Error>) -> Void) {
        self.completion = completion
        receiveNextChunk()
    }

    func cancel() {
        finish(.failure(HTTPRequestReaderError.disconnected))
    }

    private func receiveNextChunk() {
        guard !finished else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > ClaudeHookConstants.maximumBodyBytes + 16 * 1_024 {
                    self.finish(.failure(HTTPRequestReaderError.oversized))
                    return
                }
                if let request = self.parseIfComplete() {
                    self.finish(.success(request))
                    return
                }
            }
            if error != nil || isComplete {
                self.finish(.failure(HTTPRequestReaderError.disconnected))
                return
            }
            self.receiveNextChunk()
        }
    }

    private func parseIfComplete() -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: delimiter) else { return nil }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            finish(.failure(HTTPRequestReaderError.malformed))
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            finish(.failure(HTTPRequestReaderError.malformed))
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else {
            finish(.failure(HTTPRequestReaderError.malformed))
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        guard let contentLengthText = headers["content-length"],
              let contentLength = Int(contentLengthText),
              contentLength >= 0,
              contentLength <= ClaudeHookConstants.maximumBodyBytes
        else {
            finish(.failure(HTTPRequestReaderError.malformed))
            return nil
        }

        let bodyStart = headerRange.upperBound
        let availableBodyBytes = buffer.count - bodyStart
        guard availableBodyBytes >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func finish(_ result: Result<HTTPRequest, Error>) {
        guard !finished else { return }
        finished = true
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}
