import CoreGraphics
import Foundation

struct AppConfig {
    let host: String
    let port: UInt16
    let autoOn: Bool
    let fixturePath: String?
}

private enum ToggleHotkey {
    static let keyCode = CGKeyCode(0x64) // F8 on macOS virtual keycodes
}

final class MaclinqApp {
    private let config: AppConfig
    private let keyCapture = KeyCapture()
    private let mouseCapture = MouseCapture()
    private let stateLock = NSLock()
    private let fixturePlayback: FixturePlayback?
    private lazy var toggleSocket = ToggleSocket { [weak self] command in
        self?.handleToggleCommand(command) ?? .invalid
    }

    private var desiredActive = false
    private var isActive = false
    private var isShuttingDown = false
    private var sender: TCPSender?

    init(config: AppConfig) throws {
        self.config = config
        if let fixturePath = config.fixturePath {
            fixturePlayback = try FixturePlayback(path: fixturePath)
        } else {
            fixturePlayback = nil
        }
    }

    func start() throws {
        if fixturePlayback == nil {
            try PermissionCheck.validateInteractiveCapturePermissions()
            try toggleSocket.start()
            print("maclinq-mac: ready; target is \(config.host):\(config.port)")
            print("maclinq-mac: use Karabiner or scripts/maclinq-toggle.sh to toggle forwarding")
        } else {
            print("maclinq-mac: fixture mode enabled; target is \(config.host):\(config.port)")
        }

        if config.autoOn || fixturePlayback != nil {
            DispatchQueue.main.async { [weak self] in
                self?.activate(reason: self?.fixturePlayback != nil ? "fixture mode" : "auto-on")
            }
        }
    }

