#include "djonehub_control_protocol.h"

#include <string.h>

#define CONTROL_MAGIC 0x444A4F48U
#define FRAME_HELLO 1U
#define FRAME_REQUEST 2U
#define FRAME_RESPONSE 3U

static void store_be16(uint8_t *output, uint16_t value)
{
    output[0] = (uint8_t)(value >> 8U);
    output[1] = (uint8_t)value;
}

static uint16_t load_be16(const uint8_t *input)
{
    return (uint16_t)(((uint16_t)input[0] << 8U) | (uint16_t)input[1]);
}

static void store_be32(uint8_t *output, uint32_t value)
{
    output[0] = (uint8_t)(value >> 24U);
    output[1] = (uint8_t)(value >> 16U);
    output[2] = (uint8_t)(value >> 8U);
    output[3] = (uint8_t)value;
}

static uint32_t load_be32(const uint8_t *input)
{
    return ((uint32_t)input[0] << 24U) | ((uint32_t)input[1] << 16U) |
           ((uint32_t)input[2] << 8U) | (uint32_t)input[3];
}

static void store_be64(uint8_t *output, uint64_t value)
{
    unsigned int index;

    for (index = 0U; index < 8U; ++index) {
        output[index] = (uint8_t)(value >> (56U - index * 8U));
    }
}

static uint64_t load_be64(const uint8_t *input)
{
    uint64_t value = 0U;
    unsigned int index;

    for (index = 0U; index < 8U; ++index) {
        value = (value << 8U) | (uint64_t)input[index];
    }
    return value;
}

static void encode_header(uint8_t type, uint8_t code, uint16_t payload_length,
                          uint64_t request_id, uint8_t output[20])
{
    store_be32(output, CONTROL_MAGIC);
    output[4] = DJONEHUB_CONTROL_VERSION;
    output[5] = type;
    output[6] = code;
    output[7] = 0U;
    store_be16(output + 8U, payload_length);
    output[10] = 0U;
    output[11] = 0U;
    store_be64(output + 12U, request_id);
}

static int valid_header(const uint8_t *frame, size_t frame_length,
                        uint8_t expected_type, uint16_t *payload_length,
                        uint64_t *request_id)
{
    if (frame == NULL || frame_length < DJONEHUB_CONTROL_HEADER_BYTES ||
        load_be32(frame) != CONTROL_MAGIC ||
        frame[4] != DJONEHUB_CONTROL_VERSION || frame[5] != expected_type ||
        frame[7] != 0U || frame[10] != 0U || frame[11] != 0U) {
        return -1;
    }
    *payload_length = load_be16(frame + 8U);
    *request_id = load_be64(frame + 12U);
    return 0;
}

static int operation_from_wire(uint8_t wire,
                               enum djonehub_voice_operation *operation)
{
    if (wire == 1U) {
        *operation = DJONEHUB_VOICE_STATUS;
    } else if (wire == 2U) {
        *operation = DJONEHUB_VOICE_DIAL;
    } else if (wire == 3U) {
        *operation = DJONEHUB_VOICE_ANSWER;
    } else if (wire == 4U) {
        *operation = DJONEHUB_VOICE_END;
    } else if (wire == 5U) {
        *operation = DJONEHUB_USB_AUDIO;
    } else {
        return -1;
    }
    return 0;
}

static uint8_t operation_to_wire(enum djonehub_voice_operation operation)
{
    switch (operation) {
    case DJONEHUB_VOICE_STATUS:
        return 1U;
    case DJONEHUB_VOICE_DIAL:
        return 2U;
    case DJONEHUB_VOICE_ANSWER:
        return 3U;
    case DJONEHUB_VOICE_END:
        return 4U;
    case DJONEHUB_USB_AUDIO:
        return 5U;
    default:
        return 0U;
    }
}

