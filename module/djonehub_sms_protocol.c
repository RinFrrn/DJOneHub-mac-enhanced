#include "djonehub_sms_protocol.h"

#include <string.h>

#define SMS_MAGIC 0x444A4F53U
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
    return (uint16_t)(((uint16_t)input[0] << 8U) | input[1]);
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
           ((uint32_t)input[2] << 8U) | input[3];
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
        value = (value << 8U) | input[index];
    }
    return value;
}

static int valid_operation(uint8_t value,
                           enum djonehub_sms_operation *operation)
{
    if (value < (uint8_t)DJONEHUB_SMS_STATUS ||
        value > (uint8_t)DJONEHUB_SMS_DELETE || operation == NULL) {
        return 0;
    }
    *operation = (enum djonehub_sms_operation)value;
    return 1;
}

static int valid_request_payload(enum djonehub_sms_operation operation,
                                 const uint8_t *payload, size_t length)
{
    uint16_t pdu_length;

    if (operation == DJONEHUB_SMS_STATUS) {
        return length == 0U;
    }
    if (operation == DJONEHUB_SMS_LIST) {
        return length == 1U && payload != NULL && payload[0] <= 1U;
    }
    if (operation == DJONEHUB_SMS_READ || operation == DJONEHUB_SMS_DELETE) {
        return length == 5U && payload != NULL && payload[0] <= 1U;
    }
    if (operation != DJONEHUB_SMS_SEND_RAW || payload == NULL || length < 4U ||
        length > DJONEHUB_SMS_MAX_REQUEST_PAYLOAD || payload[0] != 0x06U) {
        return 0;
    }
    pdu_length = load_be16(payload + 1U);
    return pdu_length != 0U && pdu_length <= DJONEHUB_SMS_MAX_PDU_BYTES &&
           length == 3U + (size_t)pdu_length;
}

static void encode_header(uint8_t type, uint8_t code, uint16_t payload_length,
                          uint64_t request_id, uint8_t output[20])
{
    store_be32(output, SMS_MAGIC);
    output[4] = DJONEHUB_SMS_VERSION;
    output[5] = type;
    output[6] = code;
    output[7] = 0U;
    store_be16(output + 8U, payload_length);
    output[10] = 0U;
    output[11] = 0U;
    store_be64(output + 12U, request_id);
}

static int decode_header(const uint8_t *frame, size_t frame_length,
                         uint8_t expected_type, uint16_t *payload_length,
                         uint64_t *request_id)
{
    if (frame == NULL || payload_length == NULL || request_id == NULL ||
        frame_length < DJONEHUB_SMS_HEADER_BYTES ||
        load_be32(frame) != SMS_MAGIC || frame[4] != DJONEHUB_SMS_VERSION ||
        frame[5] != expected_type || frame[7] != 0U || frame[10] != 0U ||
        frame[11] != 0U) {
        return -1;
    }
    *payload_length = load_be16(frame + 8U);
    *request_id = load_be64(frame + 12U);
    return 0;
}

static void make_tag(const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
                     const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES],
                     const uint8_t *frame, size_t frame_length,
                     uint8_t tag[DJONEHUB_SMS_TAG_BYTES])
{
    uint8_t authenticated[DJONEHUB_SMS_NONCE_BYTES +
                          DJONEHUB_SMS_HEADER_BYTES +
                          DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD];

    memcpy(authenticated, nonce, DJONEHUB_SMS_NONCE_BYTES);
    memcpy(authenticated + DJONEHUB_SMS_NONCE_BYTES, frame, frame_length);
    djonehub_hmac_sha256(key, DJONEHUB_PAIRING_KEY_BYTES, authenticated,
                        DJONEHUB_SMS_NONCE_BYTES + frame_length, tag);
    memset(authenticated, 0, sizeof(authenticated));
}

size_t djonehub_sms_encode_hello(
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], uint8_t *output,
    size_t output_capacity)
{
    if (nonce == NULL || output == NULL ||
        output_capacity < DJONEHUB_SMS_HELLO_BYTES) {
        return 0U;
    }
    encode_header(FRAME_HELLO, 0U, DJONEHUB_SMS_NONCE_BYTES, 0U, output);
    memcpy(output + DJONEHUB_SMS_HEADER_BYTES, nonce,
           DJONEHUB_SMS_NONCE_BYTES);
    return DJONEHUB_SMS_HELLO_BYTES;
}

int djonehub_sms_decode_hello(
    const uint8_t *frame, size_t frame_length,
    uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES])
{
    uint16_t payload_length;
    uint64_t request_id;

    if (nonce == NULL ||
        decode_header(frame, frame_length, FRAME_HELLO, &payload_length,
                      &request_id) != 0 ||
        frame[6] != 0U || request_id != 0U ||
        payload_length != DJONEHUB_SMS_NONCE_BYTES ||
        frame_length != DJONEHUB_SMS_HELLO_BYTES) {
        return -1;
    }
    memcpy(nonce, frame + DJONEHUB_SMS_HEADER_BYTES,
           DJONEHUB_SMS_NONCE_BYTES);
    return 0;
}

