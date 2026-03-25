# Protocol v2 Draft

This is a draft for a platform-neutral Maclinq protocol intended to support:
- Mac to Linux
- Linux to Mac
- Android to Linux
- Android to Mac

It is not implemented yet. It exists to pin down the transport contract before
the platform adapters are refactored.

## Design Goals

The v2 protocol should:
- stop treating Linux evdev codes as the wire-format truth
- allow endpoints to advertise what they can capture and inject
- keep the wire model semantic instead of platform-specific
- preserve low-latency local-network behavior
- remain simple enough for native implementations in Swift, C, and Android

## Terms

- `controller endpoint`: the side that originates a session and requests remote control
- `executor endpoint`: the side that accepts a session and applies remote input locally
- `capability`: a feature the endpoint can capture or inject
- `semantic event`: an event described in platform-neutral terms

These terms describe session roles, not operating systems.

## Session Model

The current v1 client/server split is acceptable for transport bootstrapping,
but the protocol needs capability negotiation after connection.

The initial sequence should be:

1. TCP connection established
2. `hello` from controller endpoint
3. `hello_ack` from executor endpoint
4. optional `session_config`
5. event streaming begins

## Hello

Both sides should describe:
- protocol version
- endpoint platform
- endpoint role support
- capture capabilities
- inject capabilities
- optional human-readable name

### Example Fields

| Field | Purpose |
|-------|---------|
| `version_major` | incompatible protocol version |
| `version_minor` | backward-compatible feature version |
| `platform` | `macos`, `linux`, `android`, `unknown` |
| `supports_capture` | endpoint can capture local input |
| `supports_inject` | endpoint can inject remote input |
| `capabilities` | feature bitset or capability list |
| `device_name` | optional display/debug string |

## Capability Model

The first capability set should likely include:
- `keyboard`
- `pointer_relative`
- `pointer_buttons`
- `scroll`
- `text_input`
- `media_keys`
- `clipboard_sync`
- `gesture_basic`

Not every v2 endpoint needs every capability. The negotiated session should
use the intersection of controller and executor support.

## Semantic Event Model

The protocol needs semantic events that can be translated at the platform
boundaries.

### Keyboard

The key identity should not be a Linux evdev number.

The wire should instead use a semantic key enum or usage code namespace such
as:
- letters and digits
- function keys
- arrows
- editing/navigation keys
- modifiers
- media/system keys

Two realistic choices are:

1. HID usage page based key identities
2. a Maclinq-defined semantic enum inspired by HID usage names

Recommendation:
- use HID-style usage identities where possible
- reserve Maclinq extension ranges for keys that do not fit neatly

### Pointer

Pointer events should be semantic:
- relative move
- button down
- button up
- scroll

That matches what Maclinq already does conceptually, but v2 should make the
fields explicit and platform-neutral from the start.

### Text

v2 should reserve space for text input events even if not implemented in the
first runtime pass.

Reason:
- Android and some IME-heavy setups do not map cleanly to raw keypresses
- remote text insertion can be a better fallback than raw key transport in
  some environments

## Proposed Packet Families

This is a suggested top-level packet taxonomy:

| Family | Purpose |
|--------|---------|
| `0x00-0x0F` | session and handshake |
| `0x10-0x1F` | control and liveness |
| `0x20-0x2F` | keyboard semantic events |
| `0x30-0x3F` | pointer semantic events |
| `0x40-0x4F` | text and composition |
| `0x50-0x5F` | diagnostics and logging |

## Draft Messages

### `hello`

Contains:
- protocol version
- platform
- role support
- capability bitset
- endpoint name length + bytes

### `hello_ack`

Contains:
- accepted version
- acceptance status
- negotiated capability bitset
- optional reason code if rejected

### `session_config`

Contains negotiated runtime settings such as:
- heartbeat interval
- idle timeout
- pointer mode
- scroll mode
- optional acceleration hinting flags

### `key_event`

Contains:
- semantic key identity
- action: down/up/repeat
- modifier state snapshot
- timestamp

### `pointer_move`

Contains:
- relative dx
- relative dy
- timestamp

### `pointer_button`

Contains:
- button identity
- action down/up
- timestamp

### `scroll`

Contains:
- horizontal delta
- vertical delta
- source kind if useful later
- timestamp

## Translation Boundary

The branch should treat translation as an edge concern:

`native event -> semantic Maclinq event -> wire -> semantic Maclinq event -> native event`

This is the core abstraction needed to make:
- Linux capture feed Mac injection
- Android capture feed Linux injection
- future Mac injection work possible without redesigning the transport again

## Platform Notes

### macOS

- capture: Quartz event taps
- inject: likely Quartz event posting
- challenge: permissions and local suppression semantics

### Linux

- capture: likely `libinput`/`evdev` with exclusive grab or compositor-aware hooks
- inject: `/dev/uinput`
- challenge: capture strategy differs a lot by environment

### Android

- capture: likely Accessibility Service, not plain Termux
- inject: likely Accessibility-driven actions or dedicated app hooks
- challenge: permissions and OS restrictions dominate the design

## Compatibility Plan

The migration path should be:

1. keep v1 in place for the current stable path
2. implement a shared semantic event model internally
3. add v2 behind a feature flag or separate binaries first
4. only retire v1 after Mac/Linux v2 parity exists

## Open Design Questions

These are the decisions that may need explicit product/UX input later:

1. Should Maclinq standardize on HID usage identities or define its own key enum?
2. Should the controller always initiate the TCP session, or should peer mode exist?
3. Should Android be a first-class source endpoint only at first, or source and sink together?
4. Should text input be part of the first v2 runtime, or deferred until raw input parity is stable?

If any of those affect how you want the user-facing flow to work, that is the
point where I should stop and ask you before locking the branch design in.
