#include <stdint.h>
#include <stdio.h>

#include "../protocol.h"

static int assert_equal_u32(uint32_t actual, uint32_t expected, const char *label)
{
    if (actual != expected) {
        fprintf(stderr, "%s mismatch: expected %u, got %u\n", label, expected, actual);
        return 1;
    }
    return 0;
}

int main(void)
{
    uint8_t buf[8] = {
        PKT_KEY_DOWN,
        0x12, 0x34,
        MOD_LCTRL | MOD_LSHIFT,
        0x01, 0x02, 0x03, 0x04
    };
    struct key_event evt;

    if (protocol_parse_event(buf, &evt) != 0) {
        fputs("protocol_parse_event returned failure\n", stderr);
        return 1;
    }

    if (assert_equal_u32(evt.type, PKT_KEY_DOWN, "type") != 0) {
        return 1;
    }
    if (assert_equal_u32(evt.keycode, 0x1234, "keycode") != 0) {
        return 1;
    }
    if (assert_equal_u32(evt.modifiers, MOD_LCTRL | MOD_LSHIFT, "modifiers") != 0) {
        return 1;
    }
    if (assert_equal_u32(evt.timestamp_ms, 0x01020304, "timestamp_ms") != 0) {
        return 1;
    }
    if (!protocol_is_control(PKT_HEARTBEAT) || !protocol_is_control(PKT_DISCONNECT)) {
        fputs("protocol_is_control failed for control packet types\n", stderr);
        return 1;
    }
    if (protocol_is_control(PKT_KEY_DOWN)) {
        fputs("protocol_is_control incorrectly treated key packet as control packet\n", stderr);
        return 1;
    }

    puts("maclinq-linux: protocol tests passed");
    return 0;
}
