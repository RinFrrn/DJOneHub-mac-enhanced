/*
 * Minimal module-side control-plane sentinel for the iPhone ECM path.
 *
 * This intentionally does not access AT, QMI, PCM, or a shell.  It only
 * proves that the module-side service can be reached over the USB network.
 * The real call-control implementation must be added behind this boundary
 * after the internal AT channel has been identified and reserved safely.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DJONEHUBD_DEFAULT_ADDRESS "192.168.225.1"
#define DJONEHUBD_DEFAULT_PORT 45750U
#define DJONEHUBD_BACKLOG 4
#define DJONEHUBD_RESPONSE \
    "{\"ok\":true,\"service\":\"djonehubd\",\"version\":1," \
    "\"state\":\"ready\"}\n"

static volatile sig_atomic_t stop_requested;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int install_signal_handlers(void)
{
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = handle_signal;
    if (sigemptyset(&action.sa_mask) != 0 ||
        sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0 ||
        signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        return -1;
    }
    return 0;
}

static int parse_port(const char *text, unsigned int *port)
{
    char *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] == '\0') {
        return -1;
    }
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0UL ||
        value > 65535UL) {
        return -1;
    }
    *port = (unsigned int)value;
    return 0;
}

static int send_all(int socket_fd, const char *buffer, size_t length)
{
    size_t offset = 0U;

    while (offset < length) {
        ssize_t sent = send(socket_fd, buffer + offset, length - offset, 0);
        if (sent < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (sent == 0) {
            return -1;
        }
        offset += (size_t)sent;
    }
    return 0;
}

static int create_listener(const char *address, unsigned int port)
{
    struct sockaddr_in local;
    int socket_fd;
    int enabled = 1;

    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, address, &local.sin_addr) != 1) {
        fprintf(stderr, "djonehubd: invalid listen address: %s\n", address);
        return -1;
    }

    socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        fprintf(stderr, "djonehubd: socket: %s\n", strerror(errno));
        return -1;
    }
    if (setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &enabled,
                   sizeof(enabled)) != 0 ||
        bind(socket_fd, (const struct sockaddr *)&local, sizeof(local)) != 0 ||
        listen(socket_fd, DJONEHUBD_BACKLOG) != 0) {
        fprintf(stderr, "djonehubd: listen %s:%u: %s\n", address, port,
                strerror(errno));
        (void)close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static void serve_client(int client_fd)
{
    static const char response[] = DJONEHUBD_RESPONSE;

    /* A TCP handshake is the primary probe.  The greeting also gives the
     * future iOS control client a framing-safe first response without
     * accepting arbitrary commands at this stage. */
    (void)send_all(client_fd, response, sizeof(response) - 1U);
    (void)shutdown(client_fd, SHUT_WR);
    (void)close(client_fd);
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s [--listen-address IPv4] [--port PORT] [--once]\n",
            program);
}

int main(int argc, char **argv)
{
    const char *listen_address = DJONEHUBD_DEFAULT_ADDRESS;
    unsigned int port = DJONEHUBD_DEFAULT_PORT;
    int once = 0;
    int listener;
    int index;

    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--listen-address") == 0 &&
            index + 1 < argc) {
            listen_address = argv[++index];
        } else if (strcmp(argv[index], "--port") == 0 && index + 1 < argc) {
            if (parse_port(argv[++index], &port) != 0) {
                fprintf(stderr, "djonehubd: invalid port\n");
                return EXIT_FAILURE;
            }
        } else if (strcmp(argv[index], "--once") == 0) {
            once = 1;
        } else if (strcmp(argv[index], "--help") == 0 ||
                   strcmp(argv[index], "-h") == 0) {
            usage(argv[0]);
            return EXIT_SUCCESS;
        } else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (install_signal_handlers() != 0) {
        fprintf(stderr, "djonehubd: could not install signal handlers: %s\n",
                strerror(errno));
        return EXIT_FAILURE;
    }
    listener = create_listener(listen_address, port);
    if (listener < 0) {
        return EXIT_FAILURE;
    }
    fprintf(stderr, "djonehubd: listening on %s:%u\n", listen_address, port);

    while (!stop_requested) {
        int client_fd = accept(listener, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "djonehubd: accept: %s\n", strerror(errno));
            (void)close(listener);
            return EXIT_FAILURE;
        }
        serve_client(client_fd);
        if (once) {
            break;
        }
    }
    (void)close(listener);
    return EXIT_SUCCESS;
}