    func shutdown(reason: String, exitCode: Int32 = 0) {
        var senderToDisconnect: TCPSender?
        let shouldContinue: Bool = withLockedState {
            if isShuttingDown {
                return false
            }
            isShuttingDown = true
            desiredActive = false
            isActive = false
            senderToDisconnect = sender
            sender = nil
            return true
        }

        guard shouldContinue else {
            return
        }

        print("maclinq-mac: shutting down (\(reason))")
        stopCaptures()
        toggleSocket.stop()

        if let senderToDisconnect {
            senderToDisconnect.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Foundation.exit(exitCode)
            }
        } else {
            Foundation.exit(exitCode)
        }
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
                self?.activate(reason: "force-on command")
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
            activate(reason: "toggle command")
        }
    }

    private func activate(reason: String) {
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

        print("maclinq-mac: connecting to \(config.host):\(config.port) (\(reason))")
        sender.connect(host: config.host, port: config.port) { [weak self, weak sender] error in
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
                    if self.fixturePlayback != nil {
                        self.shutdown(reason: "fixture startup failed", exitCode: 1)
                    }
                    return
                }

                do {
                    if let fixturePlayback = self.fixturePlayback {
                        self.withLockedState {
                            self.isActive = true
                        }
                        print("maclinq-mac: active (fixture mode)")
                        self.runFixturePlayback(fixturePlayback, sender: sender)
                        return
                    }

                    try self.startLiveCapture(sender: sender)
                } catch {
                    self.withLockedState {
                        self.desiredActive = false
                    }
                    self.stopCaptures()
                    sender?.disconnect()
                    self.sender = nil
                    fputs("maclinq-mac: transport connected, but local input capture could not start: \(error.localizedDescription)\n", stderr)
                    return
                }

                self.withLockedState {
                    self.isActive = true
                }
                print("maclinq-mac: active")
            }
        }
    }

    private func startLiveCapture(sender: TCPSender?) throws {
        do {
            try keyCapture.start { [weak self, weak sender] type, keyCode, flags in
                self?.forwardCapturedEvent(type: type, keyCode: keyCode, flags: flags, sender: sender)
            }
        } catch {
            throw NSError(
                domain: "maclinq-mac",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "keyboard capture start failed: \(error.localizedDescription)"]
            )
        }

        do {
            try mouseCapture.start { [weak self, weak sender] event in
                self?.forwardMouseEvent(event, sender: sender)
            }
        } catch {
            keyCapture.stop()
            throw NSError(
                domain: "maclinq-mac",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "mouse capture start failed: \(error.localizedDescription)"]
            )
        }
    }

    private func runFixturePlayback(_ playback: FixturePlayback, sender: TCPSender?) {
        playback.play(
            forwardKey: { [weak self, weak sender] type, keyCode, flags in
                self?.forwardCapturedEvent(type: type, keyCode: keyCode, flags: flags, sender: sender)
            },
            forwardMouse: { [weak self, weak sender] event in
                self?.forwardMouseEvent(event, sender: sender)
            },
            completion: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        fputs("maclinq-mac: fixture replay failed: \(error.localizedDescription)\n", stderr)
                        self.shutdown(reason: "fixture failed", exitCode: 1)
                        return
                    }

                    print("maclinq-mac: fixture replay completed successfully")
                    self.shutdown(reason: "fixture completed", exitCode: 0)
                }
            }
        )
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
        stopCaptures()
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
        stopCaptures()
        sender = nil

        if fixturePlayback != nil {
            shutdown(reason: "fixture transport failure", exitCode: 1)
        }
    }

    private func stopCaptures() {
        mouseCapture.stop()
        keyCapture.stop()
    }

    private func forwardCapturedEvent(type: UInt8, keyCode: CGKeyCode, flags: CGEventFlags, sender: TCPSender?) {
        guard currentStatusByte() == 0x01, let sender else {
            return
        }

        // Never forward the local toggle key to the remote side.
        if keyCode == ToggleHotkey.keyCode, type == 0x01 || type == 0x02 {
            return
        }

        let modifiers = KeyMapper.mapModifiers(flags)
        let timestamp = sender.elapsedMs

        switch type {
        case 0x03:
            sender.sendKeyEvent(type: type, keycode: 0, modifiers: modifiers, timestampMs: timestamp)
        case 0x01, 0x02:
            guard let mappedKeyCode = KeyMapper.mapKeyCode(keyCode) else {
                fputs("maclinq-mac: no Linux evdev mapping for macOS keycode \(keyCode); keyboard event dropped\n", stderr)
                return
            }
            sender.sendKeyEvent(type: type, keycode: mappedKeyCode, modifiers: modifiers, timestampMs: timestamp)
        default:
            fputs("maclinq-mac: unexpected keyboard capture event type 0x\(String(format: "%02X", type)); event dropped\n", stderr)
        }
    }

    private func forwardMouseEvent(_ event: MouseForwardEvent, sender: TCPSender?) {
        guard currentStatusByte() == 0x01, let sender else {
            return
        }

        switch event {
        case .move(let deltaX, let deltaY):
            guard deltaX != 0 || deltaY != 0 else {
                return
            }
            sender.sendMouseMove(deltaX: deltaX, deltaY: deltaY)
        case .buttonDown(let button):
            sender.sendMouseButton(type: 0x21, button: button)
        case .buttonUp(let button):
            sender.sendMouseButton(type: 0x22, button: button)
        case .scroll(let deltaX, let deltaY):
            guard deltaX != 0 || deltaY != 0 else {
                return
            }
            sender.sendMouseScroll(deltaX: deltaX, deltaY: deltaY)
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
    fputs("Usage: \(program) [--auto-on] [--fixture PATH] <host> <port>\n", stderr)
    fputs("Both host and port are required; Maclinq does not assume network defaults.\n", stderr)
    fputs("--fixture replays scripted events and implies immediate activation\n", stderr)
    Foundation.exit(2)
}

private func parsePort(_ value: String) -> UInt16? {
    UInt16(value)
}

private func parseArguments() -> AppConfig {
    var autoOn = false
    var fixturePath: String?
    var positional: [String] = []
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0

    while index < args.count {
        let arg = args[index]

        switch arg {
        case "--help", "-h":
            printUsageAndExit()
        case "--auto-on":
            autoOn = true
        case "--fixture":
            index += 1
            guard index < args.count else {
                fputs("maclinq-mac: --fixture requires a path argument\n", stderr)
                printUsageAndExit()
            }
            fixturePath = args[index]
        default:
            if arg.hasPrefix("--fixture=") {
                fixturePath = String(arg.dropFirst("--fixture=".count))
            } else if arg.hasPrefix("-") {
                fputs("maclinq-mac: unknown option '\(arg)'\n", stderr)
                printUsageAndExit()
            } else {
                positional.append(arg)
            }
        }

        index += 1
    }

    if positional.count != 2 {
        fputs("maclinq-mac: expected exactly two positional arguments: <host> <port>\n", stderr)
        printUsageAndExit()
    }

    let host = positional[0]
    if host.isEmpty {
        fputs("maclinq-mac: host must not be empty\n", stderr)
        printUsageAndExit()
    }

    if parsePort(positional[1]) == nil {
        fputs("maclinq-mac: invalid port '\(positional[1])'; expected an integer in the range 1-65535\n", stderr)
        printUsageAndExit()
    }

    return AppConfig(
        host: host,
        port: parsePort(positional[1]) ?? 0,
        autoOn: autoOn || fixturePath != nil,
        fixturePath: fixturePath
    )
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

let config = parseArguments()

do {
    let app = try MaclinqApp(config: config)
    installSignalHandlers(app: app)
    try app.start()
    dispatchMain()
} catch {
    fputs("maclinq-mac: startup failed: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