static int valid_dial_payload(const uint8_t *payload, size_t length)
{
    size_t index;

    if (payload == NULL || length == 0U ||
        length > DJONEHUB_VOICE_MAX_NUMBER_BYTES - 1U) {
        return 0;
    }
    for (index = 0U; index < length; ++index) {
        uint8_t value = payload[index];

        if ((value >= (uint8_t)'0' && value <= (uint8_t)'9') ||
            value == (uint8_t)'*' || value == (uint8_t)'#' ||
            (value == (uint8_t)'+' && index == 0U && length > 1U)) {
            continue;
        }
        return 0;
    }
    return 1;
}

static int valid_operation_payload(enum djonehub_voice_operation operation,
                                   const uint8_t *payload, size_t length)
{
    if (operation == DJONEHUB_VOICE_STATUS) {
        return length == 0U;
    }
    if (operation == DJONEHUB_VOICE_DIAL) {
        return valid_dial_payload(payload, length);
    }
    if (operation == DJONEHUB_VOICE_ANSWER ||
        operation == DJONEHUB_VOICE_END) {
        return length == 1U && payload != NULL && payload[0] != 0U;
    }
    if (operation == DJONEHUB_USB_AUDIO) {
        return length == 0U ||
               (length == 1U && payload != NULL && payload[0] <= 1U);
    }
    return 0;
}

static void make_tag(const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
                     const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES],
                     const uint8_t *frame_without_tag, size_t frame_length,
                     uint8_t tag[DJONEHUB_CONTROL_TAG_BYTES])
{
    uint8_t authenticated[DJONEHUB_CONTROL_NONCE_BYTES +
                          DJONEHUB_CONTROL_HEADER_BYTES +
                          DJONEHUB_CONTROL_MAX_PAYLOAD];

    memcpy(authenticated, nonce, DJONEHUB_CONTROL_NONCE_BYTES);
    memcpy(authenticated + DJONEHUB_CONTROL_NONCE_BYTES, frame_without_tag,
           frame_length);
    djonehub_hmac_sha256(key, DJONEHUB_PAIRING_KEY_BYTES, authenticated,
                         DJONEHUB_CONTROL_NONCE_BYTES + frame_length, tag);
    memset(authenticated, 0, sizeof(authenticated));
}

size_t djonehub_control_encode_hello(
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], uint8_t *output,
    size_t output_capacity)
{
    if (nonce == NULL || output == NULL ||
        output_capacity < DJONEHUB_CONTROL_HELLO_BYTES) {
        return 0U;
    }
    encode_header(FRAME_HELLO, 0U, DJONEHUB_CONTROL_NONCE_BYTES, 0U, output);
    memcpy(output + DJONEHUB_CONTROL_HEADER_BYTES, nonce,
           DJONEHUB_CONTROL_NONCE_BYTES);
    return DJONEHUB_CONTROL_HELLO_BYTES;
}

int djonehub_control_decode_hello(
    const uint8_t *frame, size_t frame_length,
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES])
{
    uint16_t payload_length;
    uint64_t request_id;

    if (nonce == NULL ||
        valid_header(frame, frame_length, FRAME_HELLO, &payload_length,
                     &request_id) != 0 ||
        frame[6] != 0U || request_id != 0U ||
        payload_length != DJONEHUB_CONTROL_NONCE_BYTES ||
        frame_length != DJONEHUB_CONTROL_HELLO_BYTES) {
        return -1;
    }
    memcpy(nonce, frame + DJONEHUB_CONTROL_HEADER_BYTES,
           DJONEHUB_CONTROL_NONCE_BYTES);
    return 0;
}

