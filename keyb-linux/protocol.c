#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>

#include "protocol.h"

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
    uint16_t keycode_net;
    uint32_t ts_net;

    evt->type      = buf[0];
    memcpy(&keycode_net, buf + 1, sizeof(keycode_net));
    evt->keycode   = ntohs(keycode_net);
    evt->modifiers = buf[3];
    memcpy(&ts_net, buf + 4, sizeof(ts_net));
    evt->timestamp_ms = ntohl(ts_net);

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
