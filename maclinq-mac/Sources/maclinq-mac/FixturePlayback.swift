import CoreGraphics
import Foundation

final class FixturePlayback {
    enum Step {
        case key(type: UInt8, keyCode: CGKeyCode, flags: CGEventFlags)
        case mouse(MouseForwardEvent)
        case sleep(milliseconds: UInt32)
    }

    private let steps: [Step]
    private let sourcePath: String
    private let queue = DispatchQueue(label: "maclinq.fixture-playback", qos: .userInitiated)

    init(path: String) throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        sourcePath = expandedPath
        steps = try Self.parse(path: expandedPath)
    }

    func play(
        forwardKey: @escaping (UInt8, CGKeyCode, CGEventFlags) -> Void,
        forwardMouse: @escaping (MouseForwardEvent) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        queue.async {
            for step in self.steps {
                switch step {
                case .key(let type, let keyCode, let flags):
                    forwardKey(type, keyCode, flags)
                case .mouse(let event):
                    forwardMouse(event)
                case .sleep(let milliseconds):
                    usleep(useconds_t(min(milliseconds, UInt32.max / 1000)) * 1000)
                }
            }
            completion(nil)
        }
    }

    private static func parse(path: String) throws -> [Step] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var steps: [Step] = []

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            do {
                steps.append(try parseLine(parts, lineNumber: index + 1))
            } catch {
                throw NSError(
                    domain: "maclinq-mac",
                    code: 40,
                    userInfo: [NSLocalizedDescriptionKey: "fixture parse error in \(path):\(index + 1): \(error.localizedDescription)"]
                )
            }
        }

        if steps.isEmpty {
            throw NSError(
                domain: "maclinq-mac",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "fixture file '\(path)' did not contain any executable steps"]
            )
        }

        return steps
    }

    private static func parseLine(_ parts: [String], lineNumber: Int) throws -> Step {
        guard let command = parts.first else {
            throw fixtureError("line \(lineNumber) is empty after tokenization")
        }

        switch command {
        case "key_down":
            guard parts.count == 3 else {
                throw fixtureError("key_down expects 2 arguments: <mac_keycode> <flags_raw>")
            }
            return .key(type: 0x01, keyCode: try parseKeyCode(parts[1]), flags: try parseFlags(parts[2]))
        case "key_up":
            guard parts.count == 3 else {
                throw fixtureError("key_up expects 2 arguments: <mac_keycode> <flags_raw>")
            }
            return .key(type: 0x02, keyCode: try parseKeyCode(parts[1]), flags: try parseFlags(parts[2]))
        case "flags_changed":
            guard parts.count == 2 else {
                throw fixtureError("flags_changed expects 1 argument: <flags_raw>")
            }
            return .key(type: 0x03, keyCode: 0, flags: try parseFlags(parts[1]))
        case "mouse_move":
            guard parts.count == 3 else {
                throw fixtureError("mouse_move expects 2 arguments: <dx> <dy>")
            }
            return .mouse(.move(deltaX: try parseSigned16(parts[1]), deltaY: try parseSigned16(parts[2])))
        case "mouse_down":
            guard parts.count == 2 else {
                throw fixtureError("mouse_down expects 1 argument: <left|right|middle>")
            }
            return .mouse(.buttonDown(try parseButton(parts[1])))
        case "mouse_up":
            guard parts.count == 2 else {
                throw fixtureError("mouse_up expects 1 argument: <left|right|middle>")
            }
            return .mouse(.buttonUp(try parseButton(parts[1])))
        case "scroll":
            guard parts.count == 3 else {
                throw fixtureError("scroll expects 2 arguments: <dx> <dy>")
            }
            return .mouse(.scroll(deltaX: try parseSigned16(parts[1]), deltaY: try parseSigned16(parts[2])))
        case "sleep_ms":
            guard parts.count == 2 else {
                throw fixtureError("sleep_ms expects 1 argument: <milliseconds>")
            }
            return .sleep(milliseconds: try parseUnsigned32(parts[1]))
        default:
            throw fixtureError("unknown fixture command '\(command)'")
        }
    }

    private static func parseKeyCode(_ value: String) throws -> CGKeyCode {
        let parsed = try parseUnsigned32(value)
        guard parsed <= UInt32(UInt16.max) else {
            throw fixtureError("mac keycode '\(value)' is out of range")
        }
        return CGKeyCode(parsed)
    }

    private static func parseFlags(_ value: String) throws -> CGEventFlags {
        CGEventFlags(rawValue: try parseUnsigned64(value))
    }

    private static func parseButton(_ value: String) throws -> UInt8 {
        switch value.lowercased() {
        case "left":
            return 0x01
        case "right":
            return 0x02
        case "middle":
            return 0x03
        default:
            throw fixtureError("unsupported mouse button '\(value)'")
        }
    }

    private static func parseUnsigned32(_ value: String) throws -> UInt32 {
        guard let parsed = UInt32(value.numericLiteral, radix: value.numericRadix) else {
            throw fixtureError("invalid unsigned integer '\(value)'")
        }
        return parsed
    }

    private static func parseUnsigned64(_ value: String) throws -> UInt64 {
        guard let parsed = UInt64(value.numericLiteral, radix: value.numericRadix) else {
            throw fixtureError("invalid unsigned integer '\(value)'")
        }
        return parsed
    }

    private static func parseSigned16(_ value: String) throws -> Int16 {
        if value.hasPrefix("-") {
            let digits = String(value.dropFirst())
            guard let parsed = Int16(digits.numericLiteral, radix: digits.numericRadix) else {
                throw fixtureError("invalid signed integer '\(value)'")
            }
            return -parsed
        }

        guard let parsed = Int16(value.numericLiteral, radix: value.numericRadix) else {
            throw fixtureError("invalid signed integer '\(value)'")
        }
        return parsed
    }

    private static func fixtureError(_ message: String) -> NSError {
        NSError(domain: "maclinq-mac", code: 42, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension String {
    var numericRadix: Int {
        lowercased().hasPrefix("0x") ? 16 : 10
    }

    var numericLiteral: String {
        lowercased().hasPrefix("0x") ? String(dropFirst(2)) : self
    }
}
