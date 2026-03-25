#include <errno.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "protocol.h"
#include "server.h"
#include "uinput_device.h"

static volatile sig_atomic_t g_running = 1;

struct app_config {
    uint16_t port;
    const char *event_log_path;
    int once;
};

static void handle_signal(int signo)
{
    (void)signo;
    g_running = 0;
}

static void print_usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s --port PORT [--event-log path] [--once]\n"
            "  -p, --port PORT       Listen on PORT\n"
            "      --event-log PATH  Append injected event summaries to PATH\n"
            "      --once            Exit after the first client session ends\n"
            "  -h, --help            Show this help text\n",
            argv0);
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

static int parse_arguments(int argc, char **argv, struct app_config *config)
{
    int opt;
    static const struct option long_options[] = {
        {"help", no_argument, NULL, 'h'},
        {"port", required_argument, NULL, 'p'},
        {"event-log", required_argument, NULL, 1000},
        {"once", no_argument, NULL, 1001},
        {0, 0, 0, 0}
    };

    config->port = 0;
    config->event_log_path = NULL;
    config->once = 0;

    while ((opt = getopt_long(argc, argv, "hp:", long_options, NULL)) != -1) {
        switch (opt) {
        case 'p':
            if (parse_port(optarg, &config->port) != 0) {
                fprintf(stderr, "maclinq-linux: invalid port '%s'\n", optarg);
                return -1;
            }
            break;
        case 'h':
            print_usage(argv[0]);
            exit(0);
        case 1000:
            config->event_log_path = optarg;
            break;
        case 1001:
            config->once = 1;
            break;
        default:
            return -1;
        }
    }

    if (optind != argc) {
        fprintf(stderr, "maclinq-linux: unexpected positional argument '%s'\n", argv[optind]);
        return -1;
    }
    if (config->port == 0) {
        fputs("maclinq-linux: missing required --port argument\n", stderr);
        return -1;
    }

    return 0;
}

static int open_event_log(const char *path, FILE **out_file)
{
    FILE *file;

    if (path == NULL) {
        *out_file = NULL;
        return 0;
    }

    file = fopen(path, "w");
    if (file == NULL) {
        fprintf(stderr, "maclinq-linux: failed to open event log '%s': %s\n", path, strerror(errno));
        return -1;
    }

    if (setvbuf(file, NULL, _IOLBF, 0) != 0) {
        fprintf(stderr, "maclinq-linux: warning: failed to enable line buffering for '%s'\n", path);
    }

    *out_file = file;
    return 0;
}

static void append_event_log(FILE *event_log, const char *fmt, ...)
{
    va_list args;

    if (event_log == NULL) {
        return;
    }

    va_start(args, fmt);
    vfprintf(event_log, fmt, args);
    va_end(args);
    fputc('\n', event_log);
}

static void format_packet_hex(const uint8_t *buf, size_t len, char *out, size_t out_len)
{
    size_t i;
    size_t used = 0;

    if (out_len == 0) {
        return;
    }

    out[0] = '\0';
    for (i = 0; i < len && used + 4 < out_len; i++) {
        int written = snprintf(out + used, out_len - used, "%s%02X", (i == 0) ? "" : " ", buf[i]);
        if (written < 0 || (size_t)written >= out_len - used) {
            break;
        }
        used += (size_t)written;
    }
}

static const char *mouse_button_name(uint8_t button)
{
    switch (button) {
    case MOUSE_BUTTON_LEFT:
        return "left";
    case MOUSE_BUTTON_RIGHT:
        return "right";
    case MOUSE_BUTTON_MIDDLE:
        return "middle";
    default:
        return "unknown";
    }
}

static int release_modifiers(int uinput_fd, uint8_t *current_mods)
{
    if (*current_mods == 0) {
        return 0;
    }

    if (uinput_send_modifier_diff(uinput_fd, *current_mods, 0) < 0) {
        return -1;
    }
    *current_mods = 0;
    return 0;
}

