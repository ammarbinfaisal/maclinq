import CoreGraphics
import XCTest
@testable import maclinq_mac

final class MaclinqMacTests: XCTestCase {
    func testHandshakePacketLayout() {
        XCTAssertEqual(Array(TCPSender.handshakePacket()), [0x4D, 0x43, 0x4C, 0x51, 0x01, 0x00])
    }

    func testKeyEventPacketUsesBigEndianLayout() {
        let packet = Array(TCPSender.keyEventPacket(type: 0x01, keycode: 0x1234, modifiers: 0xA5, timestampMs: 0x01020304))
        XCTAssertEqual(packet, [0x01, 0x12, 0x34, 0xA5, 0x01, 0x02, 0x03, 0x04])
    }

    func testControlPacketLayout() {
        let packet = Array(TCPSender.controlPacket(type: 0x10))
        XCTAssertEqual(packet, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testMouseMovePacketUsesBigEndianSignedDeltas() {
        let packet = Array(TCPSender.mouseMovePacket(deltaX: 12, deltaY: -8))
        XCTAssertEqual(packet, [0x20, 0x00, 0x0C, 0xFF, 0xF8, 0x00, 0x00, 0x00])
    }

    func testMouseButtonPacketLayout() {
        let packet = Array(TCPSender.mouseButtonPacket(type: 0x21, button: 0x02))
        XCTAssertEqual(packet, [0x21, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testMouseScrollPacketLayout() {
        let packet = Array(TCPSender.mouseScrollPacket(deltaX: 0, deltaY: -1))
        XCTAssertEqual(packet, [0x23, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00])
    }

    func testKeyMapperUsesCorrectMAndPeriodMappings() {
        XCTAssertEqual(KeyMapper.mapKeyCode(0x2E), 50)
        XCTAssertEqual(KeyMapper.mapKeyCode(0x2F), 52)
    }

    func testCommandMapsToLeftControlModifierBit() {
        XCTAssertEqual(KeyMapper.mapModifiers(.maskCommand), 0x01)
    }

    func testShiftAndOptionMapToLinuxModifierBits() {
        let flags: CGEventFlags = [.maskShift, .maskAlternate]
        XCTAssertEqual(KeyMapper.mapModifiers(flags) & 0x02, 0x02)
        XCTAssertEqual(KeyMapper.mapModifiers(flags) & 0x04, 0x04)
    }

    func testFixturePlaybackParsesKeyboardAndMouseSteps() throws {
        let tempDir = try XCTUnwrap(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) as URL?)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fixtureURL = tempDir.appendingPathComponent("fixture.txt")
        try """
        # comment
        key_down 0x08 0
        key_up 0x08 0
        mouse_down left
        mouse_move 12 -8
        mouse_up left
        scroll 0 -1
        sleep_ms 5
        """.write(to: fixtureURL, atomically: true, encoding: .utf8)

        let playback = try FixturePlayback(path: fixtureURL.path)
        let finished = expectation(description: "fixture completion")
        var events: [String] = []

        playback.play(
            forwardKey: { type, keyCode, flags in
                events.append("key:\(type):\(keyCode):\(flags.rawValue)")
            },
            forwardMouse: { event in
                switch event {
                case .move(let dx, let dy):
                    events.append("move:\(dx):\(dy)")
                case .buttonDown(let button):
                    events.append("down:\(button)")
                case .buttonUp(let button):
                    events.append("up:\(button)")
                case .scroll(let dx, let dy):
                    events.append("scroll:\(dx):\(dy)")
                }
            },
            completion: { error in
                XCTAssertNil(error)
                finished.fulfill()
            }
        )

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(
            events,
            [
                "key:1:8:0",
                "key:2:8:0",
                "down:1",
                "move:12:-8",
                "up:1",
                "scroll:0:-1"
            ]
        )
    }
}
