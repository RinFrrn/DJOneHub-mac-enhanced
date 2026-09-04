#ifndef DJONEHUB_QMI_WMS_ENGINE_H
#define DJONEHUB_QMI_WMS_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#include "djonehub_wms_codec.h"

enum djonehub_qmi_wms_error {
    DJONEHUB_QMI_WMS_SUCCESS = 0,
    DJONEHUB_QMI_WMS_LIBRARY_LOAD = 1,
    DJONEHUB_QMI_WMS_SERVICE_OBJECT = 2,
    DJONEHUB_QMI_WMS_CLIENT_INIT = 3,
    DJONEHUB_QMI_WMS_TRANSPORT = 4,
    DJONEHUB_QMI_WMS_SERVICE = 5,
    DJONEHUB_QMI_WMS_MALFORMED_RESPONSE = 6,
    DJONEHUB_QMI_WMS_LIMIT_EXCEEDED = 7,
    DJONEHUB_QMI_WMS_INVALID_INPUT = 8
};

struct djonehub_qmi_wms_status {
    uint8_t protocol;
    uint8_t registration;
    uint8_t registration_available;
    uint8_t idl_major;
    uint8_t idl_minor;
    uint8_t idl_tool;
};

struct djonehub_qmi_wms_result {
    int transport_error;
    unsigned int service_error;
    struct djonehub_qmi_wms_status status;
    struct djonehub_wms_message_ref messages[DJONEHUB_WMS_MAX_MESSAGES];
    size_t message_count;
    struct djonehub_wms_raw_message message;
    uint16_t sent_message_id;
};

enum djonehub_qmi_wms_error djonehub_qmi_wms_get_status(
    struct djonehub_qmi_wms_result *result);
enum djonehub_qmi_wms_error djonehub_qmi_wms_list(
    uint8_t storage, struct djonehub_qmi_wms_result *result);
enum djonehub_qmi_wms_error djonehub_qmi_wms_read(
    uint8_t storage, uint32_t index, struct djonehub_qmi_wms_result *result);
enum djonehub_qmi_wms_error djonehub_qmi_wms_send_raw(
    uint8_t format, const uint8_t *pdu, size_t pdu_length,
    struct djonehub_qmi_wms_result *result);
enum djonehub_qmi_wms_error djonehub_qmi_wms_delete(
    uint8_t storage, uint32_t index, struct djonehub_qmi_wms_result *result);

void djonehub_qmi_wms_shutdown(void);
const char *djonehub_qmi_wms_error_name(enum djonehub_qmi_wms_error error);

#endif
