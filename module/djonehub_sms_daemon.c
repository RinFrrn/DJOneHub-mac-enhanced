#define _GNU_SOURCE

/* Authenticated, fixed-operation QMI WMS gateway for the QDC507 USB ECM link. */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include "djonehub_qmi_wms_engine.h"
#include "djonehub_sms_protocol.h"

#define CONTROL_ADDRESS "192.168.225.1"
#define CONTROL_INTERFACE "bridge0"
#define CONTROL_PORT 45752U
#define CONTROL_BACKLOG 4
#define CONTROL_TIMEOUT_SECONDS 5
#define RANDOM_DEVICE "/dev/urandom"
#define DEFAULT_KEY_FILE "/usrdata/djonehub/pairing.key"

static volatile sig_atomic_t stop_requested;

static void daemon_logf(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

static void daemon_logf(const char *format, ...)
{
    char buffer[512];
    va_list arguments;
    int count;
    size_t length;
    ssize_t ignored;

    va_start(arguments, format);
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
#endif
    count = vsnprintf(buffer, sizeof(buffer), format, arguments);
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    va_end(arguments);
    if (count <= 0) {
        return;
    }
    length = (size_t)count;
    if (length >= sizeof(buffer) - 1U) {
        length = sizeof(buffer) - 2U;
    }
    buffer[length++] = '\n';
    do {
        ignored = write(STDERR_FILENO, buffer, length);
    } while (ignored < 0 && errno == EINTR);
}

static void request_stop(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int install_signal_handlers(void)
{
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    if (sigemptyset(&action.sa_mask) != 0 ||
        sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0) {
        return -1;
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    if (sigemptyset(&action.sa_mask) != 0 ||
        sigaction(SIGPIPE, &action, NULL) != 0) {
        return -1;
    }
    return 0;
}

static int read_exact(int descriptor, uint8_t *buffer, size_t length)
{
    size_t offset = 0U;

    while (offset < length) {
        ssize_t count = recv(descriptor, buffer + offset, length - offset, 0);

        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static int write_exact(int descriptor, const uint8_t *buffer, size_t length)
{
    size_t offset = 0U;

    while (offset < length) {
        ssize_t count = send(descriptor, buffer + offset, length - offset, 0);

        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

static int random_nonce(uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES])
{
    size_t offset = 0U;
    int descriptor = open(RANDOM_DEVICE, O_RDONLY | O_CLOEXEC);

    if (descriptor < 0) {
        return -1;
    }
    while (offset < DJONEHUB_SMS_NONCE_BYTES) {
        ssize_t count = read(descriptor, nonce + offset,
                             DJONEHUB_SMS_NONCE_BYTES - offset);

        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            (void)close(descriptor);
            return -1;
        }
    }
    return close(descriptor) == 0 ? 0 : -1;
}

static int valid_key_owner(const char *path)
{
    struct stat attributes;

    if (geteuid() != 0U || lstat(path, &attributes) != 0 ||
        !S_ISREG(attributes.st_mode) || attributes.st_uid != 0U ||
        (attributes.st_mode & 0077) != 0) {
        errno = EACCES;
        return 0;
    }
    return 1;
}

static int peer_is_usb_host(const struct sockaddr_in *peer)
{
    uint32_t address = ntohl(peer->sin_addr.s_addr);

    return (address & 0xffffff00U) == 0xc0a8e100U &&
           address != 0xc0a8e101U;
}

static int configure_client(int descriptor)
{
    const struct timeval timeout = {CONTROL_TIMEOUT_SECONDS, 0};

    if (setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   (socklen_t)sizeof(timeout)) != 0 ||
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   (socklen_t)sizeof(timeout)) != 0) {
        return -1;
    }
    return 0;
}

static int create_listener(void)
{
    struct sockaddr_in address;
    int enabled = 1;
    int descriptor = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);

    if (descriptor < 0) {
        return -1;
    }
    if (setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled,
                   (socklen_t)sizeof(enabled)) != 0) {
        (void)close(descriptor);
        return -1;
    }
#ifdef SO_BINDTODEVICE
    if (setsockopt(descriptor, SOL_SOCKET, SO_BINDTODEVICE, CONTROL_INTERFACE,
                   (socklen_t)sizeof(CONTROL_INTERFACE)) != 0) {
        (void)close(descriptor);
        return -1;
    }
#endif
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(CONTROL_PORT);
    if (inet_pton(AF_INET, CONTROL_ADDRESS, &address.sin_addr) != 1 ||
        bind(descriptor, (const struct sockaddr *)&address,
             (socklen_t)sizeof(address)) != 0 ||
        listen(descriptor, CONTROL_BACKLOG) != 0) {
        (void)close(descriptor);
        return -1;
    }
    return descriptor;
}

static uint32_t load_be32(const uint8_t *input)
{
    return ((uint32_t)input[0] << 24U) | ((uint32_t)input[1] << 16U) |
           ((uint32_t)input[2] << 8U) | input[3];
}

static void store_be16(uint8_t *output, uint16_t value)
{
    output[0] = (uint8_t)(value >> 8U);
    output[1] = (uint8_t)value;
}

static void store_be32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)(value >> 24U);
    output[1] = (uint8_t)(value >> 16U);
    output[2] = (uint8_t)(value >> 8U);
    output[3] = (uint8_t)value;
}

