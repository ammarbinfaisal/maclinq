#!/bin/bash
# keyb-toggle.sh — CLI toggle for keyb daemon
# Usage: keyb-toggle.sh [on|off|toggle|status]

SOCK="/tmp/keyb.sock"

if [ ! -S "$SOCK" ]; then
    echo "keyb: daemon not running (no socket at $SOCK)"
    exit 1
fi

case "${1:-toggle}" in
    toggle)
        echo -ne "\x01" | nc -U "$SOCK"
        ;;
    on)
        echo -ne "\x02" | nc -U "$SOCK"
        ;;
    off)
        echo -ne "\x03" | nc -U "$SOCK"
        ;;
    status)
        # Send query byte, read response
        RESP=$(echo -ne "\x04" | nc -U "$SOCK" | xxd -p)
        if [ "$RESP" = "01" ]; then
            echo "keyb: active"
        else
            echo "keyb: inactive"
        fi
        ;;
    *)
        echo "Usage: $0 [toggle|on|off|status]"
        exit 1
        ;;
esac
