import CoreGraphics

enum KeyMapper {
    // Maps macOS CGKeyCode to Linux evdev keycode
    static let keyCodeMap: [CGKeyCode: UInt16] = [
        // Letters
        0x00: 30,  // A → KEY_A
        0x01: 31,  // S → KEY_S
        0x02: 32,  // D → KEY_D
        0x03: 33,  // F → KEY_F
        0x04: 35,  // H → KEY_H
        0x05: 34,  // G → KEY_G
        0x06: 44,  // Z → KEY_Z
        0x07: 45,  // X → KEY_X
        0x08: 46,  // C → KEY_C
        0x09: 47,  // V → KEY_V
        0x0B: 48,  // B → KEY_B
        0x0C: 16,  // Q → KEY_Q
        0x0D: 17,  // W → KEY_W
        0x0E: 18,  // E → KEY_E
        0x0F: 19,  // R → KEY_R
        0x10: 21,  // Y → KEY_Y
        0x11: 20,  // T → KEY_T
        // Numbers and symbols
        0x12: 2,   // 1 → KEY_1
        0x13: 3,   // 2 → KEY_2
        0x14: 4,   // 3 → KEY_3
        0x15: 5,   // 4 → KEY_4
        0x16: 7,   // 6 → KEY_6
        0x17: 6,   // 5 → KEY_5
        0x18: 13,  // = → KEY_EQUAL
        0x19: 10,  // 9 → KEY_9
        0x1A: 8,   // 7 → KEY_7
        0x1B: 12,  // - → KEY_MINUS
        0x1C: 9,   // 8 → KEY_8
        0x1D: 11,  // 0 → KEY_0
        0x1E: 27,  // ] → KEY_RIGHTBRACE
        0x1F: 24,  // O → KEY_O
        0x20: 22,  // U → KEY_U
        0x21: 26,  // [ → KEY_LEFTBRACE
        0x22: 23,  // I → KEY_I
        0x23: 25,  // P → KEY_P
        0x24: 28,  // Return → KEY_ENTER
        0x25: 38,  // L → KEY_L
        0x26: 36,  // J → KEY_J
        0x27: 40,  // ' → KEY_APOSTROPHE
        0x28: 37,  // K → KEY_K
        0x29: 39,  // ; → KEY_SEMICOLON
        0x2A: 43,  // \ → KEY_BACKSLASH
        0x2B: 51,  // , → KEY_COMMA
        0x2C: 53,  // / → KEY_SLASH
        0x2D: 49,  // N → KEY_N
        0x2E: 50,  // M → KEY_M
        0x2F: 52,  // . → KEY_DOT
        0x30: 15,  // Tab → KEY_TAB
        0x31: 57,  // Space → KEY_SPACE
        0x32: 41,  // ` → KEY_GRAVE
        0x33: 14,  // Delete/Backspace → KEY_BACKSPACE
        0x35: 1,   // Escape → KEY_ESC
        // Modifiers
        0x37: 125, // Left Cmd → KEY_LEFTMETA
        0x38: 42,  // Left Shift → KEY_LEFTSHIFT
        0x39: 58,  // Caps Lock → KEY_CAPSLOCK
        0x3A: 56,  // Left Option → KEY_LEFTALT
        0x3B: 29,  // Left Control → KEY_LEFTCTRL
        0x3C: 54,  // Right Shift → KEY_RIGHTSHIFT
        0x3D: 100, // Right Option → KEY_RIGHTALT
        0x3E: 97,  // Right Control → KEY_RIGHTCTRL
        // Function keys
        0x7A: 59,  // F1 → KEY_F1
        0x78: 60,  // F2 → KEY_F2
        0x63: 61,  // F3 → KEY_F3
        0x76: 62,  // F4 → KEY_F4
        0x60: 63,  // F5 → KEY_F5
        0x61: 64,  // F6 → KEY_F6
        0x62: 65,  // F7 → KEY_F7
        0x64: 66,  // F8 → KEY_F8
        0x65: 67,  // F9 → KEY_F9
        0x6D: 68,  // F10 → KEY_F10
        0x67: 69,  // F11 → KEY_F11
        0x6F: 70,  // F12 → KEY_F12
        0x69: 183, // F13 → KEY_F13
        // Navigation
        0x73: 102, // Home → KEY_HOME
        0x74: 104, // Page Up → KEY_PAGEUP
        0x75: 111, // Forward Delete → KEY_DELETE
        0x77: 107, // End → KEY_END
        0x79: 109, // Page Down → KEY_PAGEDOWN
        0x7B: 105, // Left Arrow → KEY_LEFT
        0x7C: 106, // Right Arrow → KEY_RIGHT
        0x7D: 108, // Down Arrow → KEY_DOWN
        0x7E: 103, // Up Arrow → KEY_UP
    ]

