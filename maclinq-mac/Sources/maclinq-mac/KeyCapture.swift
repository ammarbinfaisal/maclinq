import CoreGraphics
import Foundation

/// Callback type for captured keyboard events.
/// Parameters: eventType (1=keyDown,2=keyUp,3=flagsChanged), keyCode, flags
typealias KeyEventCallback = (UInt8, CGKeyCode, CGEventFlags) -> Void

private final class KeyCaptureStartupState {
    var error: Error?
}

final class KeyCapture {
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureRunLoop: CFRunLoop?
    private var captureThread: Thread?
    private var stopWaiter: DispatchSemaphore?
    private var callback: KeyEventCallback?

    /// Start capturing keyboard events, calling `callback` for each event.
    func start(callback: @escaping KeyEventCallback) throws {
        let startupWaiter = DispatchSemaphore(value: 0)
        let startupState = KeyCaptureStartupState()

        let thread = try withLockedState { () throws -> Thread in
            guard captureThread == nil else {
                throw NSError(
                    domain: "maclinq-mac",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "keyboard capture is already active"]
                )
            }

            self.callback = callback

            let thread = Thread { [weak self] in
                self?.runCaptureLoop(startupWaiter: startupWaiter, startupState: startupState)
            }
            thread.name = "maclinq.keyboard-capture"
            captureThread = thread
            return thread
        }

        thread.start()
        startupWaiter.wait()

        if let error = startupState.error {
            throw error
        }

        print("maclinq-mac: keyboard capture started")
    }

    /// Stop capturing keyboard events.
    func stop() {
        let stopWaiter: DispatchSemaphore? = withLockedState {
            guard captureThread != nil else {
                return nil
            }
            callback = nil
            let waiter = DispatchSemaphore(value: 0)
            self.stopWaiter = waiter
            return waiter
        }

        guard let stopWaiter else {
            return
        }

        if let runLoop = withLockedState({ captureRunLoop }) {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }

        stopWaiter.wait()
        print("maclinq-mac: keyboard capture stopped")
    }

    /// Called from the C callback; re-enables the tap if the system disabled it.
    fileprivate func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        // If the tap was disabled by the system, re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard let callback = callback else { return }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let eventTypeCode: UInt8
        switch type {
        case .keyDown:
            eventTypeCode = 0x01
        case .keyUp:
            eventTypeCode = 0x02
        case .flagsChanged:
            eventTypeCode = 0x03
        default:
            return
        }

        callback(eventTypeCode, keyCode, flags)
    }

    private func runCaptureLoop(startupWaiter: DispatchSemaphore, startupState: KeyCaptureStartupState) {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: keyCaptureCallback,
            userInfo: selfPtr
        ) else {
            withLockedState {
                callback = nil
                captureThread = nil
            }
            startupState.error = NSError(
                domain: "maclinq-mac",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to create CGEventTap; grant Accessibility access to the terminal or app running maclinq-mac in System Settings > Privacy & Security > Accessibility"
                ]
            )
            startupWaiter.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()

        withLockedState {
            eventTap = tap
            runLoopSource = source
            captureRunLoop = runLoop
        }

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startupWaiter.signal()
        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)

        let waiter = withLockedState { () -> DispatchSemaphore? in
            eventTap = nil
            runLoopSource = nil
            captureRunLoop = nil
            captureThread = nil
            let waiter = stopWaiter
            stopWaiter = nil
            return waiter
        }
        waiter?.signal()
    }

    @discardableResult
    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}

// MARK: - C-compatible CGEventTap callback

private func keyCaptureCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
    capture.handleEvent(proxy: proxy, type: type, event: event)
    switch type {
    case .keyDown, .keyUp, .flagsChanged:
        return nil
    default:
        return Unmanaged.passUnretained(event)
    }
}
