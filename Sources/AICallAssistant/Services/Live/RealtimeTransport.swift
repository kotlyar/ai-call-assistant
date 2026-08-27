import Foundation

protocol RealtimeTransport: Sendable {
    func connect(apiKey: String, modelID: String) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

enum RealtimeTransportError: LocalizedError, Equatable {
    case invalidEndpoint
    case disconnected
    case unsupportedMessage
    case handshakeTimeout
    case httpStatus(Int, retryAfterSeconds: Double?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Некорректный адрес Realtime API."
        case .disconnected:
            return "Соединение с Realtime API закрыто."
        case .unsupportedMessage:
            return "Realtime API вернул неподдерживаемое сообщение."
        case .handshakeTimeout:
            return "Realtime API не подтвердил открытие WebSocket вовремя."
        case let .httpStatus(statusCode, _):
            return "Realtime API отклонил WebSocket-подключение (HTTP \(statusCode))."
        }
    }
}

actor URLSessionRealtimeTransport: RealtimeTransport {
    private static let defaultHandshakeTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let session: URLSession
    private let endpoint: URL
    private let handshakeTimeoutNanoseconds: UInt64
    private let openGate: WebSocketOpenGate
    private let sessionDelegate: RealtimeWebSocketDelegate
    private var task: URLSessionWebSocketTask?

    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime")!,
        handshakeTimeoutNanoseconds: UInt64 = defaultHandshakeTimeoutNanoseconds
    ) {
        let openGate = WebSocketOpenGate()
        let sessionDelegate = RealtimeWebSocketDelegate(openGate: openGate)
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        self.endpoint = endpoint
        self.handshakeTimeoutNanoseconds = handshakeTimeoutNanoseconds
        self.openGate = openGate
        self.sessionDelegate = sessionDelegate
    }

    func connect(apiKey: String, modelID: String) async throws {
        await close()

        // A transcription model is selected by `session.update`. The WebSocket
        // itself must be opened in transcription mode; passing that model as the
        // connection's `model` query creates a realtime conversation session (or
        // is rejected as an invalid connection model).
        let url = try Self.transcriptionEndpoint(from: endpoint)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        openGate.begin(taskIdentifier: task.taskIdentifier)
        task.resume()

        do {
            try await waitUntilOpen(taskIdentifier: task.taskIdentifier)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            openGate.remove(taskIdentifier: task.taskIdentifier)
            throw Self.classifiedTransportError(for: task, underlying: error)
        }
        openGate.remove(taskIdentifier: task.taskIdentifier)
    }

    nonisolated static func transcriptionEndpoint(from endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RealtimeTransportError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "model" || $0.name == "intent" }
        queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RealtimeTransportError.invalidEndpoint
        }
        return url
    }

    func send(_ data: Data) async throws {
        guard let task else { throw RealtimeTransportError.disconnected }
        do {
            try await task.send(try Self.textMessage(for: data))
        } catch {
            throw Self.classifiedTransportError(for: task, underlying: error)
        }
    }

    func receive() async throws -> Data {
        guard let task else { throw RealtimeTransportError.disconnected }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw Self.classifiedTransportError(for: task, underlying: error)
        }
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            guard let data = string.data(using: .utf8) else {
                throw RealtimeTransportError.unsupportedMessage
            }
            return data
        @unknown default:
            throw RealtimeTransportError.unsupportedMessage
        }
    }

    func close() async {
        if let task {
            openGate.cancel(
                taskIdentifier: task.taskIdentifier,
                error: CancellationError()
            )
            task.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
    }

    nonisolated static func textMessage(
        for data: Data
    ) throws -> URLSessionWebSocketTask.Message {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeTransportError.unsupportedMessage
        }
        return .string(text)
    }

    private func waitUntilOpen(taskIdentifier: Int) async throws {
        let openGate = self.openGate
        let timeout = handshakeTimeoutNanoseconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await openGate.wait(taskIdentifier: taskIdentifier)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw RealtimeTransportError.handshakeTimeout
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RealtimeTransportError.disconnected
            }
            return result
        }
    }

    private static func classifiedTransportError(
        for task: URLSessionWebSocketTask,
        underlying: Error
    ) -> Error {
        guard let response = task.response as? HTTPURLResponse else {
            return underlying
        }
        guard response.statusCode != 101,
              !(200...299).contains(response.statusCode) else {
            return underlying
        }
        return RealtimeTransportError.httpStatus(
            response.statusCode,
            retryAfterSeconds: retryAfterSeconds(from: response)
        )
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Double? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(raw), seconds >= 0 {
            return seconds
        }
        guard let date = HTTPDateParser.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

private final class RealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    private let openGate: WebSocketOpenGate

    init(openGate: WebSocketOpenGate) {
        self.openGate = openGate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        openGate.opened(taskIdentifier: webSocketTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        openGate.cancel(taskIdentifier: task.taskIdentifier, error: error)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        openGate.cancel(
            taskIdentifier: webSocketTask.taskIdentifier,
            error: RealtimeTransportError.disconnected
        )
    }
}

private final class WebSocketOpenGate: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<Void, Error>

    private enum State {
        case waiting([UUID: Waiter])
        case completed(Result<Void, Error>)
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]

    func begin(taskIdentifier: Int) {
        lock.withLock {
            states[taskIdentifier] = .waiting([:])
        }
    }

    func wait(taskIdentifier: Int) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    switch states[taskIdentifier] {
                    case var .waiting(waiters):
                        waiters[waiterID] = continuation
                        states[taskIdentifier] = .waiting(waiters)
                        return nil
                    case let .completed(result):
                        return result
                    case nil:
                        return .failure(RealtimeTransportError.disconnected)
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation: Waiter? = self.lock.withLock {
                guard case var .waiting(waiters) = self.states[taskIdentifier] else {
                    return nil
                }
                let continuation = waiters.removeValue(forKey: waiterID)
                self.states[taskIdentifier] = .waiting(waiters)
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func opened(taskIdentifier: Int) {
        complete(taskIdentifier: taskIdentifier, result: .success(()))
    }

    func cancel(taskIdentifier: Int, error: Error) {
        complete(taskIdentifier: taskIdentifier, result: .failure(error))
    }

    func remove(taskIdentifier: Int) {
        _ = lock.withLock {
            states.removeValue(forKey: taskIdentifier)
        }
    }

    private func complete(
        taskIdentifier: Int,
        result: Result<Void, Error>
    ) {
        let waiters: [Waiter] = lock.withLock {
            guard case let .waiting(waiters) = states[taskIdentifier] else {
                return []
            }
            states[taskIdentifier] = .completed(result)
            return Array(waiters.values)
        }
        waiters.forEach { $0.resume(with: result) }
    }
}

private enum HTTPDateParser {
    static let formatters: [DateFormatter] = {
        [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
