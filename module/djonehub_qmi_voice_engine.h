#ifndef DJONEHUB_QMI_VOICE_ENGINE_H
#define DJONEHUB_QMI_VOICE_ENGINE_H

#include <stdint.h>

#include "djonehub_voice_codec.h"
#include "djonehub_voice_policy.h"

enum djonehub_qmi_voice_error {
    DJONEHUB_QMI_VOICE_SUCCESS = 0,
    DJONEHUB_QMI_VOICE_LIBRARY_LOAD = 1,
    DJONEHUB_QMI_VOICE_SERVICE_OBJECT = 2,
    DJONEHUB_QMI_VOICE_CLIENT_INIT = 3,
    DJONEHUB_QMI_VOICE_STATUS_QUERY = 4,
    DJONEHUB_QMI_VOICE_PRECONDITION = 5,
    DJONEHUB_QMI_VOICE_INVALID_INPUT = 6,
    DJONEHUB_QMI_VOICE_ACTION = 7,
    DJONEHUB_QMI_VOICE_CALL_ID_MISMATCH = 8,
    DJONEHUB_QMI_VOICE_CONFIRM_QUERY = 9,
    DJONEHUB_QMI_VOICE_CONFIRM_TIMEOUT = 10,
    DJONEHUB_QMI_VOICE_RELEASE = 11
};

struct djonehub_qmi_voice_result {
    struct djonehub_voice_snapshot snapshot;
    uint8_t action_call_id;
    uint8_t confirmed;
    int transport_error;
    unsigned int service_error;
};

/*
 * Executes one fixed QMI Voice operation.  number is used only for DIAL;
 * call_id is used only for ANSWER/END.  Mutating operations enforce policy
 * against a fresh snapshot and confirm the resulting state by read-back.
 */
enum djonehub_qmi_voice_error djonehub_qmi_voice_execute(
    enum djonehub_voice_operation operation, const char *number,
    uint8_t call_id, struct djonehub_qmi_voice_result *result);

/* Releases the persistent QMI client during orderly daemon shutdown. */
void djonehub_qmi_voice_shutdown(void);

const char *djonehub_qmi_voice_error_name(
    enum djonehub_qmi_voice_error error);

#endif