static enum djonehub_sms_status map_error(enum djonehub_qmi_wms_error error)
{
    if (error == DJONEHUB_QMI_WMS_LIMIT_EXCEEDED) {
        return DJONEHUB_SMS_LIMIT_EXCEEDED;
    }
    if (error == DJONEHUB_QMI_WMS_INVALID_INPUT) {
        return DJONEHUB_SMS_MALFORMED;
    }
    if (error == DJONEHUB_QMI_WMS_LIBRARY_LOAD ||
        error == DJONEHUB_QMI_WMS_SERVICE_OBJECT ||
        error == DJONEHUB_QMI_WMS_CLIENT_INIT ||
        error == DJONEHUB_QMI_WMS_TRANSPORT ||
        error == DJONEHUB_QMI_WMS_SERVICE) {
        return DJONEHUB_SMS_QMI_FAILED;
    }
    return DJONEHUB_SMS_INTERNAL;
}

static enum djonehub_qmi_wms_error execute_request(
    const struct djonehub_sms_request *request,
    struct djonehub_qmi_wms_result *result, uint8_t *payload,
    size_t *payload_length)
{
    enum djonehub_qmi_wms_error error;
    uint8_t storage = 0U;
    uint32_t index = 0U;
    size_t cursor = 0U;

    if (request->payload_length != 0U) {
        storage = request->payload[0];
    }
    if (request->payload_length >= 5U) {
        index = load_be32(request->payload + 1U);
    }
    if (request->operation == DJONEHUB_SMS_STATUS) {
        error = djonehub_qmi_wms_get_status(result);
        if (error == DJONEHUB_QMI_WMS_SUCCESS) {
            payload[0] = result->status.protocol;
            payload[1] = result->status.registration;
            payload[2] = result->status.registration_available;
            payload[3] = result->status.idl_major;
            payload[4] = result->status.idl_minor;
            payload[5] = result->status.idl_tool;
            *payload_length = 6U;
        }
        return error;
    }
    if (request->operation == DJONEHUB_SMS_LIST) {
        size_t message_index;

        error = djonehub_qmi_wms_list(storage, result);
        if (error != DJONEHUB_QMI_WMS_SUCCESS) {
            return error;
        }
        if (result->message_count > UINT16_MAX ||
            3U + result->message_count * 5U >
                DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD) {
            return DJONEHUB_QMI_WMS_LIMIT_EXCEEDED;
        }
        payload[cursor++] = storage;
        store_be16(payload + cursor, (uint16_t)result->message_count);
        cursor += 2U;
        for (message_index = 0U; message_index < result->message_count;
             ++message_index) {
            store_be32(payload + cursor,
                       result->messages[message_index].index);
            cursor += 4U;
            payload[cursor++] = result->messages[message_index].tag;
        }
        *payload_length = cursor;
        return error;
    }
    if (request->operation == DJONEHUB_SMS_READ) {
        error = djonehub_qmi_wms_read(storage, index, result);
        if (error != DJONEHUB_QMI_WMS_SUCCESS) {
            return error;
        }
        payload[0] = storage;
        store_be32(payload + 1U, index);
        payload[5] = result->message.has_tag != 0U ? result->message.tag : 0xffU;
        payload[6] = result->message.format;
        store_be16(payload + 7U, (uint16_t)result->message.pdu_length);
        memcpy(payload + 9U, result->message.pdu,
               result->message.pdu_length);
        *payload_length = 9U + result->message.pdu_length;
        return error;
    }
    if (request->operation == DJONEHUB_SMS_SEND_RAW) {
        size_t pdu_length = ((size_t)request->payload[1] << 8U) |
                            request->payload[2];

        error = djonehub_qmi_wms_send_raw(
            request->payload[0], request->payload + 3U, pdu_length, result);
        if (error == DJONEHUB_QMI_WMS_SUCCESS) {
            store_be16(payload, result->sent_message_id);
            *payload_length = 2U;
        }
        return error;
    }
    error = djonehub_qmi_wms_delete(storage, index, result);
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        payload[0] = storage;
        store_be32(payload + 1U, index);
        *payload_length = 5U;
    }
    return error;
}

