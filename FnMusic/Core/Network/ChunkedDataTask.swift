import Foundation

enum ChunkedDataTask {
    static func data(
        for request: URLRequest,
        session: URLSession,
        responsePolicy: @escaping @Sendable (HTTPURLResponse) throws -> Int,
        overflowError: @escaping @Sendable () -> Error
    ) async throws -> (Data, HTTPURLResponse) {
        let collector = ChunkedDataTaskCollector(responsePolicy: responsePolicy, overflowError: overflowError)
        let task = session.dataTask(with: request)
        task.delegate = collector
        return try await withTaskCancellationHandler {
            try await collector.start(task)
        } onCancel: {
            task.cancel()
        }
    }
}

private final class ChunkedDataTaskCollector: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<(Data, HTTPURLResponse), Error>

    private let responsePolicy: @Sendable (HTTPURLResponse) throws -> Int
    private let overflowError: @Sendable () -> Error
    private var continuation: Continuation?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var capacity = 0
    private var terminalError: Error?

    init(
        responsePolicy: @escaping @Sendable (HTTPURLResponse) throws -> Int,
        overflowError: @escaping @Sendable () -> Error
    ) {
        self.responsePolicy = responsePolicy
        self.overflowError = overflowError
    }

    func start(_ task: URLSessionDataTask) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            terminalError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        self.response = http
        do {
            capacity = try responsePolicy(http)
            data.reserveCapacity(min(capacity, 524_288))
            completionHandler(.allow)
        } catch {
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard terminalError == nil else { return }
        guard chunk.count <= capacity - data.count else {
            terminalError = overflowError()
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let terminalError {
            continuation?.resume(throwing: terminalError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
    }
}
