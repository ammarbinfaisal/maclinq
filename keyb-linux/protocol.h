#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>

#define KEYB_MAGIC       0x4B455942
#define KEYB_VERSION     0x01
#define KEYB_PORT        7680

// Packet types
#define PKT_KEY_DOWN      0x01
#define PKT_KEY_UP        0x02
#define PKT_FLAGS_CHANGED 0x03
#define PKT_HEARTBEAT     0x10
#define PKT_DISCONNECT    0x11

// Modifier bits
#define MOD_LCTRL   0x01
#define MOD_LSHIFT  0x02
#define MOD_LALT    0x04
#define MOD_LMETA   0x08
#define MOD_RCTRL   0x10
#define MOD_RSHIFT  0x20
#define MOD_RALT    0x40
#define MOD_RMETA   0x80

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

int protocol_parse_event(const uint8_t *buf, struct key_event *evt);
int protocol_is_control(uint8_t type);

#endif
