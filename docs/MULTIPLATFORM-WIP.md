# Multiplatform WIP

This branch is the first pass at abstracting Maclinq away from a single
hardcoded direction.

Today the stable implementation is effectively:

`macOS capture -> TCP transport -> Linux uinput injection`

That works, but it couples the codebase and the wire model to one source
platform and one destination platform.

## Problem Statement

To support these combinations cleanly:
- Linux to Mac
- Mac to Linux
- Android to Mac
- Android to Linux

Maclinq needs to stop treating "Mac" as always the sender and "Linux" as
always the receiver.

The project needs to be modeled as:
- an endpoint that can capture input
- an endpoint that can inject input
- a transport/session layer between them
- a translation layer between native platform events and the wire format

## Current Coupling

The main blockers in the current code are:

1. The wire protocol uses Linux evdev keycodes as the canonical key identity.
   That makes the protocol destination-biased toward Linux injection.

2. The session model assumes the Mac side is always the TCP client and the
   Linux side is always the TCP server.

3. The control plane is Mac-local today.
   The toggle socket and Karabiner integration are useful, but they are not a
   generic endpoint control model.

4. Capture and injection are described by platform names rather than by
   capability.
   That is fine for v1, but it does not scale once an endpoint can be either a
   source, a sink, or both.

## Neutral Model

The branch should move Maclinq toward these concepts:

### Endpoint Roles

- `capture`: produces local input events
- `inject`: applies remote input events locally
- `control`: enables, disables, or inspects a session
- `transport`: owns connection establishment and liveness

An endpoint can implement one or more roles.

Examples:
- A Mac laptop in the current setup implements `capture` and `control`
- The Linux target implements `inject` and `transport`
- A future Mac target would implement `inject`
- A future Linux source would implement `capture`

### Event Pipeline

Every path should be expressed as:

`native capture -> semantic Maclinq event -> transport -> native injection`

That gives us a stable middle layer even if the capture and injection APIs are
different on each platform.

### Platform Capability Matrix

| Platform | Capture | Inject | Notes |
|----------|---------|--------|-------|
| macOS    | Yes     | Planned | Capture is already implemented through Quartz event taps |
| Linux    | Planned | Yes     | Injection exists through `/dev/uinput`; capture likely needs `libinput` or `evdev` grab |
| Android  | Partial/Planned | Planned | Termux alone is not enough for full global capture or low-latency injection |

## Wire Direction

The transport should be independent from platform naming.

The branch should use these terms going forward:
- `controller endpoint`: initiates a session
- `executor endpoint`: receives and applies remote input

Those names are still directional, but they are not platform-specific.

Later, Maclinq may need a more symmetric discovery/session model where either
side can initiate the TCP connection depending on network constraints.

## Protocol Direction

The current v1 packet format is still usable for the existing path, but it is
not the right long-term abstraction because:
- key identity is Linux-specific
- pointer events are injection-oriented rather than semantic
- there is no capability negotiation

The likely path forward is:

1. Keep v1 support for the current Mac-to-Linux workflow.
2. Define a v2 protocol with:
   - endpoint hello/capability negotiation
   - semantic key identities instead of Linux-only evdev codes
   - semantic pointer and scroll events
   - optional feature flags for buttons, scrolling, text input, and gestures
3. Add per-platform translation layers at the edges.

The first draft of that protocol now lives in
[`docs/PROTOCOL-V2-DRAFT.md`](docs/PROTOCOL-V2-DRAFT.md).

## Android Notes

### Termux

Termux is useful for:
- configuration
- session control
- scripted or fixture-driven testing
- a CLI/TUI launcher

Termux alone is usually not enough for a full Android source endpoint because
Android does not normally expose global keyboard and pointer capture to a plain
terminal process.

### Practical Android Options

The most realistic Android paths are:

1. A small Android app with an Accessibility Service.
   This is the best option for global capture and a usable user-facing flow.

2. A hybrid model:
   - Termux handles config, transport launching, and logs
   - a thin Android app provides capture and injection bindings

3. Root-only input access through `/dev/input`.
   Technically possible, but not a good default product path.

### Recommendation

If Android is a serious target, the clean path is:
- keep a terminal-friendly control layer
- add a minimal Android app for the actual capture/inject permissions

## Near-Term Refactor Plan

The first meaningful steps are:

1. Rename internal concepts from sender/receiver to endpoint roles.
2. Separate native capture/inject code from session orchestration.
3. Introduce a semantic event model that is not Linux-keycode-first.
4. Keep the current v1 implementation working while v2 is designed.

The next code milestone after this draft is to introduce a shared internal
event model in both implementations so v1 platform code can be adapted behind
that semantic layer before the transport is changed.

## Branch Intent

This branch is the place to do the above refactor without destabilizing
`main`.
