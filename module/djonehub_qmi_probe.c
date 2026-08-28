#define _POSIX_C_SOURCE 200809L

/*
 * Read-only QMI Voice compatibility probe for the QDC507 module.
 *
 * The module firmware already ships the matching Qualcomm QCCI and generated
 * service-object libraries.  Loading those libraries at runtime avoids
 * copying a private QMI IDL ABI into this repository.  This probe performs
 * only QMI_VOICE_GET_ALL_CALL_INFO (0x002F); it cannot originate, answer, or
 * end a call and it never writes module configuration.
 */

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VOICE_IDL_MAJOR 0x02U
#define VOICE_IDL_MINOR 0x4DU
#define VOICE_IDL_TOOL 0x06U
#define QMI_CLIENT_INSTANCE_ANY 0xFFFFU
#define QMI_NO_ERR 0
#define QMI_VOICE_GET_ALL_CALL_INFO 0x002FU
#define QMI_TIMEOUT_MS 5000U
#define RESPONSE_CAPACITY 16384U

typedef void *qmi_client_type;
typedef void *qmi_idl_service_object_type;

/*
 * Linux QCCI ABI from qmi_cci_target_ext.h.  The module's own
 * quectel_daemon passes this object to qmi_client_init(); a NULL pointer is
 * not accepted by the vendor library and is dereferenced during setup.
 */
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
    qmi_idl_service_object_type service_object,
    unsigned int instance_id,
    void *indication_callback,
    void *indication_data,
    void *os_params,
    uint32_t timeout_ms,
    qmi_client_type *client);
typedef int (*qmi_client_send_raw_msg_sync_fn)(
    qmi_client_type client,
    unsigned int message_id,
    void *request,
    unsigned int request_length,
    void *response,
    unsigned int response_capacity,
    unsigned int *response_length,
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

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)((uint16_t)data[0] | ((uint16_t)data[1] << 8U));
}

