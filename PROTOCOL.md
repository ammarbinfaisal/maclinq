# Maclinq Binary Protocol Specification v1

## Overview

Maclinq uses a simple binary protocol over TCP for streaming keyboard and
mouse events from a Mac sender to a Linux receiver. Both sides must implement
this protocol identically to ensure interoperability.

## Connection

- Transport: TCP
- Port: operator-selected; both endpoints must use the same TCP port
- No TLS by default (optional encryption layer planned)
- Mac connects to Linux (Linux is the server)

## Handshake

On connection, the Mac client sends a handshake packet. The Linux server
responds with an acknowledgment. No further handshake is needed.

### Handshake Request (Client → Server)

| Offset | Size | Field         | Value / Description            |
|--------|------|---------------|--------------------------------|
| 0      | 4    | magic         | `0x4D434C51` ("MCLQ")          |
| 4      | 1    | version       | `0x01`                         |
| 5      | 1    | reserved      | `0x00`                         |

Total: **6 bytes**

### Handshake Response (Server → Client)

| Offset | Size | Field         | Value / Description            |
|--------|------|---------------|--------------------------------|
| 0      | 4    | magic         | `0x4D434C51` ("MCLQ")          |
| 4      | 1    | version       | `0x01`                         |
| 5      | 1    | status        | `0x00` = OK, `0x01` = rejected |

Total: **6 bytes**

## Key Event Packet (Client → Server)

After handshake, the client streams keyboard events:

| Offset | Size | Field         | Value / Description                   |
|--------|------|---------------|---------------------------------------|
| 0      | 1    | type          | `0x01` = key_down, `0x02` = key_up, `0x03` = flags_changed |
| 1      | 2    | keycode       | Linux evdev keycode (uint16, network byte order) |
| 3      | 1    | modifiers     | Bitmask (see below)                   |
| 4      | 4    | timestamp_ms  | Milliseconds since connection (uint32, network byte order) |

Total: **8 bytes** per event

### Modifier Bitmask

| Bit | Modifier        |
|-----|-----------------|
| 0   | Left Ctrl       |
| 1   | Left Shift      |
| 2   | Left Alt        |
| 3   | Left Meta/Super |
| 4   | Right Ctrl      |
| 5   | Right Shift     |
| 6   | Right Alt       |
| 7   | Right Meta/Super|

Note: The Mac sender maps Cmd → Ctrl, Option → Alt before sending.
The modifiers field reflects the **Linux-side** modifier state.

## Mouse Packets (Client → Server)

Maclinq v1 forwards relative mouse motion, button transitions, and scroll
wheel deltas. Gesture semantics stay on the Mac side; the sender only emits
the interpreted pointer events.

### Relative Mouse Move

| Offset | Size | Field | Value / Description |
|--------|------|-------|---------------------|
| 0      | 1    | type  | `0x20` = mouse_move |
| 1      | 2    | dx    | Signed relative X delta (`int16`, network byte order) |
| 3      | 2    | dy    | Signed relative Y delta (`int16`, network byte order) |
| 5      | 3    | pad   | `0x00` |

Total: **8 bytes**

### Mouse Button

| Offset | Size | Field  | Value / Description |
|--------|------|--------|---------------------|
| 0      | 1    | type   | `0x21` = button_down, `0x22` = button_up |
| 1      | 1    | button | `0x01` = left, `0x02` = right, `0x03` = middle |
| 2      | 6    | pad    | `0x00` |

Total: **8 bytes**

### Scroll

| Offset | Size | Field | Value / Description |
|--------|------|-------|---------------------|
| 0      | 1    | type  | `0x23` = scroll |
| 1      | 2    | dx    | Signed horizontal wheel delta (`int16`, network byte order) |
| 3      | 2    | dy    | Signed vertical wheel delta (`int16`, network byte order) |
| 5      | 3    | pad   | `0x00` |

Total: **8 bytes**

Notes:
- Mouse packets are relative; the sender does not transmit absolute cursor coordinates.
- Dragging is represented as a button-down packet plus subsequent relative move packets.
- Two-finger scrolling is represented as scroll packets. Higher-level gestures are out of scope for v1.

## Control Packets (Client → Server)

| Offset | Size | Field    | Value / Description              |
|--------|------|----------|----------------------------------|
| 0      | 1    | type     | `0x10` = heartbeat, `0x11` = disconnect |
| 1      | 7    | padding  | `0x00` (pad to 8 bytes)          |

Total: **8 bytes**

The client sends heartbeats every 2 seconds. If the server receives no
data for 5 seconds, it should consider the client disconnected.

## Keycode Mapping

The Mac sender translates macOS virtual keycodes to Linux evdev keycodes
before sending. The mapping table covers the standard US keyboard layout.
Both sides use Linux evdev keycodes as the canonical representation.

## Byte Order

All multi-byte integers use **network byte order** (big-endian).

## Toggle Protocol (Mac-local, Unix Socket)

The Karabiner toggle sends a single byte over a Unix domain socket at
`/tmp/maclinq.sock`:

| Value  | Meaning |
|--------|---------|
| `0x01` | Toggle (flip current state) |
| `0x02` | Force ON |
| `0x03` | Force OFF |
| `0x04` | Query status (server replies with `0x01`=active, `0x00`=inactive) |
