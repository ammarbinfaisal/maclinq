import CoreGraphics
import Foundation

enum MouseForwardEvent {
    case move(deltaX: Int16, deltaY: Int16)
    case buttonDown(UInt8)
    case buttonUp(UInt8)
    case scroll(deltaX: Int16, deltaY: Int16)
}

typealias MouseEventCallback = (MouseForwardEvent) -> Void

private final class MouseCaptureStartupState {
    var error: Error?
}

final class MouseCapture {
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var captureRunLoop: CFRunLoop?
    private var captureThread: Thread?
    private var stopWaiter: DispatchSemaphore?
    private var callback: MouseEventCallback?

    func start(callback: @escaping MouseEventCallback) throws {
        let startupWaiter = DispatchSemaphore(value: 0)
        let startupState = MouseCaptureStartupState()

        let thread = try withLockedState { () throws -> Thread in
            guard captureThread == nil else {
                throw NSError(
                    domain: "maclinq-mac",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "mouse capture is already active"]
                )
            }

            self.callback = callback

            let thread = Thread { [weak self] in
                self?.runCaptureLoop(startupWaiter: startupWaiter, startupState: startupState)
            }
            thread.name = "maclinq.mouse-capture"
            captureThread = thread
            return thread
        }

        thread.start()
        startupWaiter.wait()

        if let error = startupState.error {
            throw error
        }

        print("maclinq-mac: mouse capture started")
    }

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
        print("maclinq-mac: mouse capture stopped")
    }

    fileprivate func translatedEvent(type: CGEventType, event: CGEvent) -> MouseForwardEvent? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let deltaX = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaX))
            let deltaY = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaY))
            guard deltaX != 0 || deltaY != 0 else {
                return .move(deltaX: 0, deltaY: 0)
            }
            return .move(deltaX: deltaX, deltaY: deltaY)
        case .leftMouseDown:
            return .buttonDown(0x01)
        case .leftMouseUp:
            return .buttonUp(0x01)
        case .rightMouseDown:
            return .buttonDown(0x02)
        case .rightMouseUp:
            return .buttonUp(0x02)
        case .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            guard number == 2 else {
                fputs("maclinq-mac: unsupported auxiliary mouse button \(number); event left local\n", stderr)
                return nil
            }
            return type == .otherMouseDown ? .buttonDown(0x03) : .buttonUp(0x03)
        case .scrollWheel:
            let deltaX = Int16(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let deltaY = Int16(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            return .scroll(deltaX: deltaX, deltaY: deltaY)
        default:
            return nil
        }
    }

    fileprivate func reEnableTapIfNeeded(type: CGEventType) -> Bool {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return false
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        return true
    }

    fileprivate func emit(_ event: MouseForwardEvent) {
        callback?(event)
    }

    private func runCaptureLoop(startupWaiter: DispatchSemaphore, startupState: MouseCaptureStartupState) {
        let trackedTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
        ]
        let eventMask = trackedTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: mouseCaptureCallback,
            userInfo: selfPtr
        ) else {
            withLockedState {
                callback = nil
                captureThread = nil
            }
            startupState.error = NSError(
                domain: "maclinq-mac",
                code: 31,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to create mouse CGEventTap; grant Accessibility access to the terminal or app running maclinq-mac in System Settings > Privacy & Security > Accessibility"
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

private func mouseCaptureCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = proxy

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let capture = Unmanaged<MouseCapture>.fromOpaque(userInfo).takeUnretainedValue()
    if capture.reEnableTapIfNeeded(type: type) {
        return Unmanaged.passUnretained(event)
    }

    guard let translated = capture.translatedEvent(type: type, event: event) else {
        return Unmanaged.passUnretained(event)
    }

    capture.emit(translated)
    return nil
}