size_t djonehub_control_encode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES],
    enum djonehub_voice_operation operation, uint64_t request_id,
    const uint8_t *payload, size_t payload_length, uint8_t *output,
    size_t output_capacity)
{
    uint8_t wire_operation = operation_to_wire(operation);
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || output == NULL || request_id == 0U ||
        wire_operation == 0U ||
        !valid_operation_payload(operation, payload, payload_length) ||
        payload_length > DJONEHUB_CONTROL_MAX_PAYLOAD) {
        return 0U;
    }
    unsigned_length = DJONEHUB_CONTROL_HEADER_BYTES + payload_length;
    if (output_capacity < unsigned_length + DJONEHUB_CONTROL_TAG_BYTES) {
        return 0U;
    }
    encode_header(FRAME_REQUEST, wire_operation, (uint16_t)payload_length,
                  request_id, output);
    if (payload_length != 0U) {
        memcpy(output + DJONEHUB_CONTROL_HEADER_BYTES, payload,
               payload_length);
    }
    make_tag(key, nonce, output, unsigned_length, output + unsigned_length);
    return unsigned_length + DJONEHUB_CONTROL_TAG_BYTES;
}

int djonehub_control_decode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, struct djonehub_control_request *request)
{
    uint8_t expected_tag[DJONEHUB_CONTROL_TAG_BYTES];
    enum djonehub_voice_operation operation;
    uint16_t payload_length;
    uint64_t request_id;
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || request == NULL ||
        valid_header(frame, frame_length, FRAME_REQUEST, &payload_length,
                     &request_id) != 0 ||
        operation_from_wire(frame[6], &operation) != 0 || request_id == 0U ||
        payload_length > DJONEHUB_CONTROL_MAX_PAYLOAD) {
        return -1;
    }
    unsigned_length = DJONEHUB_CONTROL_HEADER_BYTES + (size_t)payload_length;
    if (frame_length != unsigned_length + DJONEHUB_CONTROL_TAG_BYTES ||
        !valid_operation_payload(operation,
                                 frame + DJONEHUB_CONTROL_HEADER_BYTES,
                                 payload_length)) {
        return -1;
    }
    make_tag(key, nonce, frame, unsigned_length, expected_tag);
    if (!djonehub_secure_equal(expected_tag, frame + unsigned_length,
                               sizeof(expected_tag))) {
        memset(expected_tag, 0, sizeof(expected_tag));
        return -2;
    }
    memset(expected_tag, 0, sizeof(expected_tag));
    memset(request, 0, sizeof(*request));
    request->operation = operation;
    request->request_id = request_id;
    request->payload_length = payload_length;
    if (payload_length != 0U) {
        memcpy(request->payload, frame + DJONEHUB_CONTROL_HEADER_BYTES,
               payload_length);
    }
    return 0;
}

static size_t encode_result_payload(const struct djonehub_control_result *result,
                                    uint8_t *output, size_t capacity)
{
    size_t required;
    size_t index;

    if (result == NULL || result->snapshot.count > DJONEHUB_VOICE_MAX_CALLS) {
        return 0U;
    }
    required = 4U + result->snapshot.count * 7U;
    if (capacity < required || operation_to_wire(result->operation) == 0U) {
        return 0U;
    }
    output[0] = operation_to_wire(result->operation);
    output[1] = result->action_call_id;
    output[2] = result->confirmed != 0U ? 1U : 0U;
    output[3] = (uint8_t)result->snapshot.count;
    for (index = 0U; index < result->snapshot.count; ++index) {
        const struct djonehub_voice_call *call = &result->snapshot.calls[index];
        uint8_t *record = output + 4U + index * 7U;

        record[0] = call->id;
        record[1] = call->state;
        record[2] = call->type;
        record[3] = call->direction;
        record[4] = call->mode;
        record[5] = call->multipart;
        record[6] = call->als;
    }
    return required;
}

