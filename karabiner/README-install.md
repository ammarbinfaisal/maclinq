# Karabiner-Elements Setup for Maclinq

## Installation

1. Copy the toggle rule to Karabiner's complex modifications:

```bash
cp maclinq-toggle.json ~/.config/karabiner/assets/complex_modifications/
```

2. Open Karabiner-Elements → Complex Modifications → Add Rule
3. Enable "F8: Toggle maclinq (send input to the remote endpoint)"
4. Optionally enable "Shift+F8: Force OFF maclinq"

## Usage

- **F8** — Toggle forwarding on/off
- **Shift+F8** — Emergency force-off (always disables forwarding)

This default is intentional for Touch Bar Macs or setups where the function
row is already exposed through Karabiner. It avoids depending on `Cmd+F12`.

## Customizing the hotkey

If `F8` conflicts with your setup:

1. Open `karabiner/maclinq-toggle.json`
2. Change the `from.key_code` value in both manipulators
3. Change the `mandatory` modifiers if you want a modified shortcut instead
4. Re-copy the file into Karabiner's `complex_modifications` directory

Examples:
- plain `f9`
- `right_command` + `f9`
- `right_option` + `f8`

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
