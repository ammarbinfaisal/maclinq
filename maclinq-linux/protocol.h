#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>

#define MACLINQ_MAGIC       0x4D434C51
#define MACLINQ_VERSION     0x01
#define MACLINQ_PORT        7680

// Packet types
#define PKT_KEY_DOWN      0x01
#define PKT_KEY_UP        0x02
#define PKT_FLAGS_CHANGED 0x03
#define PKT_HEARTBEAT     0x10
#define PKT_DISCONNECT    0x11
#define PKT_MOUSE_MOVE    0x20
#define PKT_MOUSE_DOWN    0x21
#define PKT_MOUSE_UP      0x22
#define PKT_SCROLL        0x23

// Modifier bits
#define MOD_LCTRL   0x01
#define MOD_LSHIFT  0x02
#define MOD_LALT    0x04
#define MOD_LMETA   0x08
#define MOD_RCTRL   0x10
#define MOD_RSHIFT  0x20
#define MOD_RALT    0x40
#define MOD_RMETA   0x80

#define MOUSE_BUTTON_LEFT   0x01
#define MOUSE_BUTTON_RIGHT  0x02
#define MOUSE_BUTTON_MIDDLE 0x03

// Handshake packet (6 bytes)
struct __attribute__((packed)) handshake_pkt {
    uint32_t magic;
    uint8_t  version;
    uint8_t  status; // reserved in request, status in response
};

// Key event packet (8 bytes)
struct __attribute__((packed)) key_event_pkt {
    uint8_t  type;
    uint16_t keycode;
    uint8_t  modifiers;
    uint32_t timestamp_ms;
};

// Control packet (8 bytes)
struct __attribute__((packed)) control_pkt {
    uint8_t type;
    uint8_t padding[7];
};

// Parsed key event (host byte order)
struct key_event {
    uint8_t  type;
    uint16_t keycode;
    uint8_t  modifiers;
    uint32_t timestamp_ms;
};

struct mouse_move_event {
    int16_t dx;
    int16_t dy;
};

struct mouse_button_event {
    uint8_t type;
    uint8_t button;
};

struct mouse_scroll_event {
    int16_t dx;
    int16_t dy;
};

int protocol_parse_event(const uint8_t *buf, struct key_event *evt);
int protocol_parse_mouse_move(const uint8_t *buf, struct mouse_move_event *evt);
int protocol_parse_mouse_button(const uint8_t *buf, struct mouse_button_event *evt);
int protocol_parse_mouse_scroll(const uint8_t *buf, struct mouse_scroll_event *evt);
int protocol_is_control(uint8_t type);
int protocol_is_key_event(uint8_t type);
int protocol_is_mouse_event(uint8_t type);
int protocol_is_known_mouse_button(uint8_t button);

#endif
