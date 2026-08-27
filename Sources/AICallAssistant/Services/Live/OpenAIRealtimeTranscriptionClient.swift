import Foundation

enum RealtimeClientState: Equatable, Sendable {
    case idle
    case connecting
    case ready(expiresAt: Int64?)
    case failed(RealtimeConnectionFailure)
    case closed
}

enum RealtimeClientError: Error, Equatable {
    case readinessTimeout
    case connectionFailed(RealtimeConnectionFailure)
    case notReady
}

struct RealtimeClientConnection: Equatable, Sendable {
    let id: UInt64
    let expiresAt: Int64?
}

struct RealtimeConnectionFailure: Error, Equatable, Sendable {
    enum Reason: String, Codable, Equatable, Sendable {
        case authentication
        case forbidden
        case invalidConfiguration
        case quotaExceeded
        case rateLimited
        case server
        case network
        case protocolViolation
    }

    let reason: Reason
    let code: String
    let httpStatus: Int?
    let retryAfterSeconds: Double?

    init(
        reason: Reason,
        code: String? = nil,
        httpStatus: Int? = nil,
        retryAfterSeconds: Double? = nil
    ) {
        self.reason = reason
        self.code = code ?? Self.defaultCode(for: reason)
        self.httpStatus = httpStatus
        self.retryAfterSeconds = retryAfterSeconds
    }

    var diagnostic: RealtimeFailureDiagnostic {
        RealtimeFailureDiagnostic(code: code, reason: reason, httpStatus: httpStatus)
    }

    var isTerminal: Bool {
        switch reason {
        case .authentication, .forbidden, .invalidConfiguration, .quotaExceeded:
            return true
        case .rateLimited, .server, .network, .protocolViolation:
            return false
        }
    }

    private static func defaultCode(for reason: Reason) -> String {
        switch reason {
        case .authentication: return "authentication_failed"
        case .forbidden: return "permission_denied"
        case .invalidConfiguration: return "invalid_session_configuration"
        case .quotaExceeded: return "insufficient_quota"
        case .rateLimited: return "rate_limit_exceeded"
        case .server: return "server_error"
        case .network: return "transport"
        case .protocolViolation: return "protocol_violation"
        }
    }
}

enum RealtimeClientSignal: Equatable, Sendable {
    case server(connectionID: UInt64, RealtimeServerEvent)
    case connectionFailed(connectionID: UInt64, RealtimeConnectionFailure)
}

protocol RealtimeTranscriptionClientProtocol: Sendable {
    var signals: AsyncStream<RealtimeClientSignal> { get }
    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection
    func appendPCM16(_ data: Data) async throws
    func commit(eventID: String) async throws
    func disconnect() async
}

