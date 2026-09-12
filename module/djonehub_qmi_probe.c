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
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "djonehub_voice_codec.h"

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

/*
 * Do not use stderr for diagnostics on this old userspace.  A Zig-linked
 * probe must pass through the module's loader, and its first stdio access may
 * fault while resolving the stderr data symbol.  A direct ARM EABI
 * write syscall gives us a phase marker without any libc data relocation.
 */
static void probe_write(const char *data, size_t length)
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
#error "djonehub_qmi_probe requires the ARM EABI write syscall"
#endif
}

static void probe_log(const char *text)
{
    size_t length = 0U;

    while (text[length] != '\0') {
        ++length;
    }
    probe_write(text, length);
}

static void probe_logf(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

static void probe_logf(const char *format, ...)
{
    char buffer[512];
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
    probe_write(buffer, output_length);
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
        probe_logf("djonehub-qmi-probe: dlsym %s: %s\n", name,
                   error_text != NULL ? error_text : "symbol not found");
        return -1;
    }
    if (target_size != sizeof(symbol)) {
        probe_log("djonehub-qmi-probe: incompatible function pointer size\n");
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
        probe_logf("djonehub-qmi-probe: dlopen libqmiservices: %s\n",
                   dlerror());
        return -1;
    }
    api->client_library = dlopen("libqmi_cci.so.1", RTLD_NOW | RTLD_LOCAL);
    if (api->client_library == NULL) {
        probe_logf("djonehub-qmi-probe: dlopen libqmi_cci: %s\n",
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

int main(void)
{
    struct qmi_api api;
    qmi_idl_service_object_type service_object;
    qmi_client_type client = NULL;
    struct qmi_client_os_params os_params;
    uint8_t response[RESPONSE_CAPACITY];
    uint8_t empty_request = 0U;
    unsigned int response_length = 0U;
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 0U;
    size_t call_index;
    int inspect_result;
    int qmi_result;
    int exit_status = EXIT_FAILURE;

    probe_log("djonehub-qmi-probe: phase=entered-main\n");
    probe_log("djonehub-qmi-probe: phase=load-libraries\n");
    if (load_qmi_api(&api) != 0) {
        return EXIT_FAILURE;
    }
    probe_log("djonehub-qmi-probe: phase=get-service-object\n");
    service_object = api.get_voice_service_object(
        (int32_t)VOICE_IDL_MAJOR, (int32_t)VOICE_IDL_MINOR,
        (int32_t)VOICE_IDL_TOOL);
    if (service_object == NULL) {
        probe_log(
            "djonehub-qmi-probe: Voice service object 2/0x4D/6 rejected\n");
        goto cleanup;
    }

    memset(&os_params, 0, sizeof(os_params));
    probe_logf("djonehub-qmi-probe: phase=init-client os_params=%u\n",
               (unsigned int)sizeof(os_params));
    qmi_result = api.client_init_instance(
        service_object, QMI_CLIENT_INSTANCE_ANY, NULL, NULL, &os_params,
        QMI_TIMEOUT_MS, &client);
    if (qmi_result != QMI_NO_ERR || client == NULL) {
        probe_logf("djonehub-qmi-probe: QMI Voice init failed: %d\n",
                   qmi_result);
        goto cleanup;
    }

    probe_log("djonehub-qmi-probe: phase=get-all-call-info\n");
    memset(response, 0, sizeof(response));
    qmi_result = api.send_raw_sync(
        client, QMI_VOICE_GET_ALL_CALL_INFO, &empty_request, 0U, response,
        (unsigned int)sizeof(response), &response_length, QMI_TIMEOUT_MS);
    if (qmi_result != QMI_NO_ERR) {
        probe_logf(
            "djonehub-qmi-probe: get-all-call-info transport failed: %d\n",
            qmi_result);
        goto cleanup;
    }
    if (response_length > (unsigned int)sizeof(response)) {
        probe_logf("djonehub-qmi-probe: invalid response length: %u\n",
                   response_length);
        goto cleanup;
    }

    inspect_result = djonehub_voice_parse_snapshot(
        response, (size_t)response_length, &snapshot, &service_error);
    if (inspect_result < 0) {
        probe_log("djonehub-qmi-probe: malformed QMI Voice response\n");
        goto cleanup;
    }
    if (inspect_result > 0) {
        probe_logf("djonehub-qmi-probe: QMI Voice service error: %u\n",
                   service_error);
        goto cleanup;
    }

    probe_logf("{\"ok\":true,\"probe\":\"qmi-voice-read-only\","
               "\"idl\":\"2.0x4D.6\",\"call_count\":%u,\"calls\":[",
               (unsigned int)snapshot.count);
    for (call_index = 0U; call_index < snapshot.count; ++call_index) {
        const struct djonehub_voice_call *call = &snapshot.calls[call_index];

        probe_logf("%s{\"id\":%u,\"state\":%u,\"state_name\":\"%s\","
                   "\"type\":%u,\"direction\":%u,\"mode\":%u}",
                   call_index == 0U ? "" : ",", (unsigned int)call->id,
                   (unsigned int)call->state,
                   djonehub_voice_call_state_name(call->state),
                   (unsigned int)call->type,
                   (unsigned int)call->direction,
                   (unsigned int)call->mode);
    }
    probe_log("]}\n");
    exit_status = EXIT_SUCCESS;

cleanup:
    probe_log("djonehub-qmi-probe: phase=cleanup\n");
    if (client != NULL) {
        qmi_result = api.client_release(client);
        if (qmi_result != QMI_NO_ERR) {
            probe_logf(
                "djonehub-qmi-probe: QMI client release failed: %d\n",
                qmi_result);
            exit_status = EXIT_FAILURE;
        }
    }
    unload_qmi_api(&api);
    return exit_status;
}
