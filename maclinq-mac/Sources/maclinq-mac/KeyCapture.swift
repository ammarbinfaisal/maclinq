import CoreGraphics
import Foundation

/// Callback type for captured keyboard events.
/// Parameters: eventType (1=keyDown,2=keyUp,3=flagsChanged), keyCode, flags
typealias KeyEventCallback = (UInt8, CGKeyCode, CGEventFlags) -> Void

final class KeyCapture {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: KeyEventCallback?

    /// Start capturing keyboard events, calling `callback` for each event.
    func start(callback: @escaping KeyEventCallback) throws {
        guard eventTap == nil else {
            throw NSError(
                domain: "maclinq-mac",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "keyboard capture is already active"]
            )
        }
        self.callback = callback

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: keyCaptureCallback,
            userInfo: selfPtr
        ) else {
            self.callback = nil
            throw NSError(
                domain: "maclinq-mac",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to create CGEventTap; grant Accessibility access to the terminal or app running maclinq-mac in System Settings > Privacy & Security > Accessibility"
                ]
            )
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("maclinq-mac: keyboard capture started")
    }

    /// Stop capturing keyboard events.
    func stop() {
        guard eventTap != nil else {
            return
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        callback = nil
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