size_t djonehub_sms_encode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES],
    enum djonehub_sms_operation operation, uint64_t request_id,
    const uint8_t *payload, size_t payload_length, uint8_t *output,
    size_t output_capacity)
{
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || output == NULL || request_id == 0U ||
        !valid_request_payload(operation, payload, payload_length)) {
        return 0U;
    }
    unsigned_length = DJONEHUB_SMS_HEADER_BYTES + payload_length;
    if (output_capacity < unsigned_length + DJONEHUB_SMS_TAG_BYTES) {
        return 0U;
    }
    encode_header(FRAME_REQUEST, (uint8_t)operation,
                  (uint16_t)payload_length, request_id, output);
    if (payload_length != 0U) {
        memcpy(output + DJONEHUB_SMS_HEADER_BYTES, payload, payload_length);
    }
    make_tag(key, nonce, output, unsigned_length, output + unsigned_length);
    return unsigned_length + DJONEHUB_SMS_TAG_BYTES;
}

int djonehub_sms_decode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, struct djonehub_sms_request *request)
{
    uint8_t expected[DJONEHUB_SMS_TAG_BYTES];
    enum djonehub_sms_operation operation;
    uint16_t payload_length;
    uint64_t request_id;
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || request == NULL ||
        decode_header(frame, frame_length, FRAME_REQUEST, &payload_length,
                      &request_id) != 0 ||
        !valid_operation(frame[6], &operation) || request_id == 0U ||
        payload_length > DJONEHUB_SMS_MAX_REQUEST_PAYLOAD) {
        return -1;
    }
    unsigned_length = DJONEHUB_SMS_HEADER_BYTES + payload_length;
    if (frame_length != unsigned_length + DJONEHUB_SMS_TAG_BYTES ||
        !valid_request_payload(operation, frame + DJONEHUB_SMS_HEADER_BYTES,
                               payload_length)) {
        return -1;
    }
    make_tag(key, nonce, frame, unsigned_length, expected);
    if (!djonehub_secure_equal(expected, frame + unsigned_length,
                               sizeof(expected))) {
        memset(expected, 0, sizeof(expected));
        return -2;
    }
    memset(expected, 0, sizeof(expected));
    memset(request, 0, sizeof(*request));
    request->operation = operation;
    request->request_id = request_id;
    request->payload_length = payload_length;
    if (payload_length != 0U) {
        memcpy(request->payload, frame + DJONEHUB_SMS_HEADER_BYTES,
               payload_length);
    }
    return 0;
}

size_t djonehub_sms_encode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES],
    enum djonehub_sms_status status, uint64_t request_id,
    enum djonehub_sms_operation operation, const uint8_t *payload,
    size_t payload_length, uint8_t *output, size_t output_capacity)
{
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || output == NULL || request_id == 0U ||
        status < DJONEHUB_SMS_OK || status > DJONEHUB_SMS_LIMIT_EXCEEDED ||
        operation < DJONEHUB_SMS_STATUS || operation > DJONEHUB_SMS_DELETE ||
        payload_length > DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD ||
        (payload_length != 0U && payload == NULL) ||
        (status != DJONEHUB_SMS_OK && payload_length != 0U)) {
        return 0U;
    }
    unsigned_length = DJONEHUB_SMS_HEADER_BYTES + payload_length;
    if (output_capacity < unsigned_length + DJONEHUB_SMS_TAG_BYTES) {
        return 0U;
    }
    encode_header(FRAME_RESPONSE, (uint8_t)status, (uint16_t)payload_length,
                  request_id, output);
    output[7] = (uint8_t)operation;
    if (payload_length != 0U) {
        memcpy(output + DJONEHUB_SMS_HEADER_BYTES, payload, payload_length);
    }
    make_tag(key, nonce, output, unsigned_length, output + unsigned_length);
    return unsigned_length + DJONEHUB_SMS_TAG_BYTES;
}

int djonehub_sms_decode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, enum djonehub_sms_status *status,
    uint64_t *request_id, enum djonehub_sms_operation *operation,
    uint8_t *payload, size_t payload_capacity, size_t *payload_length)
{
    uint8_t expected[DJONEHUB_SMS_TAG_BYTES];
    uint16_t encoded_length;
    size_t unsigned_length;

    if (key == NULL || nonce == NULL || status == NULL || request_id == NULL ||
        operation == NULL || payload_length == NULL || frame == NULL ||
        frame_length < DJONEHUB_SMS_HEADER_BYTES ||
        load_be32(frame) != SMS_MAGIC || frame[4] != DJONEHUB_SMS_VERSION ||
        frame[5] != FRAME_RESPONSE || frame[10] != 0U || frame[11] != 0U ||
        frame[6] > (uint8_t)DJONEHUB_SMS_LIMIT_EXCEEDED ||
        !valid_operation(frame[7], operation)) {
        return -1;
    }
    encoded_length = load_be16(frame + 8U);
    *request_id = load_be64(frame + 12U);
    unsigned_length = DJONEHUB_SMS_HEADER_BYTES + encoded_length;
    if (*request_id == 0U || encoded_length > DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD ||
        frame_length != unsigned_length + DJONEHUB_SMS_TAG_BYTES ||
        encoded_length > payload_capacity ||
        (encoded_length != 0U && payload == NULL) ||
        (frame[6] != (uint8_t)DJONEHUB_SMS_OK && encoded_length != 0U)) {
        return -1;
    }
    make_tag(key, nonce, frame, unsigned_length, expected);
    if (!djonehub_secure_equal(expected, frame + unsigned_length,
                               sizeof(expected))) {
        memset(expected, 0, sizeof(expected));
        return -2;
    }
    memset(expected, 0, sizeof(expected));
    *status = (enum djonehub_sms_status)frame[6];
    *payload_length = encoded_length;
    if (encoded_length != 0U) {
        memcpy(payload, frame + DJONEHUB_SMS_HEADER_BYTES, encoded_length);
    }
    return 0;
}
