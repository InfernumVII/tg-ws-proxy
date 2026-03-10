import Foundation
import Network

actor TCPConnectionClient {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "TgWsProxyIOS.TCPConnectionClient")

    init(host: String, port: Int) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "TgWsProxyIOS", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: ())
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: NSError(domain: "TgWsProxyIOS", code: -11, userInfo: [NSLocalizedDescriptionKey: "Connection cancelled"]))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receive() async throws -> Data? {
        if !buffer.isEmpty {
            let data = buffer
            buffer.removeAll(keepingCapacity: true)
            return data
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
