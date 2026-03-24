#ifndef SERVER_H
#define SERVER_H

#include <stddef.h>
#include <stdint.h>

int server_create(uint16_t port);
int server_accept(int listen_fd);
int server_read_exact(int client_fd, uint8_t *buf, size_t len);
int server_write_exact(int client_fd, const uint8_t *buf, size_t len);
int server_read_handshake(int client_fd);

#endif