    /// Maps a macOS CGKeyCode to a Linux evdev keycode.
    /// Returns nil if no mapping exists.
    static func mapKeyCode(_ macKeyCode: CGKeyCode) -> UInt16? {
        return keyCodeMap[macKeyCode]
    }

    /// Maps CGEventFlags to a Linux-side modifier bitmask.
    ///
    /// Bit assignments:
    ///   0 = LCtrl   (Mac: Left Cmd or Left Control)
    ///   1 = LShift  (Mac: Left Shift)
    ///   2 = LAlt    (Mac: Left Option)
    ///   3 = LMeta   (currently unused after Cmd→Ctrl remapping)
    ///   4 = RCtrl   (Mac: Right Control)
    ///   5 = RShift  (Mac: Right Shift)
    ///   6 = RAlt    (Mac: Right Option)
    ///   7 = RMeta   (currently unused)
    static func mapModifiers(_ flags: CGEventFlags) -> UInt8 {
        var result: UInt8 = 0

        // Left Command → Linux LCtrl (bit 0)
        if flags.contains(.maskCommand) {
            result |= (1 << 0)
        }
        // Left Control → Linux LCtrl (bit 0)
        if flags.contains(.maskControl) {
            result |= (1 << 0)
        }
        // Left Shift → Linux LShift (bit 1)
        if flags.contains(.maskShift) {
            result |= (1 << 1)
        }
        // Left Option → Linux LAlt (bit 2)
        if flags.contains(.maskAlternate) {
            result |= (1 << 2)
        }
        // Right Control → Linux RCtrl (bit 4)
        // CGEventFlags doesn't have separate left/right for control;
        // we handle right modifiers via secondary flag bits below.
        // Right Shift (bit 5), Right Alt (bit 6) handled through
        // the secondary (device-specific) flags when available.

        // CGEventFlags secondary bits for distinguishing left/right
        // These are device-dependent flags; use the raw value approach.
        let raw = flags.rawValue

        // Right Shift: bit 0x0002_0004 area — use NX_DEVICERSHIFTKEYMASK
        let NX_DEVICELSHIFTKEYMASK:  UInt64 = 0x0000_0002
        let NX_DEVICERSHIFTKEYMASK:  UInt64 = 0x0000_0004
        let NX_DEVICELCMDKEYMASK:    UInt64 = 0x0000_0008
        let NX_DEVICERCMDKEYMASK:    UInt64 = 0x0000_0010
        let NX_DEVICELALTKEYMASK:    UInt64 = 0x0000_0020
        let NX_DEVICERALTKEYMASK:    UInt64 = 0x0000_0040
        let NX_DEVICELCTLKEYMASK:    UInt64 = 0x0000_0001
        let NX_DEVICERCTLKEYMASK:    UInt64 = 0x0000_2000

        // Re-derive more precisely with device-specific bits when shift is active
        if flags.contains(.maskShift) {
            // Reset the shift bits set above and re-assign per side
            result &= ~(1 << 1) // clear LShift
            result &= ~(1 << 5) // clear RShift

            if (raw & NX_DEVICELSHIFTKEYMASK) != 0 {
                result |= (1 << 1) // LShift
            }
            if (raw & NX_DEVICERSHIFTKEYMASK) != 0 {
                result |= (1 << 5) // RShift
            }
            // If neither device-specific bit fired, fall back to LShift
            if (raw & (NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK)) == 0 {
                result |= (1 << 1)
            }
        }

        if flags.contains(.maskAlternate) {
            // Reset alt bits and re-assign per side
            result &= ~(1 << 2) // clear LAlt
            result &= ~(1 << 6) // clear RAlt

            if (raw & NX_DEVICELALTKEYMASK) != 0 {
                result |= (1 << 2) // LAlt
            }
            if (raw & NX_DEVICERALTKEYMASK) != 0 {
                result |= (1 << 6) // RAlt
            }
            if (raw & (NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)) == 0 {
                result |= (1 << 2)
            }
        }

        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Reset ctrl bits and re-assign per side
            result &= ~(1 << 0) // clear LCtrl
            result &= ~(1 << 4) // clear RCtrl

            // Left Cmd → LCtrl
            if (raw & NX_DEVICELCMDKEYMASK) != 0 {
                result |= (1 << 0)
            }
            // Right Cmd → RCtrl (optional — not commonly remapped, but for consistency)
            if (raw & NX_DEVICERCMDKEYMASK) != 0 {
                result |= (1 << 4)
            }
            // Left Control → LCtrl
            if (raw & NX_DEVICELCTLKEYMASK) != 0 {
                result |= (1 << 0)
            }
            // Right Control → RCtrl
            if (raw & NX_DEVICERCTLKEYMASK) != 0 {
                result |= (1 << 4)
            }

            // Fallback if no device-specific bits
            let ctlCmdBits = NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK |
                             NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK
            if (raw & ctlCmdBits) == 0 {
                if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                    result |= (1 << 0)
                }
            }
        }

        return result
    }
}
