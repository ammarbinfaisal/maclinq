#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "protocol.h"
#include "server.h"
#include "uinput_device.h"

static volatile sig_atomic_t g_running = 1;

static void handle_signal(int signo)
{
    (void)signo;
    g_running = 0;
}

static void print_usage(const char *argv0)
{
    fprintf(stderr, "Usage: %s [-p port]\n", argv0);
}

static int parse_port(const char *text, uint16_t *out_port)
{
    char *end = NULL;
    long value = strtol(text, &end, 10);

    if (text[0] == '\0' || end == NULL || *end != '\0') {
        return -1;
    }
    if (value < 1 || value > 65535) {
        return -1;
    }

    *out_port = (uint16_t)value;
    return 0;
}

static void release_modifiers(int uinput_fd, uint8_t *current_mods)
{
    if (*current_mods == 0) {
        return;
    }

    uinput_send_modifier_diff(uinput_fd, *current_mods, 0);
    *current_mods = 0;
}

int main(int argc, char **argv)
{
    int opt;
    int listen_fd = -1;
    int client_fd = -1;
    int uinput_fd = -1;
    uint16_t port = KEYB_PORT;
    uint8_t current_mods = 0;

    while ((opt = getopt(argc, argv, "hp:")) != -1) {
        switch (opt) {
        case 'p':
            if (parse_port(optarg, &port) != 0) {
                fprintf(stderr, "keyb-linux: invalid port '%s'\n", optarg);
                print_usage(argv[0]);
                return 2;
            }
            break;
        case 'h':
        default:
            print_usage(argv[0]);
            return (opt == 'h') ? 0 : 2;
        }
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    uinput_fd = uinput_create();
    if (uinput_fd < 0) {
        return 1;
    }

    listen_fd = server_create(port);
    if (listen_fd < 0) {
        uinput_destroy(uinput_fd);
        return 1;
    }

    while (g_running) {
        struct pollfd pfd;
        uint8_t buf[8];
        struct key_event evt;
        int poll_result;

        client_fd = server_accept(listen_fd);
        if (client_fd < 0) {
            if (!g_running) {
                break;
            }
            continue;
        }

        if (server_read_handshake(client_fd) < 0) {
            close(client_fd);
            client_fd = -1;
            continue;
        }

        current_mods = 0;

        while (g_running) {
            pfd.fd = client_fd;
            pfd.events = POLLIN;
            pfd.revents = 0;

            poll_result = poll(&pfd, 1, 5000);
            if (poll_result < 0) {
                if (errno == EINTR) {
                    continue;
                }
                fprintf(stderr, "keyb-linux: poll failed: %s\n", strerror(errno));
                break;
            }

            if (poll_result == 0) {
                fputs("keyb-linux: client timed out after 5000ms without receiving a heartbeat or event\n", stderr);
                break;
            }

            if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                fprintf(stderr, "keyb-linux: client socket closed or errored (revents=0x%X)\n", pfd.revents);
                break;
            }

            if (server_read_exact(client_fd, buf, sizeof(buf)) < 0) {
                break;
            }

            if (protocol_is_control(buf[0])) {
                if (buf[0] == PKT_HEARTBEAT) {
                    continue;
                }
                if (buf[0] == PKT_DISCONNECT) {
                    puts("keyb-linux: client requested disconnect");
                    break;
                }
                fprintf(stderr, "keyb-linux: received unknown control packet type 0x%02X\n", buf[0]);
                continue;
            }

            if (protocol_parse_event(buf, &evt) != 0) {
                fputs("keyb-linux: failed to parse key event packet\n", stderr);
                break;
            }

            switch (evt.type) {
            case PKT_KEY_DOWN:
                uinput_send_key(uinput_fd, evt.keycode, 1);
                break;
            case PKT_KEY_UP:
                uinput_send_key(uinput_fd, evt.keycode, 0);
                break;
            case PKT_FLAGS_CHANGED:
                uinput_send_modifier_diff(uinput_fd, current_mods, evt.modifiers);
                current_mods = evt.modifiers;
                break;
            default:
                fprintf(stderr, "keyb-linux: unknown event packet type 0x%02X\n", evt.type);
                break;
            }
        }

        release_modifiers(uinput_fd, &current_mods);

        if (client_fd >= 0) {
            close(client_fd);
            client_fd = -1;
        }
    }

    release_modifiers(uinput_fd, &current_mods);

    if (client_fd >= 0) {
        close(client_fd);
    }
    if (listen_fd >= 0) {
        close(listen_fd);
    }
    uinput_destroy(uinput_fd);

    puts("keyb-linux: shutdown complete");
    return 0;
}
