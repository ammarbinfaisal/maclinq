#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "protocol.h"
#include "server.h"

static void print_errno(const char *context)
{
    fprintf(stderr, "keyb-linux: %s: %s\n", context, strerror(errno));
}

int server_create(uint16_t port)
{
    int fd;
    int opt = 1;
    struct sockaddr_in addr;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        print_errno("failed to create TCP socket");
        return -1;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        print_errno("failed to set SO_REUSEADDR");
        close(fd);
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "keyb-linux: failed to bind to TCP port %u: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }

    if (listen(fd, 1) < 0) {
        print_errno("failed to listen for TCP clients");
        close(fd);
        return -1;
    }

    printf("keyb-linux: listening on port %u\n", port);
    return fd;
}

int server_accept(int listen_fd)
{
    int client_fd;
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    char client_ip[INET_ADDRSTRLEN];

    client_fd = accept(listen_fd, (struct sockaddr *)&addr, &addr_len);
    if (client_fd < 0) {
        if (errno != EINTR) {
            print_errno("failed to accept client connection");
        }
        return -1;
    }

    if (inet_ntop(AF_INET, &addr.sin_addr, client_ip, sizeof(client_ip)) == NULL) {
        strncpy(client_ip, "<unknown>", sizeof(client_ip) - 1);
        client_ip[sizeof(client_ip) - 1] = '\0';
    }

    printf("keyb-linux: client connected from %s:%u\n", client_ip, ntohs(addr.sin_port));
    return client_fd;
}

int server_read_exact(int client_fd, uint8_t *buf, size_t len)
{
    size_t total = 0;

    while (total < len) {
        ssize_t n = recv(client_fd, buf + total, len - total, 0);
        if (n == 0) {
            fprintf(stderr, "keyb-linux: client disconnected while reading %zu-byte packet (%zu bytes received)\n",
                    len, total);
            return -1;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "keyb-linux: recv failed while reading %zu-byte packet: %s\n", len, strerror(errno));
            return -1;
        }
        total += (size_t)n;
    }

    return 0;
}

int server_write_exact(int client_fd, const uint8_t *buf, size_t len)
{
    size_t total = 0;

    while (total < len) {
        ssize_t n = send(client_fd, buf + total, len - total, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "keyb-linux: send failed while writing %zu-byte response: %s\n", len, strerror(errno));
            return -1;
        }
        total += (size_t)n;
    }

    return 0;
}

int server_read_handshake(int client_fd)
{
    struct handshake_pkt request;
    struct handshake_pkt response;
    uint32_t magic;
    uint8_t status = 0x00;

    memset(&request, 0, sizeof(request));
    if (server_read_exact(client_fd, (uint8_t *)&request, sizeof(request)) < 0) {
        return -1;
    }

    magic = ntohl(request.magic);
    if (magic != KEYB_MAGIC) {
        fprintf(stderr, "keyb-linux: invalid handshake magic 0x%08X (expected 0x%08X)\n", magic, KEYB_MAGIC);
        status = 0x01;
    } else if (request.version != KEYB_VERSION) {
        fprintf(stderr, "keyb-linux: unsupported client protocol version 0x%02X (expected 0x%02X)\n",
                request.version, KEYB_VERSION);
        status = 0x01;
    }

    response.magic = htonl(KEYB_MAGIC);
    response.version = KEYB_VERSION;
    response.status = status;

    if (server_write_exact(client_fd, (const uint8_t *)&response, sizeof(response)) < 0) {
        return -1;
    }

    if (status != 0x00) {
        fputs("keyb-linux: rejecting client during handshake\n", stderr);
        return -1;
    }

    puts("keyb-linux: handshake completed successfully");
    return 0;
}
