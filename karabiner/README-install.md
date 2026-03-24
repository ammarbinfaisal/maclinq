# Karabiner-Elements Setup for Maclinq

## Installation

1. Copy the toggle rule to Karabiner's complex modifications:

```bash
cp maclinq-toggle.json ~/.config/karabiner/assets/complex_modifications/
```

2. Open Karabiner-Elements → Complex Modifications → Add Rule
3. Enable "Cmd+F12: Toggle maclinq (send keystrokes to Linux)"
4. Optionally enable "Cmd+Shift+F12: Force OFF maclinq"

## Usage

- **Cmd+F12** — Toggle keyboard forwarding on/off
- **Cmd+Shift+F12** — Emergency force-off (always disables forwarding)

## CLI alternative

```bash
./scripts/maclinq-toggle.sh toggle   # toggle on/off
./scripts/maclinq-toggle.sh on       # force on
./scripts/maclinq-toggle.sh off      # force off
./scripts/maclinq-toggle.sh status   # check current state
```

## Prerequisites

- maclinq-mac daemon must be running
- Karabiner-Elements must be installed
- `nc` (netcat) must be available at /usr/bin/nc (standard on macOS)
