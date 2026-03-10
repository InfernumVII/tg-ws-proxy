import Foundation
import Network
import NetworkExtension
import OSLog

final class TgWsProxyTunnelProvider: NEAppProxyProvider {
    private let logger = Logger(subsystem: "org.flowseal.TgWsProxyIOS", category: "tunnel")

    override func startProxy(options: [String : Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        logger.info("App proxy starting")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("App proxy stopping: \(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            logger.error("Rejecting non-TCP flow")
            return false
        }

        let configuration = ProxyConfiguration.fromProviderConfiguration((protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration)
        let engine = TelegramBridgeEngine(logger: logger, configuration: configuration)

        Task {
            do {
                try await engine.handle(flow: tcpFlow)
            } catch {
                logger.error("Flow failed: \(error.localizedDescription)")
                tcpFlow.closeReadWithError(error)
                tcpFlow.closeWriteWithError(error)
            }
        }

        return true
    }
}

private struct FlowTarget {
    let host: String
    let port: Int
}

private actor TelegramBridgeEngine {
    private let logger: Logger
    private let configuration: ProxyConfiguration

    init(logger: Logger, configuration: ProxyConfiguration) {
        self.logger = logger
        self.configuration = configuration
    }

    func handle(flow: NEAppProxyTCPFlow) async throws {
        try await flow.openIfNeeded()
        guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint, let port = Int(endpoint.port) else {
            throw NSError(domain: "TgWsProxyIOS", code: -30, userInfo: [NSLocalizedDescriptionKey: "Unsupported remote endpoint"])
        }

        let target = FlowTarget(host: endpoint.hostname, port: port)
        logger.info("New flow to \(target.host):\(target.port)")

        if !TelegramRouting.isTelegramIP(target.host) {
            try await passthrough(flow: flow, target: target)
            return
        }

        let (initial, buffered) = try await readInitial64(from: flow)
        guard let initial else {
            close(flow: flow, error: nil)
            return
        }

        if isHTTPTransport(initial) {
            logger.info("Rejecting HTTP transport for \(target.host):\(target.port)")
            close(flow: flow, error: nil)
            return
        }

        let extracted = MTProtoInitParser.extractDC(from: initial)
        let dc = extracted.dc ?? TelegramRouting.ipToDC[target.host]
        guard let dc else {
            logger.info("Unknown Telegram DC for \(target.host), falling back to TCP")
            try await tcpFallback(flow: flow, target: target, initial: initial, buffered: buffered)
            return
        }

        guard let wsIP = configuration.dcMap[dc] else {
            logger.info("No WS IP mapping for DC\(dc), using TCP fallback")
            try await tcpFallback(flow: flow, target: target, initial: initial, buffered: buffered)
            return
        }

        do {
            try await websocketBridge(flow: flow, target: target, dc: dc, isMedia: extracted.isMedia, wsIP: wsIP, initial: initial, buffered: buffered)
        } catch {
            logger.error("WS bridge failed for DC\(dc): \(error.localizedDescription). Falling back to TCP")
            try await tcpFallback(flow: flow, target: target, initial: initial, buffered: buffered)
        }
    }

    private func passthrough(flow: NEAppProxyTCPFlow, target: FlowTarget) async throws {
        let remote = try TCPConnectionClient(host: target.host, port: target.port)
        try await remote.start()
        try await bridge(flow: flow, remote: remote)
    }

    private func tcpFallback(flow: NEAppProxyTCPFlow, target: FlowTarget, initial: Data, buffered: Data) async throws {
        let remote = try TCPConnectionClient(host: target.host, port: target.port)
        try await remote.start()
        try await remote.send(initial)
        if !buffered.isEmpty {
            try await remote.send(buffered)
        }
        try await bridge(flow: flow, remote: remote)
    }

    private func websocketBridge(flow: NEAppProxyTCPFlow, target: FlowTarget, dc: Int, isMedia: Bool?, wsIP: String, initial: Data, buffered: Data) async throws {
        var lastError: Error?
        for domain in TelegramRouting.wsDomains(dc: dc, isMedia: isMedia) {
            do {
                logger.info("Trying WS for DC\(dc) via \(domain) @ \(wsIP)")
                let ws = try RawWebSocketClient(ip: wsIP, domain: domain)
                try await ws.connect()
                try await ws.sendBinary(initial)
                if !buffered.isEmpty {
                    try await ws.sendBinary(buffered)
                }
                try await bridge(flow: flow, websocket: ws)
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "TgWsProxyIOS", code: -31, userInfo: [NSLocalizedDescriptionKey: "All WebSocket endpoints failed"])
    }

    private func bridge(flow: NEAppProxyTCPFlow, remote: TCPConnectionClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let chunk = try await flow.readChunk() {
                    try await remote.send(chunk)
                }
                await remote.close()
            }
            group.addTask {
                while let chunk = try await remote.receive() {
                    try await flow.writeChunk(chunk)
                }
                self.close(flow: flow, error: nil)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func bridge(flow: NEAppProxyTCPFlow, websocket: RawWebSocketClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let chunk = try await flow.readChunk() {
                    try await websocket.sendBinary(chunk)
                }
                await websocket.close()
            }
            group.addTask {
                while let chunk = try await websocket.receiveBinary() {
                    try await flow.writeChunk(chunk)
                }
                self.close(flow: flow, error: nil)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func readInitial64(from flow: NEAppProxyTCPFlow) async throws -> (Data?, Data) {
        var data = Data()
        while data.count < 64 {
            guard let chunk = try await flow.readChunk() else {
                return (data.isEmpty ? nil : data, Data())
            }
            data.append(chunk)
        }

        let initial = data.prefix(64)
        let remainder = data.dropFirst(64)
        return (Data(initial), Data(remainder))
    }

    private func isHTTPTransport(_ data: Data) -> Bool {
        let prefixes = ["POST ", "GET ", "HEAD ", "OPTIONS "]
        let text = String(decoding: data.prefix(8), as: UTF8.self)
        return prefixes.contains { text.hasPrefix($0) }
    }

    private func close(flow: NEAppProxyTCPFlow, error: Error?) {
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }
}

private extension NEAppProxyTCPFlow {
    func openIfNeeded() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.open(withLocalEndpoint: nil) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func readChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            self.readData(completionHandler: { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            })
        }
    }

    func writeChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.write(data, withCompletionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}
