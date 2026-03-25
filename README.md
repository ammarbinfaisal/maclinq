# Maclinq

Maclinq forwards keyboard and mouse input from a Mac to a Linux machine over a
local TCP connection. The Mac side captures keyboard, pointer movement,
clicks, and scroll, then the Linux side injects those events through
`/dev/uinput`.

## Cross-Platform WIP

This branch, `wip/multiplatform-flow-abstraction`, is a work-in-progress
refactor to make Maclinq role- and platform-neutral instead of hardwiring the
project to "Mac sender -> Linux receiver".

The target shape is:
- Linux to Mac
- Mac to Linux
- Android to Mac
- Android to Linux

The architectural notes for that work live in
[`docs/MULTIPLATFORM-WIP.md`](docs/MULTIPLATFORM-WIP.md).

This branch is for design and abstraction work, not for production stability.
`main` remains the stable branch for the current Mac-to-Linux path.

Current v1 scope:
- Keyboard forwarding
- Relative mouse movement
- Left, right, and middle click
- Dragging
- Scroll wheel forwarding

Out of scope in v1:
- Higher-level trackpad gestures
- Encryption
- WAN usage

## Repository Layout

- `maclinq-mac/`: current macOS endpoint implementation
- `maclinq-linux/`: current Linux endpoint implementation
- `karabiner/`: Karabiner toggle rule for normal Mac usage
- `scripts/maclinq-toggle.sh`: local toggle helper for the Mac sender
- `scripts/test-maclinq-e2e.sh`: scripted end-to-end verification
- `docs/`: architecture and work-in-progress notes
- `PROTOCOL.md`: wire protocol

## Prerequisites

### Mac

- macOS 13 or newer
- Swift 5.9 toolchain or newer
- Accessibility permission for the app or terminal running `maclinq-mac`
- Karabiner-Elements if you want the hotkey toggle flow

### Linux

- GCC and `make`
- A kernel with `uinput` available
- Permission to open `/dev/uinput`
  In practice this usually means running the receiver with `sudo`

## Install And Build

### 1. Build the Mac sender

```bash
cd maclinq-mac
swift build
swift test
```

The sender binary will be available through `swift run maclinq-mac` or in the
SwiftPM build output.

### 2. Build the Linux receiver

```bash
cd maclinq-linux
make test
make
```

This produces `maclinq-receiver`.

## Setup

### 1. Start the Linux receiver

On the Linux machine:

```bash
cd maclinq-linux
sudo ./maclinq-receiver
```

Useful options:

```bash
sudo ./maclinq-receiver --port 7766
sudo ./maclinq-receiver --event-log /tmp/maclinq-events.log
sudo ./maclinq-receiver --once
```

Notes:
- Default port is `7680`
- `--event-log` writes a line-oriented log of injected events, which is useful
  for debugging and automated verification
- `--once` exits after a single client session ends

### 2. Start the Mac sender

On the Mac:

```bash
cd maclinq-mac
swift run maclinq-mac 192.168.1.10 7680
```

If you omit arguments, the sender defaults to `192.168.1.19:7680`.

Normal mode starts a local Unix socket at `/tmp/maclinq.sock` and waits for a
toggle command.

### 3. Grant Accessibility permission

The process running `maclinq-mac` must be allowed under:

`System Settings > Privacy & Security > Accessibility`

Without this, macOS will refuse to create the keyboard and mouse event taps.

### 4. Optional: install the Karabiner toggle

Follow [`karabiner/README-install.md`](karabiner/README-install.md).

The bundled rule gives you:
- `Cmd+F12` to toggle forwarding
- `Cmd+Shift+F12` to force forwarding off

## Usage

### Toggle forwarding from the Mac

With Karabiner installed:
- Press `Cmd+F12` to toggle on or off
- Press `Cmd+Shift+F12` for an emergency off

Without Karabiner:

```bash
./scripts/maclinq-toggle.sh toggle
./scripts/maclinq-toggle.sh on
./scripts/maclinq-toggle.sh off
./scripts/maclinq-toggle.sh status
```

### What happens when forwarding is active

- Local keyboard events are suppressed and forwarded to Linux
- Local mouse movement, button events, and scroll are suppressed and forwarded
  to Linux
- The Linux receiver injects those events through a virtual input device

### Fixture mode

Fixture mode is useful for scripted testing and packet-path verification.

```bash
cd maclinq-mac
swift run maclinq-mac --fixture ../scripts/fixtures/e2e.fixture 192.168.1.10 7766
```

That mode:
- Connects immediately
- Replays scripted events
- Disconnects and exits

## End-To-End Verification

The repository includes a scripted e2e harness that:
- Runs Swift tests on the Mac side
- Moves the Linux receiver sources to the remote host
- Builds and starts the Linux receiver remotely
- Replays a fixture from the Mac sender
- Verifies that the Linux receiver logged the expected injected events

Example:

```bash
MACLINQ_E2E_REMOTE_HOST=192.168.1.10 \
MACLINQ_E2E_REMOTE_USER=ammar \
MACLINQ_E2E_REMOTE_PASS=weakp \
./scripts/test-maclinq-e2e.sh
```

The script currently expects:
- `sshpass`
- `python3`
- `curl` on the remote Linux host

## Troubleshooting

### macOS sender says capture could not start

Check Accessibility permission first. That is the most common failure path.

### Linux receiver cannot open `/dev/uinput`

Typical fixes:
- Run the receiver with `sudo`
- Ensure the `uinput` module is available
- Confirm `/dev/uinput` exists on the Linux host

### Toggle script says the daemon is not running

The sender must be running in normal mode so it can create `/tmp/maclinq.sock`.

### You need deeper packet details

Use:
- `maclinq-linux --event-log /tmp/maclinq-events.log`
- `scripts/test-maclinq-e2e.sh`
- `PROTOCOL.md`

## Protocol

See [`PROTOCOL.md`](PROTOCOL.md) for the
binary packet format.
