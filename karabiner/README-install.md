# Karabiner-Elements Setup for Maclinq

## Installation

1. Copy the toggle rule to Karabiner's complex modifications:

```bash
cp maclinq-toggle.json ~/.config/karabiner/assets/complex_modifications/
```

Important:
- `karabiner/maclinq-toggle.json` is in the file-import format:
  - top-level `title`
  - top-level `rules`
- If you use Karabiner's in-app JSON editor instead, do not paste the whole
  file. Paste only individual rule objects.

2. Open Karabiner-Elements → Complex Modifications → Add Rule
3. Enable "Shift+Cmd+Opt+0: Toggle maclinq (send input to the remote endpoint)"
4. Optionally enable "Shift+Cmd+Opt+9: Force OFF maclinq"

## Usage

- **Shift+Cmd+Opt+0** — Toggle forwarding on/off
- **Shift+Cmd+Opt+9** — Emergency force-off (always disables forwarding)

## Customizing the hotkey

If the default combo conflicts with your setup:

1. Open `karabiner/maclinq-toggle.json`
2. Change the `from.key_code` value in both manipulators
3. Change the `mandatory` modifiers if you want a modified shortcut instead
4. Re-copy the file into Karabiner's `complex_modifications` directory

Examples:
- plain `f8`
- `right_command` + `f9`
- `right_option` + `0`

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