static int handle_client(int descriptor,
                         const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
                         int read_only)
{
    uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES];
    uint8_t request_frame[DJONEHUB_SMS_MAX_REQUEST_FRAME_BYTES];
    uint8_t response_frame[DJONEHUB_SMS_MAX_RESPONSE_FRAME_BYTES];
    uint8_t response_payload[DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD];
    struct djonehub_sms_request request;
    struct djonehub_qmi_wms_result result;
    enum djonehub_qmi_wms_error qmi_error;
    enum djonehub_sms_status status;
    size_t frame_length;
    size_t response_length = 0U;
    uint16_t payload_length;

    if (random_nonce(nonce) != 0) {
        return -1;
    }
    frame_length = djonehub_sms_encode_hello(nonce, response_frame,
                                             sizeof(response_frame));
    if (frame_length == 0U ||
        write_exact(descriptor, response_frame, frame_length) != 0 ||
        read_exact(descriptor, request_frame, DJONEHUB_SMS_HEADER_BYTES) != 0) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    payload_length = (uint16_t)(((uint16_t)request_frame[8] << 8U) |
                                request_frame[9]);
    if (payload_length > DJONEHUB_SMS_MAX_REQUEST_PAYLOAD) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    frame_length = DJONEHUB_SMS_HEADER_BYTES + (size_t)payload_length +
                   DJONEHUB_SMS_TAG_BYTES;
    if (read_exact(descriptor, request_frame + DJONEHUB_SMS_HEADER_BYTES,
                   frame_length - DJONEHUB_SMS_HEADER_BYTES) != 0 ||
        djonehub_sms_decode_request(key, nonce, request_frame, frame_length,
                                    &request) != 0) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    if (read_only != 0 &&
        (request.operation == DJONEHUB_SMS_SEND_RAW ||
         request.operation == DJONEHUB_SMS_DELETE)) {
        status = DJONEHUB_SMS_FORBIDDEN;
    } else {
        memset(&result, 0, sizeof(result));
        qmi_error = execute_request(&request, &result, response_payload,
                                    &response_length);
        status = qmi_error == DJONEHUB_QMI_WMS_SUCCESS
                     ? DJONEHUB_SMS_OK
                     : map_error(qmi_error);
        if (qmi_error != DJONEHUB_QMI_WMS_SUCCESS) {
            response_length = 0U;
            daemon_logf("request %llu operation=%u failed: %s transport=%d service=%u",
                        (unsigned long long)request.request_id,
                        (unsigned int)request.operation,
                        djonehub_qmi_wms_error_name(qmi_error),
                        result.transport_error, result.service_error);
        }
    }
    frame_length = djonehub_sms_encode_response(
        key, nonce, status, request.request_id, request.operation,
        response_length == 0U ? NULL : response_payload, response_length,
        response_frame, sizeof(response_frame));
    memset(nonce, 0, sizeof(nonce));
    memset(response_payload, 0, sizeof(response_payload));
    if (frame_length == 0U ||
        write_exact(descriptor, response_frame, frame_length) != 0) {
        return -1;
    }
    return 0;
}

static int parse_arguments(int argc, char **argv, const char **key_file,
                           int *once, int *read_only)
{
    int index;

    *key_file = DEFAULT_KEY_FILE;
    *once = 0;
    *read_only = 0;
    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--once") == 0) {
            *once = 1;
        } else if (strcmp(argv[index], "--read-only") == 0) {
            *read_only = 1;
        } else if (strcmp(argv[index], "--key-file") == 0 &&
                   index + 1 < argc) {
            *key_file = argv[++index];
        } else {
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    const char *key_file;
    int once;
    int read_only;
    int listener;
    int exit_status = EXIT_SUCCESS;

    if (parse_arguments(argc, argv, &key_file, &once, &read_only) != 0) {
        daemon_logf("usage: djonehub-sms-daemon [--once] [--read-only] "
                    "[--key-file PATH]");
        return EXIT_FAILURE;
    }
    if (!valid_key_owner(key_file) ||
        djonehub_load_pairing_key(key_file, key) != 0) {
        daemon_logf("refusing insecure pairing key: %s", strerror(errno));
        return EXIT_FAILURE;
    }
    if (install_signal_handlers() != 0) {
        daemon_logf("signal setup failed: %s", strerror(errno));
        memset(key, 0, sizeof(key));
        return EXIT_FAILURE;
    }
    listener = create_listener();
    if (listener < 0) {
        daemon_logf("listen on %s:%u failed: %s", CONTROL_ADDRESS,
                    CONTROL_PORT, strerror(errno));
        memset(key, 0, sizeof(key));
        return EXIT_FAILURE;
    }
    daemon_logf("authenticated SMS control listening on %s:%u",
                CONTROL_ADDRESS, CONTROL_PORT);
    while (stop_requested == 0) {
        struct sockaddr_in peer;
        socklen_t peer_length = (socklen_t)sizeof(peer);
        int client = accept4(listener, (struct sockaddr *)&peer, &peer_length,
                             SOCK_CLOEXEC);
        int handled = 0;

        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            exit_status = EXIT_FAILURE;
            break;
        }
        if (peer_length == (socklen_t)sizeof(peer) &&
            peer.sin_family == AF_INET && peer_is_usb_host(&peer) &&
            configure_client(client) == 0 &&
            handle_client(client, key, read_only) == 0) {
            handled = 1;
        }
        (void)close(client);
        if (once != 0 && handled != 0) {
            break;
        }
    }
    (void)close(listener);
    djonehub_qmi_wms_shutdown();
    memset(key, 0, sizeof(key));
    return exit_status;
}
