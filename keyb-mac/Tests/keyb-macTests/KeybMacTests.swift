import CoreGraphics
import XCTest
@testable import keyb_mac

final class KeybMacTests: XCTestCase {
    func testHandshakePacketLayout() {
        XCTAssertEqual(Array(TCPSender.handshakePacket()), [0x4B, 0x45, 0x59, 0x42, 0x01, 0x00])
    }

    func testKeyEventPacketUsesBigEndianLayout() {
        let packet = Array(TCPSender.keyEventPacket(type: 0x01, keycode: 0x1234, modifiers: 0xA5, timestampMs: 0x01020304))
        XCTAssertEqual(packet, [0x01, 0x12, 0x34, 0xA5, 0x01, 0x02, 0x03, 0x04])
    }

    func testControlPacketLayout() {
        let packet = Array(TCPSender.controlPacket(type: 0x10))
        XCTAssertEqual(packet, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
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
}
