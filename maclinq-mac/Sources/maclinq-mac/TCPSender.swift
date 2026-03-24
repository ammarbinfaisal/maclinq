import Foundation
import Network

final class TCPSender {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "maclinq.tcp", qos: .userInteractive)
    private var heartbeatTimer: DispatchSourceTimer?
    private var connectionStartTime: Date?
    private var connectCompletion: ((Error?) -> Void)?
    private var didFinishConnect = false
    private var ready = false
    private var intentionalDisconnect = false
    private var disconnectNotified = false

    var onDisconnect: ((String) -> Void)?

    func connect(host: String, port: UInt16, completion: @escaping (Error?) -> Void) {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(makeError("Invalid port \(port)"))
            return
        }
        guard connection == nil else {
            completion(makeError("Connection attempt refused because a transport is already active"))
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        connection = conn
        connectCompletion = completion
        didFinishConnect = false
        ready = false
        intentionalDisconnect = false
        disconnectNotified = false

        conn.stateUpdateHandler = { [weak self] state in
            self?.handleStateUpdate(state)
        }
        conn.start(queue: queue)
    }

    func sendKeyEvent(type: UInt8, keycode: UInt16, modifiers: UInt8, timestampMs: UInt32) {
        send(data: Self.keyEventPacket(type: type, keycode: keycode, modifiers: modifiers, timestampMs: timestampMs),
             description: "key event")
    }

    func sendMouseMove(deltaX: Int16, deltaY: Int16) {
        send(data: Self.mouseMovePacket(deltaX: deltaX, deltaY: deltaY), description: "mouse move")
    }

    func sendMouseButton(type: UInt8, button: UInt8) {
        send(data: Self.mouseButtonPacket(type: type, button: button), description: "mouse button")
    }

    func sendMouseScroll(deltaX: Int16, deltaY: Int16) {
        send(data: Self.mouseScrollPacket(deltaX: deltaX, deltaY: deltaY), description: "scroll")
    }

    func sendHeartbeat() {
        send(data: Self.controlPacket(type: 0x10), description: "heartbeat")
    }

    func disconnect() {
        intentionalDisconnect = true
        stopHeartbeat()

        guard connection != nil else {
            return
        }

        if didFinishConnect {
            send(data: Self.controlPacket(type: 0x11), description: "disconnect") { [weak self] _ in
                self?.queue.asyncAfter(deadline: .now() + 0.05) {
                    self?.cleanupTransport(cancelConnection: true)
                }
            }
        } else {
            queue.async { [weak self] in
                self?.cleanupTransport(cancelConnection: true)
            }
        }
    }

    var elapsedMs: UInt32 {
        guard let start = connectionStartTime else { return 0 }
        return UInt32(min(Date().timeIntervalSince(start) * 1000, Double(UInt32.max)))
    }

    static func handshakePacket() -> Data {
        Data([0x4D, 0x43, 0x4C, 0x51, 0x01, 0x00])
    }

    static func keyEventPacket(type: UInt8, keycode: UInt16, modifiers: UInt8, timestampMs: UInt32) -> Data {
        var buf = [UInt8](repeating: 0, count: 8)
        buf[0] = type
        buf[1] = UInt8((keycode >> 8) & 0xFF)
        buf[2] = UInt8(keycode & 0xFF)
        buf[3] = modifiers
        buf[4] = UInt8((timestampMs >> 24) & 0xFF)
        buf[5] = UInt8((timestampMs >> 16) & 0xFF)
        buf[6] = UInt8((timestampMs >> 8) & 0xFF)
        buf[7] = UInt8(timestampMs & 0xFF)
        return Data(buf)
    }

    static func controlPacket(type: UInt8) -> Data {
        var buf = [UInt8](repeating: 0, count: 8)
        buf[0] = type
        return Data(buf)
    }

    static func mouseMovePacket(deltaX: Int16, deltaY: Int16) -> Data {
        var buf = [UInt8](repeating: 0, count: 8)
        let x = UInt16(bitPattern: deltaX)
        let y = UInt16(bitPattern: deltaY)
        buf[0] = 0x20
        buf[1] = UInt8((x >> 8) & 0xFF)
        buf[2] = UInt8(x & 0xFF)
        buf[3] = UInt8((y >> 8) & 0xFF)
        buf[4] = UInt8(y & 0xFF)
        return Data(buf)
    }

    static func mouseButtonPacket(type: UInt8, button: UInt8) -> Data {
        var buf = [UInt8](repeating: 0, count: 8)
        buf[0] = type
        buf[1] = button
        return Data(buf)
    }

    static func mouseScrollPacket(deltaX: Int16, deltaY: Int16) -> Data {
        var buf = [UInt8](repeating: 0, count: 8)
        let x = UInt16(bitPattern: deltaX)
        let y = UInt16(bitPattern: deltaY)
        buf[0] = 0x23
        buf[1] = UInt8((x >> 8) & 0xFF)
        buf[2] = UInt8(x & 0xFF)
        buf[3] = UInt8((y >> 8) & 0xFF)
        buf[4] = UInt8(y & 0xFF)
        return Data(buf)
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionStartTime = Date()
            performHandshake()
        case .waiting(let error):
            let message = "transport waiting: \(error.localizedDescription)"
            fputs("maclinq-mac: \(message)\n", stderr)
            if !didFinishConnect {
                finishConnectIfNeeded(with: makeError(message))
                notifyDisconnect(message)
                cleanupTransport(cancelConnection: true)
            }
        case .failed(let error):
            let message = "transport failed: \(error.localizedDescription)"
            finishConnectIfNeeded(with: makeError(message))
            notifyDisconnect(message)
            cleanupTransport(cancelConnection: false)
        case .cancelled:
            finishConnectIfNeeded(with: makeError("transport cancelled before handshake completed"))
            if !intentionalDisconnect {
                notifyDisconnect("transport cancelled unexpectedly")
            }
            cleanupTransport(cancelConnection: false)
        default:
            break
        }
    }

    private func performHandshake() {
        send(data: Self.handshakePacket(), description: "handshake") { [weak self] error in
            guard let self else { return }

            if let error {
                self.finishConnectIfNeeded(with: error)
                self.notifyDisconnect("handshake send failed: \(error.localizedDescription)")
                self.cleanupTransport(cancelConnection: true)
                return
            }

            self.connection?.receive(minimumIncompleteLength: 6, maximumLength: 6) { data, _, _, error in
                if let error {
                    let wrapped = self.makeError("Handshake response read failed: \(error.localizedDescription)")
                    self.finishConnectIfNeeded(with: wrapped)
                    self.notifyDisconnect(wrapped.localizedDescription)
                    self.cleanupTransport(cancelConnection: true)
                    return
                }

                guard let data, data.count == 6 else {
                    let wrapped = self.makeError("Handshake response was incomplete; expected 6 bytes but received \(data?.count ?? 0)")
                    self.finishConnectIfNeeded(with: wrapped)
                    self.notifyDisconnect(wrapped.localizedDescription)
                    self.cleanupTransport(cancelConnection: true)
                    return
                }

                let bytes = [UInt8](data)
                guard bytes[0] == 0x4D, bytes[1] == 0x43, bytes[2] == 0x4C, bytes[3] == 0x51 else {
                    let wrapped = self.makeError(
                        "Handshake response had invalid magic bytes: \(bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))"
                    )
                    self.finishConnectIfNeeded(with: wrapped)
                    self.notifyDisconnect(wrapped.localizedDescription)
                    self.cleanupTransport(cancelConnection: true)
                    return
                }

                guard bytes[4] == 0x01 else {
                    let wrapped = self.makeError(
                        "Handshake response version mismatch: expected 0x01, received 0x\(String(format: "%02X", bytes[4]))"
                    )
                    self.finishConnectIfNeeded(with: wrapped)
                    self.notifyDisconnect(wrapped.localizedDescription)
                    self.cleanupTransport(cancelConnection: true)
                    return
                }

                guard bytes[5] == 0x00 else {
                    let wrapped = self.makeError(
                        "Handshake rejected by remote server with status 0x\(String(format: "%02X", bytes[5]))"
                    )
                    self.finishConnectIfNeeded(with: wrapped)
                    self.notifyDisconnect(wrapped.localizedDescription)
                    self.cleanupTransport(cancelConnection: true)
                    return
                }

                self.ready = true
                self.startHeartbeat()
                self.finishConnectIfNeeded(with: nil)
            }
        }
    }

    private func finishConnectIfNeeded(with error: Error?) {
        guard !didFinishConnect else {
            return
        }

        didFinishConnect = true
        let completion = connectCompletion
        connectCompletion = nil
        completion?(error)
    }

    private func send(data: Data, description: String, completion: ((Error?) -> Void)? = nil) {
        guard ready || description == "handshake" else {
            completion?(makeError("Cannot send \(description) because the transport is not connected"))
            return
        }
        guard let connection else {
            completion?(makeError("Cannot send \(description) because no active connection exists"))
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                let wrapped = self?.makeError("Failed to send \(description): \(error.localizedDescription)") ?? error
                completion?(wrapped)
                if self?.intentionalDisconnect == false {
                    self?.notifyDisconnect(wrapped.localizedDescription)
                }
                return
            }

            completion?(nil)
        })
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func cleanupTransport(cancelConnection: Bool) {
        stopHeartbeat()
        ready = false
        connectionStartTime = nil
        if cancelConnection {
            connection?.cancel()
        }
        connection = nil
    }

    private func notifyDisconnect(_ message: String) {
        guard !intentionalDisconnect, !disconnectNotified else {
            return
        }

        disconnectNotified = true
        onDisconnect?(message)
    }

    private func makeError(_ message: String) -> Error {
        NSError(domain: "maclinq-mac", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
