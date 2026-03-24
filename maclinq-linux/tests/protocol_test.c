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
    struct mouse_move_event mouse_move;
    struct mouse_button_event mouse_button;
    struct mouse_scroll_event mouse_scroll;
    uint8_t mouse_move_buf[8] = {PKT_MOUSE_MOVE, 0x00, 0x0C, 0xFF, 0xF8, 0x00, 0x00, 0x00};
    uint8_t mouse_button_buf[8] = {PKT_MOUSE_DOWN, MOUSE_BUTTON_RIGHT, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    uint8_t mouse_scroll_buf[8] = {PKT_SCROLL, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00};

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
    if (!protocol_is_mouse_event(PKT_MOUSE_MOVE) || !protocol_is_mouse_event(PKT_MOUSE_UP)) {
        fputs("protocol_is_mouse_event failed for mouse packet types\n", stderr);
        return 1;
    }
    if (protocol_is_mouse_event(PKT_KEY_DOWN)) {
        fputs("protocol_is_mouse_event incorrectly treated key packet as mouse packet\n", stderr);
        return 1;
    }
    if (protocol_parse_mouse_move(mouse_move_buf, &mouse_move) != 0) {
        fputs("protocol_parse_mouse_move returned failure\n", stderr);
        return 1;
    }
    if (mouse_move.dx != 12 || mouse_move.dy != -8) {
        fprintf(stderr, "mouse move mismatch: expected 12/-8, got %d/%d\n", mouse_move.dx, mouse_move.dy);
        return 1;
    }
    if (protocol_parse_mouse_button(mouse_button_buf, &mouse_button) != 0) {
        fputs("protocol_parse_mouse_button returned failure\n", stderr);
        return 1;
    }
    if (mouse_button.type != PKT_MOUSE_DOWN || mouse_button.button != MOUSE_BUTTON_RIGHT) {
        fprintf(stderr, "mouse button mismatch: expected type=%u button=%u, got type=%u button=%u\n",
                PKT_MOUSE_DOWN, MOUSE_BUTTON_RIGHT, mouse_button.type, mouse_button.button);
        return 1;
    }
    if (protocol_parse_mouse_scroll(mouse_scroll_buf, &mouse_scroll) != 0) {
        fputs("protocol_parse_mouse_scroll returned failure\n", stderr);
        return 1;
    }
    if (mouse_scroll.dx != 0 || mouse_scroll.dy != -1) {
        fprintf(stderr, "mouse scroll mismatch: expected 0/-1, got %d/%d\n", mouse_scroll.dx, mouse_scroll.dy);
        return 1;
    }
    if (!protocol_is_known_mouse_button(MOUSE_BUTTON_LEFT) || protocol_is_known_mouse_button(0x09)) {
        fputs("protocol_is_known_mouse_button returned an unexpected result\n", stderr);
        return 1;
    }

    puts("maclinq-linux: protocol tests passed");
    return 0;
}