size_t djonehub_control_encode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES],
    enum djonehub_control_status status, uint64_t request_id,
    const struct djonehub_control_result *result, uint8_t *output,
    size_t output_capacity)
{
    uint8_t payload[DJONEHUB_CONTROL_SNAPSHOT_BYTES];
    size_t payload_length = 0U;
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || output == NULL || request_id == 0U ||
        status < DJONEHUB_CONTROL_OK || status > DJONEHUB_CONTROL_FORBIDDEN) {
        return 0U;
    }
    if (status == DJONEHUB_CONTROL_OK) {
        payload_length = encode_result_payload(result, payload,
                                               sizeof(payload));
        if (payload_length == 0U) {
            return 0U;
        }
    } else if (result != NULL) {
        return 0U;
    }
    unsigned_length = DJONEHUB_CONTROL_HEADER_BYTES + payload_length;
    if (output_capacity < unsigned_length + DJONEHUB_CONTROL_TAG_BYTES) {
        return 0U;
    }
    encode_header(FRAME_RESPONSE, (uint8_t)status, (uint16_t)payload_length,
                  request_id, output);
    if (payload_length != 0U) {
        memcpy(output + DJONEHUB_CONTROL_HEADER_BYTES, payload,
               payload_length);
    }
    make_tag(key, nonce, output, unsigned_length, output + unsigned_length);
    memset(payload, 0, sizeof(payload));
    return unsigned_length + DJONEHUB_CONTROL_TAG_BYTES;
}

static int decode_result_payload(const uint8_t *payload, size_t length,
                                 struct djonehub_control_result *result)
{
    enum djonehub_voice_operation operation;
    size_t count;
    size_t index;

    if (payload == NULL || result == NULL || length < 4U ||
        operation_from_wire(payload[0], &operation) != 0 || payload[2] > 1U) {
        return -1;
    }
    count = payload[3];
    if (count > DJONEHUB_VOICE_MAX_CALLS || length != 4U + count * 7U) {
        return -1;
    }
    memset(result, 0, sizeof(*result));
    result->operation = operation;
    result->action_call_id = payload[1];
    result->confirmed = payload[2];
    result->snapshot.count = count;
    for (index = 0U; index < count; ++index) {
        struct djonehub_voice_call *call = &result->snapshot.calls[index];
        const uint8_t *record = payload + 4U + index * 7U;

        call->id = record[0];
        call->state = record[1];
        call->type = record[2];
        call->direction = record[3];
        call->mode = record[4];
        call->multipart = record[5];
        call->als = record[6];
        if (call->id == 0U) {
            return -1;
        }
    }
    return 0;
}

int djonehub_control_decode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, enum djonehub_control_status *status,
    uint64_t *request_id, struct djonehub_control_result *result)
{
    uint8_t expected_tag[DJONEHUB_CONTROL_TAG_BYTES];
    uint16_t payload_length;
    uint64_t decoded_request_id;
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || status == NULL || request_id == NULL ||
        result == NULL ||
        valid_header(frame, frame_length, FRAME_RESPONSE, &payload_length,
                     &decoded_request_id) != 0 ||
        frame[6] > (uint8_t)DJONEHUB_CONTROL_FORBIDDEN ||
        decoded_request_id == 0U ||
        payload_length > DJONEHUB_CONTROL_SNAPSHOT_BYTES) {
        return -1;
    }
    unsigned_length = DJONEHUB_CONTROL_HEADER_BYTES + (size_t)payload_length;
    if (frame_length != unsigned_length + DJONEHUB_CONTROL_TAG_BYTES) {
        return -1;
    }
    make_tag(key, nonce, frame, unsigned_length, expected_tag);
    if (!djonehub_secure_equal(expected_tag, frame + unsigned_length,
                               sizeof(expected_tag))) {
        memset(expected_tag, 0, sizeof(expected_tag));
        return -2;
    }
    memset(expected_tag, 0, sizeof(expected_tag));
    *status = (enum djonehub_control_status)frame[6];
    *request_id = decoded_request_id;
    if (*status == DJONEHUB_CONTROL_OK) {
        return decode_result_payload(frame + DJONEHUB_CONTROL_HEADER_BYTES,
                                     payload_length, result);
    }
    if (payload_length != 0U) {
        return -1;
    }
    memset(result, 0, sizeof(*result));
    return 0;
}