actor OpenAIRealtimeTranscriptionClient: RealtimeTranscriptionClientProtocol {
    private let transport: any RealtimeTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let signalsContinuation: AsyncStream<RealtimeClientSignal>.Continuation

    nonisolated let signals: AsyncStream<RealtimeClientSignal>

    private(set) var state: RealtimeClientState = .idle
    private var receiveTask: Task<Void, Never>?
    private var connectionSequence: UInt64 = 0
    private var activeConnectionID: UInt64?

    init(transport: any RealtimeTransport = URLSessionRealtimeTransport()) {
        self.transport = transport
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        let pair = AsyncStream<RealtimeClientSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        signals = pair.stream
        signalsContinuation = pair.continuation
    }

    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection {
        await disconnect()
        connectionSequence &+= 1
        let connectionID = connectionSequence
        activeConnectionID = connectionID
        state = .connecting
        do {
            try await transport.connect(apiKey: apiKey, modelID: configuration.modelID)
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(connectionID: connectionID)
            }
            try await send(.updateSession(configuration))
            return try await waitUntilReady(connectionID: connectionID)
        } catch {
            let failure = Self.classify(error)
            if activeConnectionID == connectionID {
                state = .failed(failure)
            }
            receiveTask?.cancel()
            receiveTask = nil
            await transport.close()
            throw RealtimeClientError.connectionFailed(failure)
        }
    }

    func appendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard case .ready = state else { throw RealtimeClientError.notReady }
        try await send(.appendAudio(data))
    }

    func commit(eventID: String) async throws {
        guard case .ready = state else { throw RealtimeClientError.notReady }
        try await send(.commit(eventID: eventID))
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        activeConnectionID = nil
        if state != .idle {
            state = .closed
        }
    }

    private func send(_ event: RealtimeClientEvent) async throws {
        let data = try encoder.encode(event)
        try await transport.send(data)
    }

    private func waitUntilReady(connectionID: UInt64) async throws -> RealtimeClientConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            guard activeConnectionID == connectionID else {
                throw RealtimeTransportError.disconnected
            }
            switch state {
            case let .ready(expiresAt):
                return RealtimeClientConnection(id: connectionID, expiresAt: expiresAt)
            case let .failed(failure):
                throw RealtimeClientError.connectionFailed(failure)
            case .closed:
                throw RealtimeTransportError.disconnected
            case .idle, .connecting:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw RealtimeClientError.readinessTimeout
    }

    private func receiveLoop(connectionID: UInt64) async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                let event = try decoder.decode(RealtimeServerEvent.self, from: data)

                guard activeConnectionID == connectionID else { return }

                switch event {
                case let .sessionUpdated(expiresAt):
                    state = .ready(expiresAt: expiresAt)
                case let .providerError(error):
                    let failure = Self.classify(error)
                    state = .failed(failure)
                    signalsContinuation.yield(
                        .server(connectionID: connectionID, event)
                    )
                    signalsContinuation.yield(
                        .connectionFailed(connectionID: connectionID, failure)
                    )
                    return
                default:
                    break
                }
                signalsContinuation.yield(.server(connectionID: connectionID, event))
            }
        } catch is CancellationError {
            // Explicit close is not a provider failure.
        } catch {
            guard !Task.isCancelled, activeConnectionID == connectionID else { return }
            let failure = Self.classify(error)
            state = .failed(failure)
            signalsContinuation.yield(
                .connectionFailed(connectionID: connectionID, failure)
            )
        }
    }

    private static func classify(_ error: Error) -> RealtimeConnectionFailure {
        if let clientError = error as? RealtimeClientError,
           case let .connectionFailed(failure) = clientError {
            return failure
        }
        if let clientError = error as? RealtimeClientError,
           clientError == .readinessTimeout {
            return RealtimeConnectionFailure(
                reason: .network,
                code: "handshake_timeout"
            )
        }
        if let transportError = error as? RealtimeTransportError {
            switch transportError {
            case let .httpStatus(statusCode, retryAfterSeconds):
                switch statusCode {
                case 401:
                    return RealtimeConnectionFailure(
                        reason: .authentication,
                        code: "http_401",
                        httpStatus: statusCode
                    )
                case 403:
                    return RealtimeConnectionFailure(
                        reason: .forbidden,
                        code: "http_403",
                        httpStatus: statusCode
                    )
                case 400, 404, 405, 422:
                    return RealtimeConnectionFailure(
                        reason: .invalidConfiguration,
                        code: "invalid_session_configuration",
                        httpStatus: statusCode
                    )
                case 429:
                    return RealtimeConnectionFailure(
                        reason: .rateLimited,
                        code: "http_429",
                        httpStatus: statusCode,
                        retryAfterSeconds: retryAfterSeconds
                    )
                case 500...599:
                    return RealtimeConnectionFailure(
                        reason: .server,
                        code: "server_error",
                        httpStatus: statusCode
                    )
                default:
                    return RealtimeConnectionFailure(
                        reason: .network,
                        code: "transport",
                        httpStatus: statusCode
                    )
                }
            case .unsupportedMessage:
                return RealtimeConnectionFailure(reason: .protocolViolation)
            case .invalidEndpoint:
                return RealtimeConnectionFailure(reason: .invalidConfiguration)
            case .disconnected:
                return RealtimeConnectionFailure(reason: .network)
            case .handshakeTimeout:
                return RealtimeConnectionFailure(
                    reason: .network,
                    code: "handshake_timeout"
                )
            }
        }
        if let providerError = error as? RealtimeProviderError {
            return classify(providerError)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return RealtimeConnectionFailure(reason: .authentication)
            case .noPermissionsToReadFile:
                return RealtimeConnectionFailure(reason: .forbidden)
            default:
                return RealtimeConnectionFailure(reason: .network)
            }
        }
        if error is DecodingError {
            return RealtimeConnectionFailure(reason: .protocolViolation)
        }
        return RealtimeConnectionFailure(reason: .network)
    }

    private static func classify(
        _ error: RealtimeProviderError
    ) -> RealtimeConnectionFailure {
        let code = (error.code ?? error.type ?? "").lowercased()
        if code.contains("insufficient_quota")
            || code.contains("quota_exceeded")
            || code.contains("billing_hard_limit") {
            return RealtimeConnectionFailure(
                reason: .quotaExceeded,
                code: "insufficient_quota",
                httpStatus: 429
            )
        }
        if code.contains("auth") || code.contains("api_key") || code == "401" {
            return RealtimeConnectionFailure(
                reason: .authentication,
                code: "http_401",
                httpStatus: 401
            )
        }
        if code.contains("permission") || code.contains("forbidden") || code == "403" {
            return RealtimeConnectionFailure(
                reason: .forbidden,
                code: "http_403",
                httpStatus: 403
            )
        }
        if code.contains("rate_limit") || code == "429" {
            return RealtimeConnectionFailure(
                reason: .rateLimited,
                code: "rate_limit_exceeded",
                httpStatus: 429
            )
        }
        if code.contains("model_not_found") || code.contains("model_access") {
            return RealtimeConnectionFailure(
                reason: .invalidConfiguration,
                code: "model_unavailable"
            )
        }
        if code.contains("invalid") || code.contains("unsupported") {
            return RealtimeConnectionFailure(
                reason: .invalidConfiguration,
                code: "invalid_session_configuration"
            )
        }
        if code.contains("server") || code.contains("internal") {
            return RealtimeConnectionFailure(reason: .server)
        }
        return RealtimeConnectionFailure(
            reason: .protocolViolation,
            code: "provider_rejected"
        )
    }
}