int main(int argc, char **argv)
{
    int listen_fd = -1;
    int client_fd = -1;
    int uinput_fd = -1;
    int exit_code = 0;
    FILE *event_log = NULL;
    struct app_config config;

    if (parse_arguments(argc, argv, &config) != 0) {
        print_usage(argv[0]);
        return 2;
    }
    if (open_event_log(config.event_log_path, &event_log) != 0) {
        return 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    uinput_fd = uinput_create();
    if (uinput_fd < 0) {
        exit_code = 1;
        goto cleanup;
    }

    listen_fd = server_create(config.port);
    if (listen_fd < 0) {
        exit_code = 1;
        goto cleanup;
    }

    while (g_running) {
        struct pollfd pfd;
        uint8_t buf[8];
        uint8_t current_mods = 0;
        int poll_result;
        int session_had_fatal_error = 0;

        client_fd = server_accept(listen_fd);
        if (client_fd < 0) {
            if (!g_running) {
                break;
            }
            continue;
        }

        if (server_read_handshake(client_fd) < 0) {
            append_event_log(event_log, "SESSION handshake_failed");
            close(client_fd);
            client_fd = -1;
            if (config.once) {
                break;
            }
            continue;
        }

        append_event_log(event_log, "SESSION connected");

        while (g_running) {
            char packet_hex[3 * sizeof(buf)];

            pfd.fd = client_fd;
            pfd.events = POLLIN;
            pfd.revents = 0;

            poll_result = poll(&pfd, 1, 5000);
            if (poll_result < 0) {
                if (errno == EINTR) {
                    continue;
                }
                fprintf(stderr, "maclinq-linux: poll failed: %s\n", strerror(errno));
                session_had_fatal_error = 1;
                break;
            }

            if (poll_result == 0) {
                fputs("maclinq-linux: client timed out after 5000ms without receiving a heartbeat or event\n", stderr);
                append_event_log(event_log, "SESSION timeout");
                break;
            }

            if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                fprintf(stderr, "maclinq-linux: client socket closed or errored (revents=0x%X)\n", pfd.revents);
                append_event_log(event_log, "SESSION socket_closed revents=0x%X", pfd.revents);
                break;
            }

            if (server_read_exact(client_fd, buf, sizeof(buf)) < 0) {
                append_event_log(event_log, "SESSION read_failed");
                break;
            }

            if (protocol_is_control(buf[0])) {
                if (buf[0] == PKT_HEARTBEAT) {
                    append_event_log(event_log, "CONTROL heartbeat");
                    continue;
                }
                if (buf[0] == PKT_DISCONNECT) {
                    puts("maclinq-linux: client requested disconnect");
                    append_event_log(event_log, "CONTROL disconnect");
                    break;
                }
                fprintf(stderr, "maclinq-linux: received unknown control packet type 0x%02X\n", buf[0]);
                append_event_log(event_log, "CONTROL unknown type=0x%02X", buf[0]);
                continue;
            }

            format_packet_hex(buf, sizeof(buf), packet_hex, sizeof(packet_hex));

            if (protocol_is_key_event(buf[0])) {
                struct key_event evt;

                if (protocol_parse_event(buf, &evt) != 0) {
                    fprintf(stderr, "maclinq-linux: failed to parse keyboard packet bytes=[%s]\n", packet_hex);
                    session_had_fatal_error = 1;
                    break;
                }

                switch (evt.type) {
                case PKT_KEY_DOWN:
                    if (uinput_send_key(uinput_fd, evt.keycode, 1) < 0) {
                        fprintf(stderr, "maclinq-linux: failed to inject key-down event code=%u modifiers=0x%02X ts=%u\n",
                                evt.keycode, evt.modifiers, evt.timestamp_ms);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "KEY down code=%u modifiers=0x%02X timestamp_ms=%u",
                                     evt.keycode, evt.modifiers, evt.timestamp_ms);
                    continue;
                case PKT_KEY_UP:
                    if (uinput_send_key(uinput_fd, evt.keycode, 0) < 0) {
                        fprintf(stderr, "maclinq-linux: failed to inject key-up event code=%u modifiers=0x%02X ts=%u\n",
                                evt.keycode, evt.modifiers, evt.timestamp_ms);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "KEY up code=%u modifiers=0x%02X timestamp_ms=%u",
                                     evt.keycode, evt.modifiers, evt.timestamp_ms);
                    continue;
                case PKT_FLAGS_CHANGED:
                    if (uinput_send_modifier_diff(uinput_fd, current_mods, evt.modifiers) < 0) {
                        fprintf(stderr,
                                "maclinq-linux: failed to inject modifier change old=0x%02X new=0x%02X ts=%u\n",
                                current_mods, evt.modifiers, evt.timestamp_ms);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "MODS old=0x%02X new=0x%02X timestamp_ms=%u",
                                     current_mods, evt.modifiers, evt.timestamp_ms);
                    current_mods = evt.modifiers;
                    continue;
                default:
                    fprintf(stderr, "maclinq-linux: unknown keyboard event packet type 0x%02X bytes=[%s]\n",
                            evt.type, packet_hex);
                    session_had_fatal_error = 1;
                    break;
                }

                break;
            }

            if (protocol_is_mouse_event(buf[0])) {
                if (buf[0] == PKT_MOUSE_MOVE) {
                    struct mouse_move_event evt;

                    if (protocol_parse_mouse_move(buf, &evt) != 0) {
                        fprintf(stderr, "maclinq-linux: failed to parse mouse move packet bytes=[%s]\n", packet_hex);
                        session_had_fatal_error = 1;
                        break;
                    }
                    if (uinput_send_relative_move(uinput_fd, evt.dx, evt.dy) < 0) {
                        fprintf(stderr, "maclinq-linux: failed to inject mouse move dx=%d dy=%d\n", evt.dx, evt.dy);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "MOUSE move dx=%d dy=%d", evt.dx, evt.dy);
                    continue;
                }

                if (buf[0] == PKT_MOUSE_DOWN || buf[0] == PKT_MOUSE_UP) {
                    struct mouse_button_event evt;
                    int pressed;

                    if (protocol_parse_mouse_button(buf, &evt) != 0) {
                        fprintf(stderr, "maclinq-linux: failed to parse mouse button packet bytes=[%s]\n", packet_hex);
                        session_had_fatal_error = 1;
                        break;
                    }

                    pressed = (evt.type == PKT_MOUSE_DOWN) ? 1 : 0;
                    if (uinput_send_button(uinput_fd, evt.button, pressed) < 0) {
                        fprintf(stderr, "maclinq-linux: failed to inject mouse button event button=%s value=%d\n",
                                mouse_button_name(evt.button), pressed);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "MOUSE %s button=%s",
                                     pressed ? "down" : "up", mouse_button_name(evt.button));
                    continue;
                }

                if (buf[0] == PKT_SCROLL) {
                    struct mouse_scroll_event evt;

                    if (protocol_parse_mouse_scroll(buf, &evt) != 0) {
                        fprintf(stderr, "maclinq-linux: failed to parse scroll packet bytes=[%s]\n", packet_hex);
                        session_had_fatal_error = 1;
                        break;
                    }
                    if (uinput_send_scroll(uinput_fd, evt.dx, evt.dy) < 0) {
                        fprintf(stderr, "maclinq-linux: failed to inject scroll event dx=%d dy=%d\n", evt.dx, evt.dy);
                        session_had_fatal_error = 1;
                        break;
                    }
                    append_event_log(event_log, "SCROLL dx=%d dy=%d", evt.dx, evt.dy);
                    continue;
                }
            }

            fprintf(stderr, "maclinq-linux: received unsupported packet type 0x%02X bytes=[%s]\n", buf[0], packet_hex);
            session_had_fatal_error = 1;
            break;
        }

        if (release_modifiers(uinput_fd, &current_mods) < 0) {
            fputs("maclinq-linux: failed to release active modifiers during session teardown\n", stderr);
            session_had_fatal_error = 1;
        }

        append_event_log(event_log, "SESSION disconnected");

        if (client_fd >= 0) {
            close(client_fd);
            client_fd = -1;
        }

        if (session_had_fatal_error) {
            exit_code = 1;
            break;
        }
        if (config.once) {
            break;
        }
    }

cleanup:
    if (client_fd >= 0) {
        close(client_fd);
    }
    if (listen_fd >= 0) {
        close(listen_fd);
    }
    if (uinput_fd >= 0) {
        uinput_destroy(uinput_fd);
    }
    if (event_log != NULL) {
        fclose(event_log);
    }

    puts("maclinq-linux: shutdown complete");
    return exit_code;
}
