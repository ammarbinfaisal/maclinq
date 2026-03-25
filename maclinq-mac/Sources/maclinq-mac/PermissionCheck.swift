import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionCheck {
    static func validateInteractiveCapturePermissions() throws {
        var missing: [String] = []

        if !AXIsProcessTrusted() {
            missing.append("Accessibility")
        }

        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            missing.append("Input Monitoring")
        }

        guard !missing.isEmpty else {
            return
        }

        let processHint = [
            "Grant access to the app that launches Maclinq",
            "Examples: Terminal, iTerm, Ghostty, or a packaged Maclinq app",
            "Then fully quit and relaunch that app before starting Maclinq again",
        ].joined(separator: ". ")

        throw NSError(
            domain: "maclinq-mac",
            code: 60,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "missing required macOS permission\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", ")). Open System Settings > Privacy & Security and grant them. \(processHint)."
            ]
        )
    }
}
