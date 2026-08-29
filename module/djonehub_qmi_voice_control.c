#define _POSIX_C_SOURCE 200809L

/*
 * One-shot QMI Voice control candidate for the QDC507 module.
 *
 * This is deliberately not a network daemon and does not accept arbitrary
 * QMI message IDs.  It exposes only status, dial, answer, and end.  Every
 * mutating operation checks the current call snapshot before sending a fixed
 * message and then reads the snapshot back to confirm the transition.
 */

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "djonehub_voice_codec.h"
#include "djonehub_voice_policy.h"

#define VOICE_IDL_MAJOR 0x02U
#define VOICE_IDL_MINOR 0x4DU
#define VOICE_IDL_TOOL 0x06U
#define QMI_CLIENT_INSTANCE_ANY 0xFFFFU
#define QMI_NO_ERR 0
#define QMI_VOICE_DIAL_CALL 0x0020U
#define QMI_VOICE_END_CALL 0x0021U
#define QMI_VOICE_ANSWER_CALL 0x0022U
#define QMI_VOICE_GET_ALL_CALL_INFO 0x002FU
#define QMI_TIMEOUT_MS 5000U
#define RESPONSE_CAPACITY 16384U
#define CONFIRM_ATTEMPTS 20U
#define CONFIRM_INTERVAL_NS 250000000L

typedef void *qmi_client_type;
typedef void *qmi_idl_service_object_type;

struct qmi_client_os_params {
    uint32_t sig_set;
    uint32_t timed_out;
    uint32_t clock;
    pthread_cond_t cond;
    pthread_condattr_t attr;
    pthread_mutex_t mutex;
};

typedef qmi_idl_service_object_type (*voice_get_service_object_fn)(
    int32_t major, int32_t minor, int32_t tool);
typedef int (*qmi_client_init_instance_fn)(
    qmi_idl_service_object_type service_object, unsigned int instance_id,
    void *indication_callback, void *indication_data, void *os_params,
    uint32_t timeout_ms, qmi_client_type *client);
typedef int (*qmi_client_send_raw_msg_sync_fn)(
    qmi_client_type client, unsigned int message_id, void *request,
    unsigned int request_length, void *response,
    unsigned int response_capacity, unsigned int *response_length,
    unsigned int timeout_ms);
typedef int (*qmi_client_release_fn)(qmi_client_type client);

struct qmi_api {
    void *services_library;
    void *client_library;
    voice_get_service_object_fn get_voice_service_object;
    qmi_client_init_instance_fn client_init_instance;
    qmi_client_send_raw_msg_sync_fn send_raw_sync;
    qmi_client_release_fn client_release;
};

static void control_write(const char *data, size_t length)
{
#if defined(__arm__)
    register long result __asm__("r0") = 2L;
    register const char *buffer __asm__("r1") = data;
    register size_t count __asm__("r2") = length;
    register long syscall_number __asm__("r7") = 4L;

    __asm__ volatile("svc 0"
                     : "+r"(result)
                     : "r"(buffer), "r"(count), "r"(syscall_number)
                     : "memory", "cc");
    (void)result;
#else
#error "djonehub_qmi_voice_control requires the ARM EABI write syscall"
#endif
}

static void control_log(const char *text)
{
    size_t length = 0U;

    while (text[length] != '\0') {
        ++length;
    }
    control_write(text, length);
}

