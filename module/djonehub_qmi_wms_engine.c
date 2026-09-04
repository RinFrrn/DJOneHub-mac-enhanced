#define _POSIX_C_SOURCE 200809L

#include "djonehub_qmi_wms_engine.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

#define WMS_IDL_MAJOR 1U
#define QMI_CLIENT_INSTANCE_ANY 0xFFFFU
#define QMI_NO_ERR 0
#define QMI_WMS_RAW_SEND 0x0020U
#define QMI_WMS_RAW_READ 0x0022U
#define QMI_WMS_DELETE 0x0024U
#define QMI_WMS_LIST_MESSAGES 0x0031U
#define QMI_TIMEOUT_MS 5000U
#define RESPONSE_CAPACITY 4096U

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

typedef qmi_idl_service_object_type (*wms_get_service_object_fn)(
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
typedef int (*qmi_client_message_encode_fn)(
    qmi_client_type client, int message_type, unsigned int message_id,
    const void *source, unsigned int source_length, void *destination,
    unsigned int destination_length, unsigned int *encoded_length);
typedef int (*qmi_client_release_fn)(qmi_client_type client);

struct wms_list_messages_req_v01 {
    int32_t storage_type;
    uint8_t message_tag_valid;
    int32_t message_tag;
    uint8_t message_mode_valid;
    int32_t message_mode;
};

_Static_assert(sizeof(struct wms_list_messages_req_v01) == 20U,
               "unexpected ARM QMI WMS list request layout");

struct qmi_api {
    void *services_library;
    void *client_library;
    wms_get_service_object_fn get_service_object;
    qmi_client_init_instance_fn client_init_instance;
    qmi_client_send_raw_msg_sync_fn send_raw_sync;
    qmi_client_message_encode_fn message_encode;
    qmi_client_release_fn client_release;
};

struct qmi_wms_context {
    pthread_mutex_t mutex;
    struct qmi_api api;
    qmi_idl_service_object_type service_object;
    qmi_client_type client;
    struct qmi_client_os_params os_params;
    uint8_t idl_minor;
    uint8_t idl_tool;
    int api_loaded;
};

static struct qmi_wms_context qmi_context = {
    .mutex = PTHREAD_MUTEX_INITIALIZER
};

static int load_symbol(void *library, const char *name, void *target,
                       size_t target_size)
{
    void *symbol;
    const char *error_text;

    (void)dlerror();
    symbol = dlsym(library, name);
    error_text = dlerror();
    if (error_text != NULL || symbol == NULL || target_size != sizeof(symbol)) {
        return -1;
    }
    memcpy(target, &symbol, sizeof(symbol));
    return 0;
}

static void unload_api(struct qmi_api *api)
{
    if (api->client_library != NULL) {
        (void)dlclose(api->client_library);
    }
    if (api->services_library != NULL) {
        (void)dlclose(api->services_library);
    }
    memset(api, 0, sizeof(*api));
}

static int load_api(struct qmi_api *api)
{
    memset(api, 0, sizeof(*api));
    api->services_library = dlopen("libqmiservices.so.1", RTLD_NOW | RTLD_LOCAL);
    api->client_library = dlopen("libqmi_cci.so.1", RTLD_NOW | RTLD_LOCAL);
    if (api->services_library == NULL || api->client_library == NULL ||
        load_symbol(api->services_library,
                    "wms_get_service_object_internal_v01",
                    &api->get_service_object,
                    sizeof(api->get_service_object)) != 0 ||
        load_symbol(api->client_library, "qmi_client_init_instance",
                    &api->client_init_instance,
                    sizeof(api->client_init_instance)) != 0 ||
        load_symbol(api->client_library, "qmi_client_send_raw_msg_sync",
                    &api->send_raw_sync, sizeof(api->send_raw_sync)) != 0 ||
        load_symbol(api->client_library, "qmi_client_message_encode",
                    &api->message_encode, sizeof(api->message_encode)) != 0 ||
        load_symbol(api->client_library, "qmi_client_release",
                    &api->client_release, sizeof(api->client_release)) != 0) {
        unload_api(api);
        return -1;
    }
    return 0;
}

static int discover_service_object(struct qmi_wms_context *context)
{
    static const uint8_t preferred_tools[] = {6U, 5U, 7U, 4U, 8U, 3U, 2U, 1U};
    size_t tool_index;

    for (tool_index = 0U;
         tool_index < sizeof(preferred_tools) / sizeof(preferred_tools[0]);
         ++tool_index) {
        unsigned int minor;

        for (minor = 0U; minor <= UINT8_MAX; ++minor) {
            qmi_idl_service_object_type object =
                context->api.get_service_object(
                    (int32_t)WMS_IDL_MAJOR, (int32_t)minor,
                    (int32_t)preferred_tools[tool_index]);

            if (object != NULL) {
                context->service_object = object;
                context->idl_minor = (uint8_t)minor;
                context->idl_tool = preferred_tools[tool_index];
                return 0;
            }
        }
    }
    return -1;
}

static enum djonehub_qmi_wms_error ensure_client_locked(int *transport_error)
{
    int init_result;

    *transport_error = 0;
    if (!qmi_context.api_loaded) {
        if (load_api(&qmi_context.api) != 0) {
            *transport_error = -1;
            return DJONEHUB_QMI_WMS_LIBRARY_LOAD;
        }
        qmi_context.api_loaded = 1;
    }
    if (qmi_context.service_object == NULL &&
        discover_service_object(&qmi_context) != 0) {
        return DJONEHUB_QMI_WMS_SERVICE_OBJECT;
    }
    if (qmi_context.client != NULL) {
        return DJONEHUB_QMI_WMS_SUCCESS;
    }
    memset(&qmi_context.os_params, 0, sizeof(qmi_context.os_params));
    init_result = qmi_context.api.client_init_instance(
        qmi_context.service_object, QMI_CLIENT_INSTANCE_ANY, NULL, NULL,
        &qmi_context.os_params, QMI_TIMEOUT_MS, &qmi_context.client);
    *transport_error = init_result;
    if (init_result != QMI_NO_ERR || qmi_context.client == NULL) {
        qmi_context.client = NULL;
        return DJONEHUB_QMI_WMS_CLIENT_INIT;
    }
    return DJONEHUB_QMI_WMS_SUCCESS;
}

static enum djonehub_qmi_wms_error parse_error(int parse_result)
{
    if (parse_result == 1) {
        return DJONEHUB_QMI_WMS_SERVICE;
    }
    if (parse_result == -2) {
        return DJONEHUB_QMI_WMS_LIMIT_EXCEEDED;
    }
    return DJONEHUB_QMI_WMS_MALFORMED_RESPONSE;
}

static enum djonehub_qmi_wms_error send_locked(
    unsigned int message_id, const uint8_t *request, size_t request_length,
    uint8_t response[RESPONSE_CAPACITY], size_t *response_length,
    struct djonehub_qmi_wms_result *result)
{
    unsigned int received = 0U;
    uint8_t empty = 0U;
    int transport;

    if (request_length > UINT_MAX) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    transport = qmi_context.api.send_raw_sync(
        qmi_context.client, message_id,
        request_length == 0U ? &empty : (void *)(uintptr_t)request,
        (unsigned int)request_length, response, RESPONSE_CAPACITY, &received,
        QMI_TIMEOUT_MS);
    result->transport_error = transport;
    if (transport != QMI_NO_ERR || received > RESPONSE_CAPACITY) {
        return DJONEHUB_QMI_WMS_TRANSPORT;
    }
    *response_length = received;
    return DJONEHUB_QMI_WMS_SUCCESS;
}

static int append_unique(struct djonehub_qmi_wms_result *result,
                         const struct djonehub_wms_message_ref *message)
{
    size_t index;

    for (index = 0U; index < result->message_count; ++index) {
        if (result->messages[index].index == message->index) {
            result->messages[index].tag = message->tag;
            return 0;
        }
    }
    if (result->message_count >= DJONEHUB_WMS_MAX_MESSAGES) {
        return -1;
    }
    result->messages[result->message_count++] = *message;
    return 0;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_get_status(
    struct djonehub_qmi_wms_result *result)
{
    enum djonehub_qmi_wms_error error;

    if (result == NULL) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    result->status.protocol = 0xffU;
    result->status.registration = 0xffU;
    (void)pthread_mutex_lock(&qmi_context.mutex);
    error = ensure_client_locked(&result->transport_error);
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        result->status.idl_major = WMS_IDL_MAJOR;
        result->status.idl_minor = qmi_context.idl_minor;
        result->status.idl_tool = qmi_context.idl_tool;
    }
    (void)pthread_mutex_unlock(&qmi_context.mutex);
    return error;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_list(
    uint8_t storage, struct djonehub_qmi_wms_result *result)
{
    uint8_t request[16];
    uint8_t response[RESPONSE_CAPACITY];
    struct djonehub_wms_message_ref parsed_messages[DJONEHUB_WMS_MAX_MESSAGES];
    enum djonehub_qmi_wms_error error;
    size_t response_length = 0U;
    uint8_t tag;
    int list_succeeded = 0;

    if (result == NULL || storage > 1U) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    (void)pthread_mutex_lock(&qmi_context.mutex);
    error = ensure_client_locked(&result->transport_error);
    /* Message tag is optional in WMS List Messages.  Start with the smallest
     * request accepted across old modem IDL revisions: storage only, with a
     * message-mode retry.  Filtering locally also avoids depending on tag TLV
     * numbers that moved between older WMS schemas. */
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        int include_mode;

        for (include_mode = 0; include_mode <= 1 && !list_succeeded;
             ++include_mode) {
            struct wms_list_messages_req_v01 request_struct;
            unsigned int encoded_length = 0U;
            size_t request_length;
            size_t parsed_count = 0U;
            int parsed;
            size_t index;

            memset(&request_struct, 0, sizeof(request_struct));
            request_struct.storage_type = storage;
            request_struct.message_mode_valid = (uint8_t)include_mode;
            request_struct.message_mode = 1;
            parsed = qmi_context.api.message_encode(
                qmi_context.client, 0, QMI_WMS_LIST_MESSAGES,
                &request_struct, (unsigned int)sizeof(request_struct),
                request, (unsigned int)sizeof(request), &encoded_length);
            memset(&request_struct, 0, sizeof(request_struct));
            if (parsed != QMI_NO_ERR || encoded_length > sizeof(request)) {
                result->transport_error = parsed;
                error = DJONEHUB_QMI_WMS_MALFORMED_RESPONSE;
                break;
            }
            request_length = encoded_length;
            error = send_locked(QMI_WMS_LIST_MESSAGES, request,
                                request_length, response, &response_length,
                                result);
            if (error != DJONEHUB_QMI_WMS_SUCCESS) {
                break;
            }
            parsed = djonehub_wms_parse_list_response(
                response, response_length, parsed_messages,
                DJONEHUB_WMS_MAX_MESSAGES, &parsed_count,
                &result->service_error);
            if (parsed == 1) {
                continue;
            }
            if (parsed != 0) {
                error = parse_error(parsed);
                break;
            }
            for (index = 0U; index < parsed_count; ++index) {
                if (append_unique(result, &parsed_messages[index]) != 0) {
                    error = DJONEHUB_QMI_WMS_LIMIT_EXCEEDED;
                    break;
                }
            }
            list_succeeded = error == DJONEHUB_QMI_WMS_SUCCESS;
        }
    }
    for (tag = 0U;
         !list_succeeded && error == DJONEHUB_QMI_WMS_SUCCESS && tag <= 3U;
         ++tag) {
        static const uint8_t types[] = {0x11U, 0x02U};
        size_t type_index;
        int succeeded = 0;

        for (type_index = 0U; type_index < 2U && !succeeded; ++type_index) {
            int include_mode;

            for (include_mode = 0; include_mode <= 1; ++include_mode) {
                size_t request_length = djonehub_wms_build_list_request(
                    storage, tag, types[type_index], include_mode, request,
                    sizeof(request));
                size_t parsed_count = 0U;
                int parsed;
                size_t index;

                error = send_locked(QMI_WMS_LIST_MESSAGES, request,
                                    request_length, response, &response_length,
                                    result);
                if (error != DJONEHUB_QMI_WMS_SUCCESS) {
                    break;
                }
                parsed = djonehub_wms_parse_list_response(
                    response, response_length, parsed_messages,
                    DJONEHUB_WMS_MAX_MESSAGES, &parsed_count,
                    &result->service_error);
                if (parsed == 1) {
                    continue;
                }
                if (parsed != 0) {
                    error = parse_error(parsed);
                    break;
                }
                for (index = 0U; index < parsed_count; ++index) {
                    if (append_unique(result, &parsed_messages[index]) != 0) {
                        error = DJONEHUB_QMI_WMS_LIMIT_EXCEEDED;
                        break;
                    }
                }
                succeeded = error == DJONEHUB_QMI_WMS_SUCCESS;
                break;
            }
        }
        if (!succeeded && error == DJONEHUB_QMI_WMS_SUCCESS) {
            error = DJONEHUB_QMI_WMS_SERVICE;
        }
    }
    if (!list_succeeded && error == DJONEHUB_QMI_WMS_SUCCESS && tag > 3U) {
        list_succeeded = 1;
    }
    if (!list_succeeded && error == DJONEHUB_QMI_WMS_SUCCESS) {
        error = DJONEHUB_QMI_WMS_SERVICE;
    }
    (void)pthread_mutex_unlock(&qmi_context.mutex);
    memset(request, 0, sizeof(request));
    memset(response, 0, sizeof(response));
    memset(parsed_messages, 0, sizeof(parsed_messages));
    return error;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_read(
    uint8_t storage, uint32_t index, struct djonehub_qmi_wms_result *result)
{
    uint8_t request[16];
    uint8_t response[RESPONSE_CAPACITY];
    size_t request_length;
    size_t response_length = 0U;
    enum djonehub_qmi_wms_error error;
    int parsed;

    if (result == NULL || storage > 1U) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    request_length = djonehub_wms_build_read_request(
        storage, index, request, sizeof(request));
    (void)pthread_mutex_lock(&qmi_context.mutex);
    error = ensure_client_locked(&result->transport_error);
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        error = send_locked(QMI_WMS_RAW_READ, request, request_length, response,
                            &response_length, result);
    }
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        parsed = djonehub_wms_parse_read_response(
            response, response_length, &result->message,
            &result->service_error);
        if (parsed != 0) {
            error = parse_error(parsed);
        }
    }
    (void)pthread_mutex_unlock(&qmi_context.mutex);
    memset(request, 0, sizeof(request));
    memset(response, 0, sizeof(response));
    return error;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_send_raw(
    uint8_t format, const uint8_t *pdu, size_t pdu_length,
    struct djonehub_qmi_wms_result *result)
{
    uint8_t request[3U + 3U + DJONEHUB_WMS_MAX_PDU_BYTES];
    uint8_t response[RESPONSE_CAPACITY];
    size_t request_length;
    size_t response_length = 0U;
    enum djonehub_qmi_wms_error error;
    int parsed;

    if (result == NULL) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    request_length = djonehub_wms_build_send_request(
        format, pdu, pdu_length, request, sizeof(request));
    if (request_length == 0U) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    (void)pthread_mutex_lock(&qmi_context.mutex);
    error = ensure_client_locked(&result->transport_error);
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        error = send_locked(QMI_WMS_RAW_SEND, request, request_length, response,
                            &response_length, result);
    }
    if (error == DJONEHUB_QMI_WMS_SUCCESS) {
        parsed = djonehub_wms_parse_send_response(
            response, response_length, &result->sent_message_id,
            &result->service_error);
        if (parsed != 0) {
            error = parse_error(parsed);
        }
    }
    (void)pthread_mutex_unlock(&qmi_context.mutex);
    memset(request, 0, sizeof(request));
    memset(response, 0, sizeof(response));
    return error;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_delete(
    uint8_t storage, uint32_t index, struct djonehub_qmi_wms_result *result)
{
    uint8_t request[16];
    uint8_t response[RESPONSE_CAPACITY];
    size_t response_length = 0U;
    enum djonehub_qmi_wms_error error;
    int layout;

    if (result == NULL || storage > 1U) {
        return DJONEHUB_QMI_WMS_INVALID_INPUT;
    }
    memset(result, 0, sizeof(*result));
    (void)pthread_mutex_lock(&qmi_context.mutex);
    error = ensure_client_locked(&result->transport_error);
    for (layout = 0; layout <= 1 && error == DJONEHUB_QMI_WMS_SUCCESS;
         ++layout) {
        size_t request_length = djonehub_wms_build_delete_request(
            storage, index, layout, request, sizeof(request));
        int parsed;

        error = send_locked(QMI_WMS_DELETE, request, request_length, response,
                            &response_length, result);
        if (error != DJONEHUB_QMI_WMS_SUCCESS) {
            break;
        }
        parsed = djonehub_wms_parse_result(response, response_length,
                                           &result->service_error);
        if (parsed == 0) {
            break;
        }
        if (parsed < 0) {
            error = parse_error(parsed);
            break;
        }
        if (layout == 1) {
            error = DJONEHUB_QMI_WMS_SERVICE;
        }
    }
    (void)pthread_mutex_unlock(&qmi_context.mutex);
    memset(request, 0, sizeof(request));
    memset(response, 0, sizeof(response));
    return error;
}

void djonehub_qmi_wms_shutdown(void)
{
    (void)pthread_mutex_lock(&qmi_context.mutex);
    if (qmi_context.client != NULL) {
        (void)qmi_context.api.client_release(qmi_context.client);
        qmi_context.client = NULL;
    }
    unload_api(&qmi_context.api);
    qmi_context.service_object = NULL;
    qmi_context.api_loaded = 0;
    (void)pthread_mutex_unlock(&qmi_context.mutex);
}

const char *djonehub_qmi_wms_error_name(enum djonehub_qmi_wms_error error)
{
    switch (error) {
    case DJONEHUB_QMI_WMS_SUCCESS:
        return "success";
    case DJONEHUB_QMI_WMS_LIBRARY_LOAD:
        return "library-load";
    case DJONEHUB_QMI_WMS_SERVICE_OBJECT:
        return "service-object";
    case DJONEHUB_QMI_WMS_CLIENT_INIT:
        return "client-init";
    case DJONEHUB_QMI_WMS_TRANSPORT:
        return "transport";
    case DJONEHUB_QMI_WMS_SERVICE:
        return "service";
    case DJONEHUB_QMI_WMS_MALFORMED_RESPONSE:
        return "malformed-response";
    case DJONEHUB_QMI_WMS_LIMIT_EXCEEDED:
        return "limit-exceeded";
    case DJONEHUB_QMI_WMS_INVALID_INPUT:
        return "invalid-input";
    default:
        return "unknown";
    }
}
