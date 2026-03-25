import CoreGraphics
import Foundation

enum MouseForwardEvent {
    case move(deltaX: Int16, deltaY: Int16)
    case buttonDown(UInt8)
    case buttonUp(UInt8)
    case scroll(deltaX: Int16, deltaY: Int16)
}

typealias MouseEventCallback = (MouseForwardEvent) -> Void

final class MouseCapture {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: MouseEventCallback?

    func start(callback: @escaping MouseEventCallback) throws {
        guard eventTap == nil else {
            throw NSError(
                domain: "maclinq-mac",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "mouse capture is already active"]
            )
        }
        self.callback = callback

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
            self.callback = nil
            throw NSError(
                domain: "maclinq-mac",
                code: 31,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to create mouse CGEventTap; grant Accessibility access to the terminal or app running maclinq-mac in System Settings > Privacy & Security > Accessibility"
                ]
            )
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)

        print("maclinq-mac: mouse capture started")
    }

    func stop() {
        guard eventTap != nil else {
            return
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }

        eventTap = nil
        runLoopSource = nil
        callback = nil
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
