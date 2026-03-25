# Maclinq

Maclinq forwards keyboard and mouse input from a Mac to a Linux machine over a
local TCP connection. The Mac side captures keyboard, pointer movement,
clicks, and scroll, then the Linux side injects those events through
`/dev/uinput`.

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

- `maclinq-mac/`: Swift sender for macOS
- `maclinq-linux/`: C receiver for Linux
- `karabiner/`: Karabiner toggle rule for normal Mac usage
- `scripts/maclinq-toggle.sh`: local toggle helper for the Mac sender
- `scripts/kde-plasma6-apple-physical-keys.sh`: Apple-keyboard remap helper for KDE Plasma 6 on Linux
- `scripts/test-maclinq-e2e.sh`: scripted end-to-end verification
- `PROTOCOL.md`: wire protocol

## Prerequisites

### Mac

- macOS 13 or newer
- Swift 5.9 toolchain or newer
- Accessibility permission for the app or terminal running `maclinq-mac`
- Input Monitoring permission for the app or terminal running `maclinq-mac`
- Karabiner-Elements if you want the hotkey toggle flow

### Linux

- GCC and `make`
- A kernel with `uinput` available
- Permission to open `/dev/uinput`
  In practice this usually means running the receiver with `sudo`
- `hid_apple` if you want the Apple-keyboard physical remap helper on KDE Plasma 6

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

### 1. Choose host and port

Pick:
- the target host or IP address
- a TCP port you want both sides to use

Example shell variables:

```bash
TARGET_HOST="your-linux-host-or-ip"
TARGET_PORT="your-chosen-port"
```

Maclinq does not assume network defaults. You must provide the same port on
both endpoints, and the Mac sender must be told which host to connect to.

### 2. Start the Linux receiver

On the Linux machine:

```bash
cd maclinq-linux
sudo ./maclinq-receiver --port "$TARGET_PORT"
```

Useful options:

```bash
sudo ./maclinq-receiver --port "$TARGET_PORT" --event-log /tmp/maclinq-events.log
sudo ./maclinq-receiver --port "$TARGET_PORT" --once
```

Notes:
- `--port` is required
- `--event-log` writes a line-oriented log of injected events, which is useful
  for debugging and automated verification
- `--once` exits after a single client session ends

### 3. Start the Mac sender

On the Mac:

```bash
cd maclinq-mac
swift run maclinq-mac "$TARGET_HOST" "$TARGET_PORT"
```

Normal mode starts a local Unix socket at `/tmp/maclinq.sock` and waits for a
toggle command.

### 3a. Optional: make an Apple keyboard feel like a PC keyboard on KDE Plasma 6

If your Linux target is KDE Plasma 6 on Ubuntu and you are using an Apple
keyboard, you can remap the physical modifier row so common Linux shortcuts
match the physical key positions:

- physical `fn` acts as `Ctrl`
- physical `ctrl` acts as `Fn`
- physical `option` acts as `Meta/Super`
- physical `command` acts as `Alt`

Use:

```bash
sudo ./scripts/kde-plasma6-apple-physical-keys.sh apply
```

Status and rollback:

```bash
sudo ./scripts/kde-plasma6-apple-physical-keys.sh status
sudo ./scripts/kde-plasma6-apple-physical-keys.sh restore
```

The script:
- configures the `hid_apple` kernel driver for a persistent remap
- tries to apply the remap to the running kernel immediately
- can optionally configure Plasma 6 so `Meta` alone opens the launcher

See `--help` on the script for runtime-only mode, config-file support, and
Plasma-specific options.

### 4. Grant Accessibility permission

The process running `maclinq-mac` must be allowed under:

`System Settings > Privacy & Security > Accessibility`

Without this, macOS will refuse to create the keyboard and mouse event taps.

Grant permission to the process that actually launches Maclinq:
- `Terminal` if you run `swift run` from Terminal.app
- `iTerm` if you run it from iTerm
- `Ghostty` if you run it from Ghostty
- a packaged Maclinq app if you later ship it as an `.app`

You do not grant Accessibility access to the `.swift` source files or the repo
directory.

In practice you should grant both:
- `Accessibility`
- `Input Monitoring`

### 5. Optional: install the Karabiner toggle

Follow [README-install.md](/Users/ammar/Documents/codes/keyb/karabiner/README-install.md).

The bundled rule gives you:
- `Shift+Cmd+Opt+0` to toggle forwarding
- `Shift+Cmd+Opt+9` to force forwarding off

To install and enable the Karabiner rules automatically:

```bash
./scripts/install-karabiner-maclinq.sh
```

## Usage

### Toggle forwarding from the Mac

With Karabiner installed:
- Press `Shift+Cmd+Opt+0` to toggle on or off
- Press `Shift+Cmd+Opt+9` for an emergency off

If that does not fit your setup, customize the Karabiner rule as described in
[`karabiner/README-install.md`](/Users/ammar/Documents/codes/keyb/karabiner/README-install.md).

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
swift run maclinq-mac --fixture ../scripts/fixtures/e2e.fixture "$TARGET_HOST" "$TARGET_PORT"
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
MACLINQ_E2E_REMOTE_HOST="$TARGET_HOST" \
MACLINQ_E2E_REMOTE_USER=ammar \
MACLINQ_E2E_REMOTE_PASS=weakp \
MACLINQ_E2E_PORT="$TARGET_PORT" \
./scripts/test-maclinq-e2e.sh
```

The script currently expects:
- `sshpass`
- `python3`
- `curl` on the remote Linux host

## Troubleshooting

### macOS sender says capture could not start

Check both Accessibility and Input Monitoring for the app that launched
Maclinq. Then fully quit and relaunch that app before trying again.

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

See [PROTOCOL.md](/Users/ammar/Documents/codes/keyb/PROTOCOL.md) for the
binary packet format.
