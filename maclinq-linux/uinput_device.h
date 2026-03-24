#ifndef UINPUT_DEVICE_H
#define UINPUT_DEVICE_H

#include <stdint.h>

/*
 * Open /dev/uinput and create a virtual keyboard device.
 * Returns the file descriptor on success, or -1 on error.
 */
int uinput_create(void);

/*
 * Inject a key press or release event.
 *   fd      - file descriptor returned by uinput_create()
 *   keycode - Linux key code (e.g. KEY_A = 30)
 *   value   - 1 for press, 0 for release
 */
void uinput_send_key(int fd, uint16_t keycode, int value);

/*
 * Compare old and new modifier bitmasks and inject the appropriate
 * key press/release events for each changed modifier, followed by
 * a single SYN_REPORT.
 *   fd       - file descriptor returned by uinput_create()
 *   old_mods - previous modifier state
 *   new_mods - new modifier state
 */
void uinput_send_modifier_diff(int fd, uint8_t old_mods, uint8_t new_mods);

/*
 * Destroy the virtual device and close the file descriptor.
 */
void uinput_destroy(int fd);

#endif
