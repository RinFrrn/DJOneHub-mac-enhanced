#define _GNU_SOURCE

/*
 * Authenticated QMI Voice control daemon for the QDC507 USB ECM link.
 *
 * One TCP connection carries exactly one challenge, one authenticated
 * request and one authenticated response.  Only status, dial, answer, end and
 * the fixed USB Audio gate are accepted; no shell, arbitrary AT or arbitrary
 * QMI surface is exposed.
 */

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

#include "djonehub_control_protocol.h"
#include "djonehub_qmi_voice_engine.h"
#include "djonehub_voice_daemon_policy.h"

#define CONTROL_ADDRESS "192.168.225.1"
#define CONTROL_INTERFACE "bridge0"
#define CONTROL_PORT 45750U
#define CONTROL_BACKLOG 4
#define CONTROL_TIMEOUT_SECONDS 5
#define RANDOM_DEVICE "/dev/urandom"
#define DEFAULT_KEY_FILE "/usrdata/djonehub/pairing.key"
#define VOICE_AUDIO_ENABLE_PATH "/sys/class/android_usb/f_audio/audio_enable"

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

static int random_nonce(uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES])
{
    size_t offset = 0U;
    int descriptor = open(RANDOM_DEVICE, O_RDONLY | O_CLOEXEC);

    if (descriptor < 0) {
        return -1;
    }
    while (offset < DJONEHUB_CONTROL_NONCE_BYTES) {
        ssize_t count = read(descriptor, nonce + offset,
                             DJONEHUB_CONTROL_NONCE_BYTES - offset);

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
    int flags;

    if (setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   (socklen_t)sizeof(timeout)) != 0 ||
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   (socklen_t)sizeof(timeout)) != 0) {
        return -1;
    }
    flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0) {
        return -1;
    }
    return 0;
}

static int create_listener(void)
{
    struct sockaddr_in address;
    int enabled = 1;
    int descriptor;
    int flags;

    descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0 ||
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled,
                   (socklen_t)sizeof(enabled)) != 0) {
        (void)close(descriptor);
        return -1;
    }
#ifdef SO_BINDTODEVICE
    if (setsockopt(descriptor, SOL_SOCKET, SO_BINDTODEVICE, CONTROL_INTERFACE,
                   (socklen_t)(sizeof(CONTROL_INTERFACE))) != 0) {
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

static enum djonehub_control_status map_engine_error(
    enum djonehub_qmi_voice_error error)
{
    if (error == DJONEHUB_QMI_VOICE_PRECONDITION) {
        return DJONEHUB_CONTROL_PRECONDITION;
    }
    if (error == DJONEHUB_QMI_VOICE_CONFIRM_TIMEOUT) {
        return DJONEHUB_CONTROL_CONFIRM_TIMEOUT;
    }
    if (error == DJONEHUB_QMI_VOICE_LIBRARY_LOAD ||
        error == DJONEHUB_QMI_VOICE_SERVICE_OBJECT ||
        error == DJONEHUB_QMI_VOICE_CLIENT_INIT ||
        error == DJONEHUB_QMI_VOICE_STATUS_QUERY ||
        error == DJONEHUB_QMI_VOICE_ACTION ||
        error == DJONEHUB_QMI_VOICE_CONFIRM_QUERY ||
        error == DJONEHUB_QMI_VOICE_RELEASE) {
        return DJONEHUB_CONTROL_QMI_FAILED;
    }
    return DJONEHUB_CONTROL_INTERNAL;
}

static enum djonehub_qmi_voice_error execute_request(
    const struct djonehub_control_request *request,
    struct djonehub_qmi_voice_result *result)
{
    char number[DJONEHUB_VOICE_MAX_NUMBER_BYTES];
    const char *number_argument = NULL;
    uint8_t call_id = 0U;

    memset(number, 0, sizeof(number));
    if (request->operation == DJONEHUB_VOICE_DIAL) {
        memcpy(number, request->payload, request->payload_length);
        number_argument = number;
    } else if (request->operation == DJONEHUB_VOICE_ANSWER ||
               request->operation == DJONEHUB_VOICE_END) {
        call_id = request->payload[0];
    }
    return djonehub_qmi_voice_execute(request->operation, number_argument,
                                      call_id, result);
}

static int snapshot_is_idle(const struct djonehub_voice_snapshot *snapshot)
{
    size_t index;

    if (snapshot == NULL) {
        return 0;
    }
    for (index = 0U; index < snapshot->count; ++index) {
        if (snapshot->calls[index].state != 0x09U) {
            return 0;
        }
    }
    return 1;
}

static int read_usb_audio_enabled(uint8_t *enabled)
{
    uint8_t value;
    ssize_t received;
    int descriptor;
    int saved_errno;

    if (enabled == NULL) {
        errno = EINVAL;
        return -1;
    }
    do {
        descriptor = open(VOICE_AUDIO_ENABLE_PATH, O_RDONLY | O_CLOEXEC);
    } while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) {
        return -1;
    }
    do {
        received = read(descriptor, &value, 1U);
    } while (received < 0 && errno == EINTR);
    saved_errno = errno;
    if (close(descriptor) != 0 && received == (ssize_t)1) {
        saved_errno = errno;
        received = -1;
    }
    if (received != (ssize_t)1) {
        errno = received == 0 ? EIO : saved_errno;
        return -1;
    }
    if (value != (uint8_t)'0' && value != (uint8_t)'1') {
        errno = EPROTO;
        return -1;
    }
    *enabled = value == (uint8_t)'1' ? 1U : 0U;
    return 0;
}

