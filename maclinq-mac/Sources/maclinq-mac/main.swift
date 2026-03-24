import CoreGraphics
import Foundation

final class MaclinqApp {
    private let host: String
    private let port: UInt16
    private let capture = KeyCapture()
    private let stateLock = NSLock()
    private lazy var toggleSocket = ToggleSocket { [weak self] command in
        self?.handleToggleCommand(command) ?? .invalid
    }

    private var desiredActive = false
    private var isActive = false
    private var isShuttingDown = false
    private var sender: TCPSender?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() throws {
        try toggleSocket.start()
        print("maclinq-mac: ready; target is \(host):\(port)")
        print("maclinq-mac: use Karabiner or scripts/maclinq-toggle.sh to toggle forwarding")
    }

    func shutdown(reason: String, exitCode: Int32 = 0) {
        let shouldContinue: Bool = withLockedState {
            if isShuttingDown {
                return false
            }
            isShuttingDown = true
            desiredActive = false
            isActive = false
            return true
        }

        guard shouldContinue else {
            return
        }

        print("maclinq-mac: shutting down (\(reason))")
        capture.stop()
        sender?.disconnect()
        sender = nil
        toggleSocket.stop()
        Foundation.exit(exitCode)
    }

    private func handleToggleCommand(_ command: UInt8) -> ToggleCommandResult {
        switch command {
        case 0x01:
            DispatchQueue.main.async { [weak self] in
                self?.toggleRequestedState()
            }
            return .noResponse
        case 0x02:
            DispatchQueue.main.async { [weak self] in
                self?.activate()
            }
            return .noResponse
        case 0x03:
            DispatchQueue.main.async { [weak self] in
                self?.deactivate(reason: "force-off command")
            }
            return .noResponse
        case 0x04:
            return .response(currentStatusByte())
        default:
            return .invalid
        }
    }

    private func toggleRequestedState() {
        if currentStatusByte() == 0x01 || isDesiredActive() {
            deactivate(reason: "toggle command")
        } else {
            activate()
        }
    }

    private func activate() {
        let shouldStart: Bool = withLockedState {
            guard !isShuttingDown else {
                return false
            }
            guard !desiredActive, !isActive else {
                return false
            }
            desiredActive = true
            return true
        }

        guard shouldStart else {
            print("maclinq-mac: activate request ignored because forwarding is already active or in progress")
            return
        }

        let sender = TCPSender()
        sender.onDisconnect = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleTransportFailure(message: message)
            }
        }
        self.sender = sender

        print("maclinq-mac: connecting to \(host):\(port)")
        sender.connect(host: host, port: port) { [weak self, weak sender] error in
            DispatchQueue.main.async {
                guard let self else { return }

                guard self.isDesiredActive(), !self.isShuttingDownLocked() else {
                    sender?.disconnect()
                    return
                }

                if let error {
                    self.withLockedState {
                        self.desiredActive = false
                    }
                    self.sender = nil
                    fputs("maclinq-mac: failed to activate forwarding: \(error.localizedDescription)\n", stderr)
                    return
                }

                do {
                    try self.capture.start { [weak self, weak sender] type, keyCode, flags in
                        self?.forwardCapturedEvent(type: type, keyCode: keyCode, flags: flags, sender: sender)
                    }
                } catch {
                    self.withLockedState {
                        self.desiredActive = false
                    }
                    sender?.disconnect()
                    self.sender = nil
                    fputs("maclinq-mac: transport connected, but keyboard capture could not start: \(error.localizedDescription)\n", stderr)
                    return
                }

                self.withLockedState {
                    self.isActive = true
                }
                print("maclinq-mac: active")
            }
        }
    }

    private func deactivate(reason: String) {
        let didChange = withLockedState { () -> Bool in
            let hadState = desiredActive || isActive
            desiredActive = false
            isActive = false
            return hadState
        }

        guard didChange else {
            print("maclinq-mac: deactivate request ignored because forwarding is already inactive")
            return
        }

        print("maclinq-mac: deactivating (\(reason))")
        capture.stop()
        sender?.disconnect()
        sender = nil
    }

    private func handleTransportFailure(message: String) {
        let hadState = withLockedState { () -> Bool in
            let hadAnyState = desiredActive || isActive
            desiredActive = false
            isActive = false
            return hadAnyState
        }

        guard hadState else {
            return
        }

        fputs("maclinq-mac: remote transport dropped; forwarding has been disabled: \(message)\n", stderr)
        capture.stop()
        sender = nil
    }

    private func forwardCapturedEvent(type: UInt8, keyCode: CGKeyCode, flags: CGEventFlags, sender: TCPSender?) {
        guard currentStatusByte() == 0x01, let sender else {
            return
        }

        let modifiers = KeyMapper.mapModifiers(flags)
        let timestamp = sender.elapsedMs

        switch type {
        case 0x03:
            sender.sendKeyEvent(type: type, keycode: 0, modifiers: modifiers, timestampMs: timestamp)
        case 0x01, 0x02:
            guard let mappedKeyCode = KeyMapper.mapKeyCode(keyCode) else {
                fputs("maclinq-mac: no Linux evdev mapping for macOS keycode \(keyCode); event dropped\n", stderr)
                return
            }
            sender.sendKeyEvent(type: type, keycode: mappedKeyCode, modifiers: modifiers, timestampMs: timestamp)
        default:
            fputs("maclinq-mac: unexpected capture event type 0x\(String(format: "%02X", type)); event dropped\n", stderr)
        }
    }

    private func currentStatusByte() -> UInt8 {
        withLockedState {
            isActive ? 0x01 : 0x00
        }
    }

    private func isDesiredActive() -> Bool {
        withLockedState { desiredActive }
    }

    private func isShuttingDownLocked() -> Bool {
        withLockedState { isShuttingDown }
    }

    @discardableResult
    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

private func printUsageAndExit() -> Never {
    let program = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "maclinq-mac"
    fputs("Usage: \(program) [host] [port]\n", stderr)
    fputs("Defaults: host=192.168.1.19 port=7680\n", stderr)
    Foundation.exit(2)
}

private func parseArguments() -> (String, UInt16) {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") || args.count > 2 {
        printUsageAndExit()
    }

    let host = args.first ?? "192.168.1.19"
    if host.isEmpty {
        printUsageAndExit()
    }

    guard args.count < 2 || UInt16(args[1]) != nil else {
        fputs("maclinq-mac: invalid port '\(args[1])'; expected an integer in the range 1-65535\n", stderr)
        printUsageAndExit()
    }

    return (host, UInt16(args.dropFirst().first ?? "7680") ?? 7680)
}

private func installSignalHandlers(app: MaclinqApp) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        app.shutdown(reason: "SIGINT")
    }
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        app.shutdown(reason: "SIGTERM")
    }
    sigtermSource.resume()

    _ = [sigintSource, sigtermSource]
}

let (host, port) = parseArguments()
let app = MaclinqApp(host: host, port: port)

do {
    installSignalHandlers(app: app)
    try app.start()
    dispatchMain()
} catch {
    fputs("maclinq-mac: startup failed: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