static int load_symbol(void *library, const char *name, void *target,
                       size_t target_size)
{
    void *symbol;
    const char *error_text;

    (void)dlerror();
    symbol = dlsym(library, name);
    error_text = dlerror();
    if (error_text != NULL || symbol == NULL) {
        fprintf(stderr, "djonehub-qmi-probe: dlsym %s: %s\n", name,
                error_text != NULL ? error_text : "symbol not found");
        return -1;
    }
    if (target_size != sizeof(symbol)) {
        fprintf(stderr, "djonehub-qmi-probe: incompatible function pointer size\n");
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
        fprintf(stderr, "djonehub-qmi-probe: dlopen libqmiservices: %s\n",
                dlerror());
        return -1;
    }
    api->client_library = dlopen("libqmi_cci.so.1", RTLD_NOW | RTLD_LOCAL);
    if (api->client_library == NULL) {
        fprintf(stderr, "djonehub-qmi-probe: dlopen libqmi_cci: %s\n",
                dlerror());
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

/* Returns 0 when found, 1 when absent, and -1 for malformed TLV data. */
static int find_tlv(const uint8_t *message, size_t message_length,
                    uint8_t wanted_type, const uint8_t **value,
                    size_t *value_length)
{
    size_t offset = 0U;

    while (offset < message_length) {
        size_t length;
        uint8_t type;

        if (message_length - offset < 3U) {
            return -1;
        }
        type = message[offset];
        length = (size_t)read_le16(message + offset + 1U);
        offset += 3U;
        if (length > message_length - offset) {
            return -1;
        }
        if (type == wanted_type) {
            *value = message + offset;
            *value_length = length;
            return 0;
        }
        offset += length;
    }
    return 1;
}

static int inspect_get_all_calls_response(const uint8_t *response,
                                          size_t response_length,
                                          unsigned int *call_count,
                                          unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    int result;

    result = find_tlv(response, response_length, 0x02U, &value,
                      &value_length);
    if (result != 0 || value_length < 4U) {
        return -1;
    }
    if (read_le16(value) != 0U) {
        *service_error = (unsigned int)read_le16(value + 2U);
        return 1;
    }

    result = find_tlv(response, response_length, 0x01U, &value,
                      &value_length);
    if (result == 0) {
        if (value_length < 1U) {
            return -1;
        }
        *call_count = (unsigned int)value[0];
    } else if (result < 0) {
        return -1;
    } else {
        *call_count = 0U;
    }
    *service_error = 0U;
    return 0;
}

int main(void)
{
    struct qmi_api api;
    qmi_idl_service_object_type service_object;
    qmi_client_type client = NULL;
    struct qmi_client_os_params os_params;
    uint8_t response[RESPONSE_CAPACITY];
    uint8_t empty_request = 0U;
    unsigned int response_length = 0U;
    unsigned int call_count = 0U;
    unsigned int service_error = 0U;
    int inspect_result;
    int qmi_result;
    int exit_status = EXIT_FAILURE;

    fprintf(stderr, "djonehub-qmi-probe: phase=load-libraries\n");
    if (load_qmi_api(&api) != 0) {
        return EXIT_FAILURE;
    }
    fprintf(stderr, "djonehub-qmi-probe: phase=get-service-object\n");
    service_object = api.get_voice_service_object(
        (int32_t)VOICE_IDL_MAJOR, (int32_t)VOICE_IDL_MINOR,
        (int32_t)VOICE_IDL_TOOL);
    if (service_object == NULL) {
        fprintf(stderr,
                "djonehub-qmi-probe: Voice service object 2/0x4D/6 rejected\n");
        goto cleanup;
    }

    memset(&os_params, 0, sizeof(os_params));
    fprintf(stderr, "djonehub-qmi-probe: phase=init-client os_params=%u\n",
            (unsigned int)sizeof(os_params));
    qmi_result = api.client_init_instance(
        service_object, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, &os_params,
        QMI_TIMEOUT_MS, &client);
    if (qmi_result != QMI_NO_ERR || client == NULL) {
        fprintf(stderr, "djonehub-qmi-probe: QMI Voice init failed: %d\n",
                qmi_result);
        goto cleanup;
    }

    fprintf(stderr, "djonehub-qmi-probe: phase=get-all-call-info\n");
    memset(response, 0, sizeof(response));
    qmi_result = api.send_raw_sync(
        client, QMI_VOICE_GET_ALL_CALL_INFO, &empty_request, 0U, response,
        (unsigned int)sizeof(response), &response_length, QMI_TIMEOUT_MS);
    if (qmi_result != QMI_NO_ERR) {
        fprintf(stderr,
                "djonehub-qmi-probe: get-all-call-info transport failed: %d\n",
                qmi_result);
        goto cleanup;
    }
    if (response_length > (unsigned int)sizeof(response)) {
        fprintf(stderr, "djonehub-qmi-probe: invalid response length: %u\n",
                response_length);
        goto cleanup;
    }

    inspect_result = inspect_get_all_calls_response(
        response, (size_t)response_length, &call_count, &service_error);
    if (inspect_result < 0) {
        fprintf(stderr, "djonehub-qmi-probe: malformed QMI Voice response\n");
        goto cleanup;
    }
    if (inspect_result > 0) {
        fprintf(stderr,
                "djonehub-qmi-probe: QMI Voice service error: %u\n",
                service_error);
        goto cleanup;
    }

    printf("{\"ok\":true,\"probe\":\"qmi-voice-read-only\","
           "\"idl\":\"2.0x4D.6\",\"call_count\":%u}\n",
           call_count);
    exit_status = EXIT_SUCCESS;

cleanup:
    fprintf(stderr, "djonehub-qmi-probe: phase=cleanup\n");
    if (client != NULL) {
        qmi_result = api.client_release(client);
        if (qmi_result != QMI_NO_ERR) {
            fprintf(stderr,
                    "djonehub-qmi-probe: QMI client release failed: %d\n",
                    qmi_result);
            exit_status = EXIT_FAILURE;
        }
    }
    unload_qmi_api(&api);
    return exit_status;
}
