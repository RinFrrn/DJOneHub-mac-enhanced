#include "djonehub_voice_codec.h"

#include <string.h>

#define QMI_RESULT_TLV 0x02U
#define QMI_CALL_INFORMATION_TLV 0x10U
#define QMI_CALL_ID_TLV 0x10U
#define QMI_MANDATORY_INPUT_TLV 0x01U
#define QMI_RESULT_SUCCESS 0U
#define QMI_CALL_RECORD_BYTES 7U
#define QMI_CALL_STATE_MAXIMUM 0x0AU

/*
 * Wire layouts follow libqmi's qmi-service-voice.json definitions for
 * Dial Call (0x20), End Call (0x21), Answer Call (0x22), and Get All Call
 * Info (0x2f).  Keep this translation unit independent from libqmi-glib so
 * it can be fuzzed and unit-tested on the build host.
 */

static uint16_t read_le16(const uint8_t *data)
{
    return (uint16_t)((uint16_t)data[0] | ((uint16_t)data[1] << 8U));
}

static void write_le16(uint8_t *data, uint16_t value)
{
    data[0] = (uint8_t)(value & 0xFFU);
    data[1] = (uint8_t)(value >> 8U);
}

/* Returns 0 when found, 1 when absent and -1 for malformed TLV data. */
static int find_tlv(const uint8_t *message, size_t message_length,
                    uint8_t wanted_type, const uint8_t **value,
                    size_t *value_length)
{
    size_t offset = 0U;

    if (message == NULL || value == NULL || value_length == NULL) {
        return -1;
    }
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

static int parse_result(const uint8_t *response, size_t response_length,
                        unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    int result;

    if (service_error == NULL) {
        return -1;
    }
    result = find_tlv(response, response_length, QMI_RESULT_TLV, &value,
                      &value_length);
    if (result != 0 || value_length != 4U) {
        return -1;
    }
    if (read_le16(value) != QMI_RESULT_SUCCESS) {
        *service_error = (unsigned int)read_le16(value + 2U);
        return 1;
    }
    *service_error = 0U;
    return 0;
}

int djonehub_voice_parse_snapshot(const uint8_t *response,
                                  size_t response_length,
                                  struct djonehub_voice_snapshot *snapshot,
                                  unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    size_t expected_length;
    size_t index;
    int result;

    if (snapshot == NULL || service_error == NULL) {
        return -1;
    }
    memset(snapshot, 0, sizeof(*snapshot));
    result = parse_result(response, response_length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, response_length, QMI_CALL_INFORMATION_TLV,
                      &value, &value_length);
    if (result == 1) {
        return 0;
    }
    if (result != 0 || value_length < 1U ||
        (size_t)value[0] > DJONEHUB_VOICE_MAX_CALLS) {
        return -1;
    }
    snapshot->count = (size_t)value[0];
    expected_length = 1U + snapshot->count * QMI_CALL_RECORD_BYTES;
    if (value_length != expected_length) {
        memset(snapshot, 0, sizeof(*snapshot));
        return -1;
    }
    for (index = 0U; index < snapshot->count; ++index) {
        const uint8_t *record = value + 1U + index * QMI_CALL_RECORD_BYTES;
        struct djonehub_voice_call *call = &snapshot->calls[index];
        size_t previous_index;

        call->id = record[0];
        call->state = record[1];
        call->type = record[2];
        call->direction = record[3];
        call->mode = record[4];
        call->multipart = record[5];
        call->als = record[6];
        if (call->id == 0U || call->state > QMI_CALL_STATE_MAXIMUM) {
            memset(snapshot, 0, sizeof(*snapshot));
            return -1;
        }
        for (previous_index = 0U; previous_index < index; ++previous_index) {
            if (snapshot->calls[previous_index].id == call->id) {
                memset(snapshot, 0, sizeof(*snapshot));
                return -1;
            }
        }
    }
    return 0;
}

int djonehub_voice_parse_action_response(const uint8_t *response,
                                         size_t response_length,
                                         uint8_t *call_id,
                                         int *call_id_present,
                                         unsigned int *service_error)
{
    const uint8_t *value = NULL;
    size_t value_length = 0U;
    int result;

    if (call_id == NULL || call_id_present == NULL || service_error == NULL) {
        return -1;
    }
    *call_id = 0U;
    *call_id_present = 0;
    result = parse_result(response, response_length, service_error);
    if (result != 0) {
        return result;
    }
    result = find_tlv(response, response_length, QMI_CALL_ID_TLV, &value,
                      &value_length);
    if (result == 1) {
        return 0;
    }
    if (result != 0 || value_length != 1U || value[0] == 0U) {
        return -1;
    }
    *call_id = value[0];
    *call_id_present = 1;
    return 0;
}

static int valid_dial_character(char character, size_t index)
{
    if (character >= '0' && character <= '9') {
        return 1;
    }
    if (character == '*' || character == '#') {
        return 1;
    }
    return character == '+' && index == 0U;
}

int djonehub_voice_build_dial_request(const char *number, uint8_t *request,
                                      size_t request_capacity,
                                      size_t *request_length)
{
    size_t length;
    size_t index;
    int has_digit = 0;

    if (number == NULL || request == NULL || request_length == NULL) {
        return -1;
    }
    *request_length = 0U;
    length = strlen(number);
    if (length == 0U || length > DJONEHUB_VOICE_MAX_NUMBER_BYTES ||
        request_capacity < 3U + length) {
        return -1;
    }
    for (index = 0U; index < length; ++index) {
        if (!valid_dial_character(number[index], index)) {
            return -1;
        }
        if (number[index] >= '0' && number[index] <= '9') {
            has_digit = 1;
        }
    }
    if (!has_digit) {
        return -1;
    }
    request[0] = QMI_MANDATORY_INPUT_TLV;
    write_le16(request + 1U, (uint16_t)length);
    memcpy(request + 3U, number, length);
    *request_length = 3U + length;
    return 0;
}

int djonehub_voice_build_call_id_request(uint8_t call_id, uint8_t *request,
                                         size_t request_capacity,
                                         size_t *request_length)
{
    if (request_length == NULL) {
        return -1;
    }
    *request_length = 0U;
    if (call_id == 0U || request == NULL || request_capacity < 4U) {
        return -1;
    }
    request[0] = QMI_MANDATORY_INPUT_TLV;
    write_le16(request + 1U, 1U);
    request[3] = call_id;
    *request_length = 4U;
    return 0;
}

const char *djonehub_voice_call_state_name(uint8_t state)
{
    switch (state) {
    case 0x00U:
        return "unknown";
    case 0x01U:
        return "origination";
    case 0x02U:
        return "incoming";
    case 0x03U:
        return "conversation";
    case 0x04U:
        return "cc-in-progress";
    case 0x05U:
        return "alerting";
    case 0x06U:
        return "hold";
    case 0x07U:
        return "waiting";
    case 0x08U:
        return "disconnecting";
    case 0x09U:
        return "end";
    case 0x0AU:
        return "setup";
    default:
        return "invalid";
    }
}