static int write_usb_audio_enabled(uint8_t enabled)
{
    const uint8_t value[2] = {enabled != 0U ? (uint8_t)'1' : (uint8_t)'0',
                              (uint8_t)'\n'};
    ssize_t written;
    int descriptor;
    int saved_errno;

    do {
        descriptor = open(VOICE_AUDIO_ENABLE_PATH, O_WRONLY | O_CLOEXEC);
    } while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) {
        return -1;
    }
    do {
        written = write(descriptor, value, sizeof(value));
    } while (written < 0 && errno == EINTR);
    saved_errno = errno;
    if (close(descriptor) != 0 && written == (ssize_t)sizeof(value)) {
        saved_errno = errno;
        written = -1;
    }
    if (written != (ssize_t)sizeof(value)) {
        errno = written >= 0 ? EIO : saved_errno;
        return -1;
    }
    return 0;
}

static enum djonehub_control_status execute_usb_audio_request(
    const struct djonehub_control_request *request,
    struct djonehub_control_result *control_result)
{
    struct djonehub_qmi_voice_result qmi_result;
    enum djonehub_qmi_voice_error qmi_error;
    uint8_t enabled;

    qmi_error = djonehub_qmi_voice_execute(DJONEHUB_VOICE_STATUS, NULL, 0U,
                                           &qmi_result);
    if (qmi_error != DJONEHUB_QMI_VOICE_SUCCESS) {
        daemon_logf("USB Audio status preflight failed: %s transport=%d service=%u",
                    djonehub_qmi_voice_error_name(qmi_error),
                    qmi_result.transport_error, qmi_result.service_error);
        return map_engine_error(qmi_error);
    }
    if (request->payload_length == 1U) {
        if (!snapshot_is_idle(&qmi_result.snapshot)) {
            return DJONEHUB_CONTROL_PRECONDITION;
        }
        if (write_usb_audio_enabled(request->payload[0]) != 0) {
            daemon_logf("write(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                        strerror(errno));
            return DJONEHUB_CONTROL_INTERNAL;
        }
    }
    if (read_usb_audio_enabled(&enabled) != 0 ||
        (request->payload_length == 1U && enabled != request->payload[0])) {
        daemon_logf("read-back(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                    strerror(errno));
        return DJONEHUB_CONTROL_INTERNAL;
    }
    memset(control_result, 0, sizeof(*control_result));
    control_result->operation = DJONEHUB_USB_AUDIO;
    control_result->action_call_id = enabled;
    control_result->confirmed = 1U;
    control_result->snapshot = qmi_result.snapshot;
    return DJONEHUB_CONTROL_OK;
}

static int handle_client(int descriptor,
                         const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
                         int status_only)
{
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t frame[DJONEHUB_CONTROL_MAX_FRAME_BYTES];
    struct djonehub_control_request request;
    struct djonehub_qmi_voice_result qmi_result;
    struct djonehub_control_result control_result;
    enum djonehub_qmi_voice_error qmi_error;
    enum djonehub_control_status status;
    size_t frame_length;
    uint16_t payload_length;

    if (random_nonce(nonce) != 0) {
        return -1;
    }
    frame_length = djonehub_control_encode_hello(nonce, frame, sizeof(frame));
    if (frame_length == 0U || write_exact(descriptor, frame, frame_length) != 0 ||
        read_exact(descriptor, frame, DJONEHUB_CONTROL_HEADER_BYTES) != 0) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    payload_length = (uint16_t)(((uint16_t)frame[8] << 8U) | frame[9]);
    if (payload_length > DJONEHUB_CONTROL_MAX_PAYLOAD) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    frame_length = DJONEHUB_CONTROL_HEADER_BYTES + (size_t)payload_length +
                   DJONEHUB_CONTROL_TAG_BYTES;
    if (read_exact(descriptor, frame + DJONEHUB_CONTROL_HEADER_BYTES,
                   frame_length - DJONEHUB_CONTROL_HEADER_BYTES) != 0 ||
        djonehub_control_decode_request(key, nonce, frame, frame_length,
                                        &request) != 0) {
        memset(nonce, 0, sizeof(nonce));
        return -1;
    }
    memset(&control_result, 0, sizeof(control_result));
    if (!djonehub_voice_daemon_operation_allowed(
            status_only, request.operation == DJONEHUB_VOICE_STATUS)) {
        frame_length = djonehub_control_encode_response(
            key, nonce, DJONEHUB_CONTROL_FORBIDDEN, request.request_id, NULL,
            frame, sizeof(frame));
        memset(nonce, 0, sizeof(nonce));
        if (frame_length == 0U ||
            write_exact(descriptor, frame, frame_length) != 0) {
            return -1;
        }
        return 0;
    }
    if (request.operation == DJONEHUB_USB_AUDIO) {
        status = execute_usb_audio_request(&request, &control_result);
        if (status == DJONEHUB_CONTROL_OK) {
            frame_length = djonehub_control_encode_response(
                key, nonce, status, request.request_id, &control_result, frame,
                sizeof(frame));
        } else {
            frame_length = djonehub_control_encode_response(
                key, nonce, status, request.request_id, NULL, frame,
                sizeof(frame));
        }
        memset(nonce, 0, sizeof(nonce));
        if (frame_length == 0U ||
            write_exact(descriptor, frame, frame_length) != 0) {
            return -1;
        }
        return 0;
    }
    qmi_error = execute_request(&request, &qmi_result);
    if (qmi_error == DJONEHUB_QMI_VOICE_SUCCESS) {
        status = DJONEHUB_CONTROL_OK;
        control_result.operation = request.operation;
        control_result.action_call_id = qmi_result.action_call_id;
        control_result.confirmed = qmi_result.confirmed;
        control_result.snapshot = qmi_result.snapshot;
        frame_length = djonehub_control_encode_response(
            key, nonce, status, request.request_id, &control_result, frame,
            sizeof(frame));
    } else {
        status = map_engine_error(qmi_error);
        daemon_logf("request %llu failed: %s transport=%d service=%u",
                    (unsigned long long)request.request_id,
                    djonehub_qmi_voice_error_name(qmi_error),
                    qmi_result.transport_error, qmi_result.service_error);
        frame_length = djonehub_control_encode_response(
            key, nonce, status, request.request_id, NULL, frame,
            sizeof(frame));
    }
    memset(nonce, 0, sizeof(nonce));
    if (frame_length == 0U || write_exact(descriptor, frame, frame_length) != 0) {
        return -1;
    }
    return 0;
}

static int parse_arguments(int argc, char **argv, const char **key_file,
                           int *once, int *status_only)
{
    int index;

    *key_file = DEFAULT_KEY_FILE;
    *once = 0;
    *status_only = 0;
    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--once") == 0) {
            *once = 1;
        } else if (strcmp(argv[index], "--status-only") == 0) {
            *status_only = 1;
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
    int status_only;
    int listener;
    int exit_status = EXIT_SUCCESS;

    if (parse_arguments(argc, argv, &key_file, &once, &status_only) != 0) {
        daemon_logf("usage: djonehub-voice-daemon [--once] [--status-only] "
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
    daemon_logf("authenticated control listening on %s:%u", CONTROL_ADDRESS,
                CONTROL_PORT);
    while (stop_requested == 0) {
        struct sockaddr_in peer;
        socklen_t peer_length = (socklen_t)sizeof(peer);
        int client = accept(listener, (struct sockaddr *)&peer, &peer_length);
        enum djonehub_voice_daemon_client_outcome outcome =
            DJONEHUB_DAEMON_CLIENT_REJECTED;

        if (client < 0) {
            if (errno == EINTR) {
                continue;
            }
            exit_status = EXIT_FAILURE;
            break;
        }
        if (peer_length == (socklen_t)sizeof(peer) &&
            peer.sin_family == AF_INET && peer_is_usb_host(&peer) &&
            configure_client(client) == 0) {
            if (handle_client(client, key, status_only) == 0) {
                outcome = DJONEHUB_DAEMON_AUTHENTICATED_RESPONSE_SENT;
            }
        }
        (void)close(client);
        /*
         * A reachability probe, wrong key, truncated frame or non-USB peer must
         * not consume the one-shot daemon.  Only a completely authenticated
         * request for which a signed response was sent completes --once.
         */
        if (djonehub_voice_daemon_should_stop(once, outcome)) {
            break;
        }
    }
    (void)close(listener);
    djonehub_qmi_voice_shutdown();
    memset(key, 0, sizeof(key));
    return exit_status;
}