static void control_logf(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

static void control_logf(const char *format, ...)
{
    char buffer[768];
    va_list arguments;
    int length;
    size_t output_length;

    va_start(arguments, format);
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
#endif
    length = vsnprintf(buffer, sizeof(buffer), format, arguments);
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    va_end(arguments);
    if (length <= 0) {
        return;
    }
    output_length = (size_t)length;
    if (output_length >= sizeof(buffer)) {
        output_length = sizeof(buffer) - 1U;
    }
    control_write(buffer, output_length);
}

static int load_symbol(void *library, const char *name, void *target,
                       size_t target_size)
{
    void *symbol;
    const char *error_text;

    (void)dlerror();
    symbol = dlsym(library, name);
    error_text = dlerror();
    if (error_text != NULL || symbol == NULL ||
        target_size != sizeof(symbol)) {
        return -1;
    }
    memcpy(target, &symbol, sizeof(symbol));
    return 0;
}

static void unload_qmi_api(struct qmi_api *api)
{
    if (api->client_library != NULL) {
        (void)dlclose(api->client_library);
    }
    if (api->services_library != NULL) {
        (void)dlclose(api->services_library);
    }
    memset(api, 0, sizeof(*api));
}

static int load_qmi_api(struct qmi_api *api)
{
    memset(api, 0, sizeof(*api));
    api->services_library = dlopen("libqmiservices.so.1", RTLD_NOW | RTLD_LOCAL);
    if (api->services_library == NULL) {
        return -1;
    }
    api->client_library = dlopen("libqmi_cci.so.1", RTLD_NOW | RTLD_LOCAL);
    if (api->client_library == NULL) {
        unload_qmi_api(api);
        return -1;
    }
    if (load_symbol(api->services_library,
                    "voice_get_service_object_internal_v02",
                    &api->get_voice_service_object,
                    sizeof(api->get_voice_service_object)) != 0 ||
        load_symbol(api->client_library, "qmi_client_init_instance",
                    &api->client_init_instance,
                    sizeof(api->client_init_instance)) != 0 ||
        load_symbol(api->client_library, "qmi_client_send_raw_msg_sync",
                    &api->send_raw_sync, sizeof(api->send_raw_sync)) != 0 ||
        load_symbol(api->client_library, "qmi_client_release",
                    &api->client_release, sizeof(api->client_release)) != 0) {
        unload_qmi_api(api);
        return -1;
    }
    return 0;
}

static int query_snapshot(const struct qmi_api *api, qmi_client_type client,
                          struct djonehub_voice_snapshot *snapshot,
                          unsigned int *service_error)
{
    uint8_t response[RESPONSE_CAPACITY];
    uint8_t empty_request = 0U;
    unsigned int response_length = 0U;
    int result;

    memset(response, 0, sizeof(response));
    result = api->send_raw_sync(
        client, QMI_VOICE_GET_ALL_CALL_INFO, &empty_request, 0U, response,
        (unsigned int)sizeof(response), &response_length, QMI_TIMEOUT_MS);
    if (result != QMI_NO_ERR ||
        response_length > (unsigned int)sizeof(response)) {
        return -2;
    }
    return djonehub_voice_parse_snapshot(
        response, (size_t)response_length, snapshot, service_error);
}

static int send_action(const struct qmi_api *api, qmi_client_type client,
                       unsigned int message_id, uint8_t *request,
                       size_t request_length, uint8_t *call_id,
                       unsigned int *service_error)
{
    uint8_t response[RESPONSE_CAPACITY];
    unsigned int response_length = 0U;
    int call_id_present = 0;
    int result;

    if (request_length > (size_t)UINT_MAX) {
        return -1;
    }
    memset(response, 0, sizeof(response));
    result = api->send_raw_sync(
        client, message_id, request, (unsigned int)request_length, response,
        (unsigned int)sizeof(response), &response_length, QMI_TIMEOUT_MS);
    if (result != QMI_NO_ERR ||
        response_length > (unsigned int)sizeof(response)) {
        return -2;
    }
    result = djonehub_voice_parse_action_response(
        response, (size_t)response_length, call_id, &call_id_present,
        service_error);
    if (result == 0 && call_id_present == 0) {
        return -1;
    }
    return result;
}

static void print_snapshot(const struct djonehub_voice_snapshot *snapshot)
{
    size_t index;

    control_logf("{\"ok\":true,\"operation\":\"status\","
                 "\"call_count\":%u,\"calls\":[",
                 (unsigned int)snapshot->count);
    for (index = 0U; index < snapshot->count; ++index) {
        const struct djonehub_voice_call *call = &snapshot->calls[index];

        control_logf("%s{\"id\":%u,\"state\":%u,\"state_name\":\"%s\","
                     "\"type\":%u,\"direction\":%u,\"mode\":%u}",
                     index == 0U ? "" : ",", (unsigned int)call->id,
                     (unsigned int)call->state,
                     djonehub_voice_call_state_name(call->state),
                     (unsigned int)call->type,
                     (unsigned int)call->direction,
                     (unsigned int)call->mode);
    }
    control_log("]}\n");
}

static int parse_call_id(const char *text, uint8_t *call_id)
{
    char *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] == '\0' || call_id == NULL) {
        return -1;
    }
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0UL ||
        value > 255UL) {
        return -1;
    }
    *call_id = (uint8_t)value;
    return 0;
}

