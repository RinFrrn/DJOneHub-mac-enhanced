#define _POSIX_C_SOURCE 200809L

#include "djonehub_qmi_voice_engine.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

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
                          int *transport_error,
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
    *transport_error = result;
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
                       int *transport_error, unsigned int *service_error)
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
    *transport_error = result;
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

static int wait_for_confirmation(const struct qmi_api *api,
                                 qmi_client_type client,
                                 enum djonehub_voice_operation operation,
                                 uint8_t call_id,
                                 struct djonehub_qmi_voice_result *result)
{
    const struct timespec interval = {0, CONFIRM_INTERVAL_NS};
    unsigned int attempt;

    for (attempt = 0U; attempt < CONFIRM_ATTEMPTS; ++attempt) {
        int query_result = query_snapshot(
            api, client, &result->snapshot, &result->transport_error,
            &result->service_error);

        if (query_result != 0) {
            return -1;
        }
        if (djonehub_voice_action_confirmed(operation, &result->snapshot,
                                             call_id)) {
            return 0;
        }
        (void)nanosleep(&interval, NULL);
    }
    return 1;
}

static enum djonehub_qmi_voice_error run_operation(
    const struct qmi_api *api, qmi_client_type client,
    enum djonehub_voice_operation operation, const char *number,
    uint8_t requested_call_id, struct djonehub_qmi_voice_result *result)
{
    uint8_t request[DJONEHUB_VOICE_MAX_NUMBER_BYTES + 3U];
    size_t request_length = 0U;
    unsigned int message_id;
    int action_result;
    int confirmation_result;

    action_result = query_snapshot(api, client, &result->snapshot,
                                   &result->transport_error,
                                   &result->service_error);
    if (action_result != 0) {
        return DJONEHUB_QMI_VOICE_STATUS_QUERY;
    }
    if (operation == DJONEHUB_VOICE_STATUS) {
        return DJONEHUB_QMI_VOICE_SUCCESS;
    }
    if (!djonehub_voice_action_allowed(operation, &result->snapshot,
                                       requested_call_id)) {
        return DJONEHUB_QMI_VOICE_PRECONDITION;
    }
    if (operation == DJONEHUB_VOICE_DIAL) {
        if (djonehub_voice_build_dial_request(
                number, request, sizeof(request), &request_length) != 0) {
            return DJONEHUB_QMI_VOICE_INVALID_INPUT;
        }
        message_id = QMI_VOICE_DIAL_CALL;
    } else if (operation == DJONEHUB_VOICE_ANSWER ||
               operation == DJONEHUB_VOICE_END) {
        if (djonehub_voice_build_call_id_request(
                requested_call_id, request, sizeof(request),
                &request_length) != 0) {
            return DJONEHUB_QMI_VOICE_INVALID_INPUT;
        }
        message_id = operation == DJONEHUB_VOICE_ANSWER
                         ? QMI_VOICE_ANSWER_CALL
                         : QMI_VOICE_END_CALL;
    } else {
        return DJONEHUB_QMI_VOICE_INVALID_INPUT;
    }
    action_result = send_action(
        api, client, message_id, request, request_length,
        &result->action_call_id, &result->transport_error,
        &result->service_error);
    if (action_result != 0) {
        return DJONEHUB_QMI_VOICE_ACTION;
    }
    if (operation != DJONEHUB_VOICE_DIAL &&
        result->action_call_id != requested_call_id) {
        return DJONEHUB_QMI_VOICE_CALL_ID_MISMATCH;
    }
    confirmation_result = wait_for_confirmation(
        api, client, operation, result->action_call_id, result);
    if (confirmation_result < 0) {
        return DJONEHUB_QMI_VOICE_CONFIRM_QUERY;
    }
    if (confirmation_result > 0) {
        return DJONEHUB_QMI_VOICE_CONFIRM_TIMEOUT;
    }
    result->confirmed = 1U;
    return DJONEHUB_QMI_VOICE_SUCCESS;
}

enum djonehub_qmi_voice_error djonehub_qmi_voice_execute(
    enum djonehub_voice_operation operation, const char *number,
    uint8_t call_id, struct djonehub_qmi_voice_result *result)
{
    struct qmi_api api;
    qmi_idl_service_object_type service_object;
    qmi_client_type client = NULL;
    struct qmi_client_os_params os_params;
    enum djonehub_qmi_voice_error error;
    int init_result;
    int release_result;

    if (result == NULL) {
        return DJONEHUB_QMI_VOICE_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    if (load_qmi_api(&api) != 0) {
        return DJONEHUB_QMI_VOICE_LIBRARY_LOAD;
    }
    service_object = api.get_voice_service_object(
        (int32_t)VOICE_IDL_MAJOR, (int32_t)VOICE_IDL_MINOR,
        (int32_t)VOICE_IDL_TOOL);
    if (service_object == NULL) {
        unload_qmi_api(&api);
        return DJONEHUB_QMI_VOICE_SERVICE_OBJECT;
    }
    memset(&os_params, 0, sizeof(os_params));
    init_result = api.client_init_instance(
        service_object, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, &os_params,
        QMI_TIMEOUT_MS, &client);
    result->transport_error = init_result;
    if (init_result != QMI_NO_ERR || client == NULL) {
        unload_qmi_api(&api);
        return DJONEHUB_QMI_VOICE_CLIENT_INIT;
    }
    error = run_operation(&api, client, operation, number, call_id, result);
    release_result = api.client_release(client);
    if (release_result != QMI_NO_ERR &&
        error == DJONEHUB_QMI_VOICE_SUCCESS &&
        operation == DJONEHUB_VOICE_STATUS) {
        result->transport_error = release_result;
        error = DJONEHUB_QMI_VOICE_RELEASE;
    }
    unload_qmi_api(&api);
    return error;
}

const char *djonehub_qmi_voice_error_name(
    enum djonehub_qmi_voice_error error)
{
    switch (error) {
    case DJONEHUB_QMI_VOICE_SUCCESS:
        return "ok";
    case DJONEHUB_QMI_VOICE_LIBRARY_LOAD:
        return "qmi-library-load";
    case DJONEHUB_QMI_VOICE_SERVICE_OBJECT:
        return "voice-service-object";
    case DJONEHUB_QMI_VOICE_CLIENT_INIT:
        return "qmi-client-init";
    case DJONEHUB_QMI_VOICE_STATUS_QUERY:
        return "status-query";
    case DJONEHUB_QMI_VOICE_PRECONDITION:
        return "state-precondition";
    case DJONEHUB_QMI_VOICE_INVALID_INPUT:
        return "invalid-input";
    case DJONEHUB_QMI_VOICE_ACTION:
        return "qmi-action";
    case DJONEHUB_QMI_VOICE_CALL_ID_MISMATCH:
        return "call-id-mismatch";
    case DJONEHUB_QMI_VOICE_CONFIRM_QUERY:
        return "confirmation-query";
    case DJONEHUB_QMI_VOICE_CONFIRM_TIMEOUT:
        return "state-confirmation";
    case DJONEHUB_QMI_VOICE_RELEASE:
        return "qmi-client-release";
    default:
        return "unknown";
    }
}
