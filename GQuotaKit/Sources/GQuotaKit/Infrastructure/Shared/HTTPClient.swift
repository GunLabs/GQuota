import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Test double: replays preset responses in order.
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Stub: Sendable {
        public let status: Int
        public let body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    private actor ResponseSequence {
        private let responses: [Stub]
        private var index = 0

        init(responses: [Stub]) {
            self.responses = responses
        }

        func next() throws -> Stub {
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }

            let stub = responses[min(index, responses.count - 1)]
            index += 1
            return stub
        }
    }

    private let sequence: ResponseSequence

    public init(responses: [Stub]) {
        self.sequence = ResponseSequence(responses: responses)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let stub = try await sequence.next()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (stub.body, http)
    }
}