static int parse_operation(int argc, char **argv,
                           enum djonehub_voice_operation *operation,
                           const char **number, uint8_t *call_id)
{
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        *operation = DJONEHUB_VOICE_STATUS;
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "dial") == 0) {
        *operation = DJONEHUB_VOICE_DIAL;
        *number = argv[2];
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "answer") == 0 &&
        parse_call_id(argv[2], call_id) == 0) {
        *operation = DJONEHUB_VOICE_ANSWER;
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "end") == 0 &&
        parse_call_id(argv[2], call_id) == 0) {
        *operation = DJONEHUB_VOICE_END;
        return 0;
    }
    return -1;
}

static int wait_for_confirmation(const struct qmi_api *api,
                                 qmi_client_type client,
                                 enum djonehub_voice_operation operation,
                                 uint8_t call_id,
                                 struct djonehub_voice_snapshot *snapshot)
{
    const struct timespec interval = {0, CONFIRM_INTERVAL_NS};
    unsigned int service_error = 0U;
    unsigned int attempt;

    for (attempt = 0U; attempt < CONFIRM_ATTEMPTS; ++attempt) {
        int result = query_snapshot(api, client, snapshot, &service_error);

        if (result != 0) {
            return -1;
        }
        if (djonehub_voice_action_confirmed(operation, snapshot, call_id)) {
            return 0;
        }
        (void)nanosleep(&interval, NULL);
    }
    return 1;
}

static const char *operation_name(enum djonehub_voice_operation operation)
{
    switch (operation) {
    case DJONEHUB_VOICE_STATUS:
        return "status";
    case DJONEHUB_VOICE_DIAL:
        return "dial";
    case DJONEHUB_VOICE_ANSWER:
        return "answer";
    case DJONEHUB_VOICE_END:
        return "end";
    default:
        return "invalid";
    }
}

