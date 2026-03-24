#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include <linux/input.h>

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

/* Write a single struct input_event to the uinput fd */
static void write_event(int fd, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev;
    ssize_t written;
    memset(&ev, 0, sizeof(ev));
    ev.type  = type;
    ev.code  = code;
    ev.value = value;
    written = write(fd, &ev, sizeof(ev));
    if (written < 0) {
        fprintf(stderr, "keyb-linux: failed to write uinput event type=%u code=%u value=%d: %s\n",
                type, code, value, strerror(errno));
    } else if ((size_t)written != sizeof(ev)) {
        fprintf(stderr, "keyb-linux: short write to uinput device: wrote %zd of %zu bytes\n",
                written, sizeof(ev));
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
                "keyb-linux: failed to open /dev/uinput: %s. "
                "Ensure the uinput module is loaded and run with sufficient privileges.\n",
                strerror(errno));
        return -1;
    }

    /* Enable key and sync event types */
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        perror("UI_SET_EVBIT EV_KEY");
        close(fd);
        return -1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) {
        perror("UI_SET_EVBIT EV_SYN");
        close(fd);
        return -1;
    }

    /* Register all standard key codes up to 255 */
    for (key = KEY_ESC; key <= 255; key++) {
        if (ioctl(fd, UI_SET_KEYBIT, key) < 0) {
            /* Some slots may not be valid; ignore individual failures */
        }
    }

    /* Configure the virtual device */
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_USB;
    usetup.id.vendor  = 0x1234;
    usetup.id.product = 0x5678;
    usetup.id.version = 1;
    strncpy(usetup.name, "keyb-virtual-keyboard", UINPUT_MAX_NAME_SIZE - 1);

    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) {
        perror("UI_DEV_SETUP");
        close(fd);
        return -1;
    }

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        close(fd);
        return -1;
    }

    usleep(100000);

    return fd;
}

void uinput_send_key(int fd, uint16_t keycode, int value)
{
    if (fd < 0) {
        fputs("keyb-linux: refusing to inject key event because uinput is not initialized\n", stderr);
        return;
    }
    if (keycode == 0) {
        fputs("keyb-linux: refusing to inject key event with keycode 0\n", stderr);
        return;
    }

    write_event(fd, EV_KEY, keycode, value);
    write_event(fd, EV_SYN, SYN_REPORT, 0);
}

void uinput_send_modifier_diff(int fd, uint8_t old_mods, uint8_t new_mods)
{
    int i;
    uint8_t changed = old_mods ^ new_mods;

    if (changed == 0)
        return;
    if (fd < 0) {
        fputs("keyb-linux: refusing to inject modifier change because uinput is not initialized\n", stderr);
        return;
    }

    for (i = 0; i < 8; i++) {
        uint8_t mask = (uint8_t)(1u << i);
        if (!(changed & mask))
            continue;

        if (new_mods & mask) {
            /* Bit newly set → key press */
            write_event(fd, EV_KEY, mod_keycodes[i], 1);
        } else {
            /* Bit newly cleared → key release */
            write_event(fd, EV_KEY, mod_keycodes[i], 0);
        }
    }

    /* Single SYN_REPORT after all modifier changes */
    write_event(fd, EV_SYN, SYN_REPORT, 0);
}

void uinput_destroy(int fd)
{
    if (fd < 0)
        return;
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
}
