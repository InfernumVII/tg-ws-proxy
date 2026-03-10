import Foundation
import Network
import Security

struct WsHandshakeError: Error {
    let statusCode: Int
    let statusLine: String
    let headers: [String: String]
    let location: String?

    var isRedirect: Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }
}

actor RawWebSocketClient {
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TgWsProxyIOS.RawWebSocket")
    private var buffer = Data()

    init(ip: String, domain: String, path: String = "/apiws") throws {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, domain)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completion in
            completion(true)
        }, queue)

        guard let port = NWEndpoint.Port(rawValue: 443) else {
            throw NSError(domain: "TgWsProxyIOS", code: -20, userInfo: [NSLocalizedDescriptionKey: "Invalid TLS port"])
        }

        let parameters = NWParameters(tls: tlsOptions)
        connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: parameters)
        self.path = path
        self.domain = domain
    }

    private let path: String
    private let domain: String

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                    continuation.resume(throwing: NSError(domain: "TgWsProxyIOS", code: -21, userInfo: [NSLocalizedDescriptionKey: "WebSocket cancelled"]))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        let wsKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\n" +
            "Host: \(domain)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(wsKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "Sec-WebSocket-Protocol: binary\r\n" +
            "Origin: https://web.telegram.org\r\n" +
            "User-Agent: TgWsProxyIOS/0.1\r\n\r\n"

        try await sendRaw(Data(request.utf8))
        try await performHandshakeValidation()
    }

    func sendBinary(_ data: Data) async throws {
        try await sendRaw(buildFrame(opcode: .binary, payload: data, masked: true))
    }

    func receiveBinary() async throws -> Data? {
        while true {
            let (opcode, payload) = try await receiveFrame()
            switch opcode {
            case .binary, .text:
                return payload
            case .ping:
                try await sendRaw(buildFrame(opcode: .pong, payload: payload, masked: true))
            case .pong:
                continue
            case .close:
                try? await sendRaw(buildFrame(opcode: .close, payload: Data(), masked: true))
                return nil
            default:
                continue
            }
        }
    }

    func close() {
        connection.cancel()
    }

    private func performHandshakeValidation() async throws {
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                let lines = headerText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let statusLine = lines.first else {
                    throw WsHandshakeError(statusCode: 0, statusLine: "empty response", headers: [:], location: nil)
                }
                let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
                let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
                if code == 101 {
                    return
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                throw WsHandshakeError(statusCode: code, statusLine: statusLine, headers: headers, location: headers["location"])
            }

            guard let next = try await receiveChunk() else {
                throw WsHandshakeError(statusCode: 0, statusLine: "empty response", headers: [:], location: nil)
            }
            buffer.append(next)
        }
    }

    private func receiveFrame() async throws -> (Opcode, Data) {
        let header = try await readExactly(2)
        let first = header[header.startIndex]
        let second = header[header.index(after: header.startIndex)]
        let opcode = Opcode(rawValue: first & 0x0F) ?? .continuation
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)

        if length == 126 {
            let ext = try await readExactly(2)
            length = (Int(ext[ext.startIndex]) << 8) | Int(ext[ext.index(after: ext.startIndex)])
        } else if length == 127 {
            let ext = try await readExactly(8)
            length = ext.reduce(0) { partial, byte in
                (partial << 8) | Int(byte)
            }
        }

        let mask: Data? = masked ? try await readExactly(4) : nil
        let payload = try await readExactly(length)
        if let mask {
            return (opcode, xorMask(payload, mask: mask))
        }
        return (opcode, payload)
    }

    private func sendRaw(_ data: Data) async throws {
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

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }

    private func readExactly(_ length: Int) async throws -> Data {
        while buffer.count < length {
            guard let chunk = try await receiveChunk(), !chunk.isEmpty else {
                throw NSError(domain: "TgWsProxyIOS", code: -22, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF while reading WebSocket frame"])
            }
            buffer.append(chunk)
        }

        let data = buffer.subdata(in: 0..<length)
        buffer.removeSubrange(0..<length)
        return data
    }

    private func buildFrame(opcode: Opcode, payload: Data, masked: Bool) -> Data {
        var header = Data([0x80 | opcode.rawValue])
        let length = payload.count
        let maskBit: UInt8 = masked ? 0x80 : 0x00

        if length < 126 {
            header.append(maskBit | UInt8(length))
        } else if length < 65_536 {
            header.append(maskBit | 126)
            var size = UInt16(length).bigEndian
            header.append(Data(bytes: &size, count: MemoryLayout<UInt16>.size))
        } else {
            header.append(maskBit | 127)
            var size = UInt64(length).bigEndian
            header.append(Data(bytes: &size, count: MemoryLayout<UInt64>.size))
        }

        if masked {
            let mask = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
            header.append(mask)
            header.append(xorMask(payload, mask: mask))
            return header
        }

        header.append(payload)
        return header
    }

    private func xorMask(_ payload: Data, mask: Data) -> Data {
        let maskBytes = [UInt8](mask)
        let bytes = payload.enumerated().map { index, byte in
            byte ^ maskBytes[index % 4]
        }
        return Data(bytes)
    }
}