int main(int argc, char **argv)
{
    struct qmi_api api;
    qmi_idl_service_object_type service_object;
    qmi_client_type client = NULL;
    struct qmi_client_os_params os_params;
    struct djonehub_voice_snapshot snapshot;
    enum djonehub_voice_operation operation = DJONEHUB_VOICE_STATUS;
    const char *number = NULL;
    uint8_t requested_call_id = 0U;
    uint8_t action_call_id = 0U;
    uint8_t request[DJONEHUB_VOICE_MAX_NUMBER_BYTES + 3U];
    size_t request_length = 0U;
    unsigned int service_error = 0U;
    unsigned int message_id = 0U;
    int result;
    int exit_status = EXIT_FAILURE;

    if (parse_operation(argc, argv, &operation, &number,
                        &requested_call_id) != 0) {
        control_log("usage: djonehub-qmi-voice-control "
                    "status|dial NUMBER|answer CALL_ID|end CALL_ID\n");
        return EXIT_FAILURE;
    }
    if (load_qmi_api(&api) != 0) {
        control_log("{\"ok\":false,\"error\":\"qmi-library-load\"}\n");
        return EXIT_FAILURE;
    }
    service_object = api.get_voice_service_object(
        (int32_t)VOICE_IDL_MAJOR, (int32_t)VOICE_IDL_MINOR,
        (int32_t)VOICE_IDL_TOOL);
    if (service_object == NULL) {
        control_log("{\"ok\":false,\"error\":\"voice-service-object\"}\n");
        goto cleanup;
    }
    memset(&os_params, 0, sizeof(os_params));
    result = api.client_init_instance(
        service_object, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, &os_params,
        QMI_TIMEOUT_MS, &client);
    if (result != QMI_NO_ERR || client == NULL) {
        control_logf("{\"ok\":false,\"error\":\"qmi-client-init\","
                     "\"transport_error\":%d}\n", result);
        goto cleanup;
    }
    result = query_snapshot(&api, client, &snapshot, &service_error);
    if (result != 0) {
        control_logf("{\"ok\":false,\"error\":\"status-query\","
                     "\"result\":%d,\"service_error\":%u}\n",
                     result, service_error);
        goto cleanup;
    }
    if (operation == DJONEHUB_VOICE_STATUS) {
        print_snapshot(&snapshot);
        exit_status = EXIT_SUCCESS;
        goto cleanup;
    }
    if (!djonehub_voice_action_allowed(operation, &snapshot,
                                       requested_call_id)) {
        control_logf("{\"ok\":false,\"operation\":\"%s\","
                     "\"error\":\"state-precondition\"}\n",
                     operation_name(operation));
        goto cleanup;
    }
    if (operation == DJONEHUB_VOICE_DIAL) {
        if (djonehub_voice_build_dial_request(
                number, request, sizeof(request), &request_length) != 0) {
            control_log("{\"ok\":false,\"operation\":\"dial\","
                        "\"error\":\"invalid-number\"}\n");
            goto cleanup;
        }
        message_id = QMI_VOICE_DIAL_CALL;
    } else {
        if (djonehub_voice_build_call_id_request(
                requested_call_id, request, sizeof(request),
                &request_length) != 0) {
            control_log("{\"ok\":false,\"error\":\"invalid-call-id\"}\n");
            goto cleanup;
        }
        message_id = operation == DJONEHUB_VOICE_ANSWER
                         ? QMI_VOICE_ANSWER_CALL
                         : QMI_VOICE_END_CALL;
    }
    result = send_action(&api, client, message_id, request, request_length,
                         &action_call_id, &service_error);
    if (result != 0) {
        control_logf("{\"ok\":false,\"operation\":\"%s\","
                     "\"error\":\"qmi-action\",\"result\":%d,"
                     "\"service_error\":%u}\n",
                     operation_name(operation), result, service_error);
        goto cleanup;
    }
    if (operation != DJONEHUB_VOICE_DIAL &&
        action_call_id != requested_call_id) {
        control_log("{\"ok\":false,\"error\":\"call-id-mismatch\"}\n");
        goto cleanup;
    }
    result = wait_for_confirmation(&api, client, operation, action_call_id,
                                   &snapshot);
    if (result != 0) {
        control_logf("{\"ok\":false,\"operation\":\"%s\","
                     "\"call_id\":%u,\"error\":\"state-confirmation\","
                     "\"result\":%d}\n",
                     operation_name(operation),
                     (unsigned int)action_call_id, result);
        goto cleanup;
    }
    control_logf("{\"ok\":true,\"operation\":\"%s\","
                 "\"call_id\":%u,\"confirmed\":true}\n",
                 operation_name(operation), (unsigned int)action_call_id);
    exit_status = EXIT_SUCCESS;

cleanup:
    if (client != NULL && api.client_release(client) != QMI_NO_ERR) {
        exit_status = EXIT_FAILURE;
    }
    unload_qmi_api(&api);
    return exit_status;
}
