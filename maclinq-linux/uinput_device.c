#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include <linux/input.h>

#include "protocol.h"
#include "uinput_device.h"

/* Mapping from modifier bit position (0-7) to Linux key code */
static const uint16_t mod_keycodes[8] = {
    KEY_LEFTCTRL,   /* bit 0 - MOD_LCTRL  */
    KEY_LEFTSHIFT,  /* bit 1 - MOD_LSHIFT */
    KEY_LEFTALT,    /* bit 2 - MOD_LALT   */
    KEY_LEFTMETA,   /* bit 3 - MOD_LMETA  */
    KEY_RIGHTCTRL,  /* bit 4 - MOD_RCTRL  */
    KEY_RIGHTSHIFT, /* bit 5 - MOD_RSHIFT */
    KEY_RIGHTALT,   /* bit 6 - MOD_RALT   */
    KEY_RIGHTMETA,  /* bit 7 - MOD_RMETA  */
};

static int write_event_checked(int fd, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev;
    ssize_t written;
    memset(&ev, 0, sizeof(ev));
    ev.type  = type;
    ev.code  = code;
    ev.value = value;
    written = write(fd, &ev, sizeof(ev));
    if (written < 0) {
        fprintf(stderr, "maclinq-linux: failed to write uinput event type=%u code=%u value=%d: %s\n",
                type, code, value, strerror(errno));
        return -1;
    } else if ((size_t)written != sizeof(ev)) {
        fprintf(stderr, "maclinq-linux: short write to uinput device: wrote %zd of %zu bytes\n",
                written, sizeof(ev));
        return -1;
    }

    return 0;
}

static int emit_syn(int fd)
{
    return write_event_checked(fd, EV_SYN, SYN_REPORT, 0);
}

static int button_to_evdev(uint8_t button, uint16_t *out_code)
{
    if (out_code == NULL) {
        return -1;
    }

    switch (button) {
    case MOUSE_BUTTON_LEFT:
        *out_code = BTN_LEFT;
        return 0;
    case MOUSE_BUTTON_RIGHT:
        *out_code = BTN_RIGHT;
        return 0;
    case MOUSE_BUTTON_MIDDLE:
        *out_code = BTN_MIDDLE;
        return 0;
    default:
        return -1;
    }
}

int uinput_create(void)
{
    int fd;
    int key;
    struct uinput_setup usetup;

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr,
                "maclinq-linux: failed to open /dev/uinput: %s. "
                "Ensure the uinput module is loaded and run with sufficient privileges.\n",
                strerror(errno));
        return -1;
    }

    /* Enable keyboard, mouse, relative motion, and sync event types. */
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        fprintf(stderr, "maclinq-linux: UI_SET_EVBIT EV_KEY failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) {
        fprintf(stderr, "maclinq-linux: UI_SET_EVBIT EV_SYN failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) {
        fprintf(stderr, "maclinq-linux: UI_SET_EVBIT EV_REL failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    /* Register all standard key codes up to 255 */
    for (key = KEY_ESC; key <= 255; key++) {
        if (ioctl(fd, UI_SET_KEYBIT, key) < 0) {
            /* Some slots may not be valid; ignore individual failures */
        }
    }
    if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0) {
        fprintf(stderr, "maclinq-linux: failed to enable mouse button bits: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_HWHEEL) < 0) {
        fprintf(stderr, "maclinq-linux: failed to enable relative motion bits: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    /* Configure the virtual device */
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_USB;
    usetup.id.vendor  = 0x1234;
    usetup.id.product = 0x5678;
    usetup.id.version = 1;
    strncpy(usetup.name, "maclinq-virtual-input", UINPUT_MAX_NAME_SIZE - 1);

    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) {
        fprintf(stderr, "maclinq-linux: UI_DEV_SETUP failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "maclinq-linux: UI_DEV_CREATE failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    usleep(100000);

    return fd;
}

int uinput_send_key(int fd, uint16_t keycode, int value)
{
    if (fd < 0) {
        fputs("maclinq-linux: refusing to inject key event because uinput is not initialized\n", stderr);
        return -1;
    }
    if (keycode == 0) {
        fputs("maclinq-linux: refusing to inject key event with keycode 0\n", stderr);
        return -1;
    }

    if (write_event_checked(fd, EV_KEY, keycode, value) < 0) {
        return -1;
    }
    return emit_syn(fd);
}

int uinput_send_modifier_diff(int fd, uint8_t old_mods, uint8_t new_mods)
{
    int i;
    uint8_t changed = old_mods ^ new_mods;

    if (changed == 0) {
        return 0;
    }
    if (fd < 0) {
        fputs("maclinq-linux: refusing to inject modifier change because uinput is not initialized\n", stderr);
        return -1;
    }

    for (i = 0; i < 8; i++) {
        uint8_t mask = (uint8_t)(1u << i);
        if (!(changed & mask))
            continue;

        if (new_mods & mask) {
            /* Bit newly set → key press */
            if (write_event_checked(fd, EV_KEY, mod_keycodes[i], 1) < 0) {
                return -1;
            }
        } else {
            /* Bit newly cleared → key release */
            if (write_event_checked(fd, EV_KEY, mod_keycodes[i], 0) < 0) {
                return -1;
            }
        }
    }

    return emit_syn(fd);
}

int uinput_send_relative_move(int fd, int16_t dx, int16_t dy)
{
    if (fd < 0) {
        fputs("maclinq-linux: refusing to inject pointer movement because uinput is not initialized\n", stderr);
        return -1;
    }
    if (dx == 0 && dy == 0) {
        return 0;
    }

    if (dx != 0 && write_event_checked(fd, EV_REL, REL_X, dx) < 0) {
        return -1;
    }
    if (dy != 0 && write_event_checked(fd, EV_REL, REL_Y, dy) < 0) {
        return -1;
    }

    return emit_syn(fd);
}

int uinput_send_button(int fd, uint8_t button, int value)
{
    uint16_t code;

    if (fd < 0) {
        fputs("maclinq-linux: refusing to inject mouse button event because uinput is not initialized\n", stderr);
        return -1;
    }
    if (button_to_evdev(button, &code) < 0) {
        fprintf(stderr, "maclinq-linux: refusing to inject unknown mouse button 0x%02X\n", button);
        return -1;
    }

    if (write_event_checked(fd, EV_KEY, code, value) < 0) {
        return -1;
    }
    return emit_syn(fd);
}

int uinput_send_scroll(int fd, int16_t dx, int16_t dy)
{
    if (fd < 0) {
        fputs("maclinq-linux: refusing to inject scroll event because uinput is not initialized\n", stderr);
        return -1;
    }
    if (dx == 0 && dy == 0) {
        return 0;
    }

    if (dx != 0 && write_event_checked(fd, EV_REL, REL_HWHEEL, dx) < 0) {
        return -1;
    }
    if (dy != 0 && write_event_checked(fd, EV_REL, REL_WHEEL, dy) < 0) {
        return -1;
    }

    return emit_syn(fd);
}

void uinput_destroy(int fd)
{
    if (fd < 0)
        return;
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
}
