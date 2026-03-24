#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>

#include "protocol.h"

static uint16_t read_u16_be(const uint8_t *buf)
{
    uint16_t value_net;

    memcpy(&value_net, buf, sizeof(value_net));
    return ntohs(value_net);
}

static uint32_t read_u32_be(const uint8_t *buf)
{
    uint32_t value_net;

    memcpy(&value_net, buf, sizeof(value_net));
    return ntohl(value_net);
}

/*
 * Parse an 8-byte wire buffer into a key_event struct.
 * Layout on the wire:
 *   [0]      type        (uint8)
 *   [1-2]    keycode     (uint16, network byte order)
 *   [3]      modifiers   (uint8)
 *   [4-7]    timestamp   (uint32, network byte order)
 *
 * Returns 0 on success.
 */
int protocol_parse_event(const uint8_t *buf, struct key_event *evt)
{
    if (buf == NULL || evt == NULL) {
        return -1;
    }
    if (!protocol_is_key_event(buf[0])) {
        return -1;
    }

    evt->type      = buf[0];
    evt->keycode   = read_u16_be(buf + 1);
    evt->modifiers = buf[3];
    evt->timestamp_ms = read_u32_be(buf + 4);

    return 0;
}

int protocol_parse_mouse_move(const uint8_t *buf, struct mouse_move_event *evt)
{
    if (buf == NULL || evt == NULL) {
        return -1;
    }
    if (buf[0] != PKT_MOUSE_MOVE) {
        return -1;
    }

    evt->dx = (int16_t)read_u16_be(buf + 1);
    evt->dy = (int16_t)read_u16_be(buf + 3);

    return 0;
}

int protocol_parse_mouse_button(const uint8_t *buf, struct mouse_button_event *evt)
{
    if (buf == NULL || evt == NULL) {
        return -1;
    }
    if (buf[0] != PKT_MOUSE_DOWN && buf[0] != PKT_MOUSE_UP) {
        return -1;
    }
    if (!protocol_is_known_mouse_button(buf[1])) {
        return -1;
    }

    evt->type = buf[0];
    evt->button = buf[1];

    return 0;
}

int protocol_parse_mouse_scroll(const uint8_t *buf, struct mouse_scroll_event *evt)
{
    if (buf == NULL || evt == NULL) {
        return -1;
    }
    if (buf[0] != PKT_SCROLL) {
        return -1;
    }

    evt->dx = (int16_t)read_u16_be(buf + 1);
    evt->dy = (int16_t)read_u16_be(buf + 3);

    return 0;
}

/*
 * Returns 1 if the packet type is a control packet (heartbeat or disconnect),
 * 0 otherwise.
 */
int protocol_is_control(uint8_t type)
{
    return (type == PKT_HEARTBEAT || type == PKT_DISCONNECT) ? 1 : 0;
}

int protocol_is_key_event(uint8_t type)
{
    return (type == PKT_KEY_DOWN || type == PKT_KEY_UP || type == PKT_FLAGS_CHANGED) ? 1 : 0;
}

int protocol_is_mouse_event(uint8_t type)
{
    return (type == PKT_MOUSE_MOVE || type == PKT_MOUSE_DOWN || type == PKT_MOUSE_UP || type == PKT_SCROLL) ? 1 : 0;
}

int protocol_is_known_mouse_button(uint8_t button)
{
    return (button == MOUSE_BUTTON_LEFT || button == MOUSE_BUTTON_RIGHT || button == MOUSE_BUTTON_MIDDLE) ? 1 : 0;
}
