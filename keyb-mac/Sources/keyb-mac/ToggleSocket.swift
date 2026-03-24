import Darwin
import Foundation

enum ToggleCommandResult {
    case noResponse
    case response(UInt8)
    case invalid
}

final class ToggleSocket {
    private let socketPath: String
    private let commandHandler: (UInt8) -> ToggleCommandResult
    private let queue = DispatchQueue(label: "keyb.toggle-socket", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var running = false

    init(socketPath: String = "/tmp/keyb.sock", commandHandler: @escaping (UInt8) -> ToggleCommandResult) {
        self.socketPath = socketPath
        self.commandHandler = commandHandler
    }

    func start() throws {
        guard !running else {
            throw makeError("toggle socket is already running at \(socketPath)")
        }

        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw currentPOSIXError("failed to create Unix socket")
        }

        do {
            try setNoSigPipe(fd)

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(socketPath.utf8CString)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= pathCapacity else {
                close(fd)
                throw makeError("socket path is too long for sockaddr_un: \(socketPath)")
            }

            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                buffer.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
            }

            let addressLength = socklen_t(MemoryLayout.size(ofValue: address))
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, addressLength)
                }
            }
            guard bindResult == 0 else {
                let error = currentPOSIXError("failed to bind toggle socket at \(socketPath)")
                close(fd)
                throw error
            }

            if chmod(socketPath, 0o600) != 0 {
                let error = currentPOSIXError("failed to set permissions on \(socketPath)")
                close(fd)
                unlink(socketPath)
                throw error
            }

            guard listen(fd, 8) == 0 else {
                let error = currentPOSIXError("failed to listen on toggle socket \(socketPath)")
                close(fd)
                unlink(socketPath)
                throw error
            }
        } catch {
            close(fd)
            throw error
        }

        listenFD = fd
        running = true
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        print("keyb-mac: toggle socket listening at \(socketPath)")
    }

    func stop() {
        guard running else {
            return
        }

        running = false

        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }

        if unlink(socketPath) != 0 && errno != ENOENT {
            fputs("keyb-mac: failed to remove toggle socket \(socketPath): \(String(cString: strerror(errno)))\n", stderr)
        } else {
            print("keyb-mac: toggle socket stopped")
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if !running {
                    break
                }
                if errno == EINTR {
                    continue
                }

                fputs("keyb-mac: toggle socket accept failed: \(String(cString: strerror(errno)))\n", stderr)
                continue
            }

            do {
                try setNoSigPipe(clientFD)
            } catch {
                fputs("keyb-mac: failed to configure client toggle socket: \(error.localizedDescription)\n", stderr)
            }

            handleClient(clientFD)
            close(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        var command: UInt8 = 0
        let bytesRead = read(clientFD, &command, 1)
        if bytesRead < 0 {
            fputs("keyb-mac: failed to read toggle command: \(String(cString: strerror(errno)))\n", stderr)
            return
        }
        guard bytesRead == 1 else {
            fputs("keyb-mac: toggle client disconnected before sending a command byte\n", stderr)
            return
        }

        switch commandHandler(command) {
        case .noResponse:
            return
        case .invalid:
            fputs("keyb-mac: ignored unknown toggle command 0x\(String(format: "%02X", command))\n", stderr)
            return
        case .response(let response):
            var responseByte = response
            let bytesWritten = write(clientFD, &responseByte, 1)
            if bytesWritten < 0 && errno != EPIPE {
                fputs("keyb-mac: failed to write toggle response: \(String(cString: strerror(errno)))\n", stderr)
            }
        }
    }

    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }
        guard unlink(socketPath) == 0 else {
            throw currentPOSIXError("failed to remove stale socket at \(socketPath)")
        }
    }

    private func setNoSigPipe(_ fd: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
            throw currentPOSIXError("failed to set SO_NOSIGPIPE on socket fd \(fd)")
        }
    }

    private func currentPOSIXError(_ message: String) -> NSError {
        makeError("\(message): \(String(cString: strerror(errno)))")
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "keyb-mac", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
