#ifndef DJONEHUB_SMS_PROTOCOL_H
#define DJONEHUB_SMS_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#include "djonehub_crypto.h"

#define DJONEHUB_SMS_VERSION 1U
#define DJONEHUB_SMS_HEADER_BYTES 20U
#define DJONEHUB_SMS_NONCE_BYTES 32U
#define DJONEHUB_SMS_TAG_BYTES 32U
#define DJONEHUB_SMS_MAX_PDU_BYTES 512U
#define DJONEHUB_SMS_MAX_REQUEST_PAYLOAD (3U + DJONEHUB_SMS_MAX_PDU_BYTES)
#define DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD 1024U
#define DJONEHUB_SMS_HELLO_BYTES \
    (DJONEHUB_SMS_HEADER_BYTES + DJONEHUB_SMS_NONCE_BYTES)
#define DJONEHUB_SMS_MAX_REQUEST_FRAME_BYTES                              \
    (DJONEHUB_SMS_HEADER_BYTES + DJONEHUB_SMS_MAX_REQUEST_PAYLOAD +       \
     DJONEHUB_SMS_TAG_BYTES)
#define DJONEHUB_SMS_MAX_RESPONSE_FRAME_BYTES                             \
    (DJONEHUB_SMS_HEADER_BYTES + DJONEHUB_SMS_MAX_RESPONSE_PAYLOAD +      \
     DJONEHUB_SMS_TAG_BYTES)

enum djonehub_sms_operation {
    DJONEHUB_SMS_STATUS = 1,
    DJONEHUB_SMS_LIST = 2,
    DJONEHUB_SMS_READ = 3,
    DJONEHUB_SMS_SEND_RAW = 4,
    DJONEHUB_SMS_DELETE = 5
};

enum djonehub_sms_status {
    DJONEHUB_SMS_OK = 0,
    DJONEHUB_SMS_MALFORMED = 1,
    DJONEHUB_SMS_AUTH_FAILED = 2,
    DJONEHUB_SMS_PRECONDITION = 3,
    DJONEHUB_SMS_QMI_FAILED = 4,
    DJONEHUB_SMS_INTERNAL = 5,
    DJONEHUB_SMS_FORBIDDEN = 6,
    DJONEHUB_SMS_LIMIT_EXCEEDED = 7
};

struct djonehub_sms_request {
    enum djonehub_sms_operation operation;
    uint64_t request_id;
    size_t payload_length;
    uint8_t payload[DJONEHUB_SMS_MAX_REQUEST_PAYLOAD];
};

size_t djonehub_sms_encode_hello(
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], uint8_t *output,
    size_t output_capacity);

int djonehub_sms_decode_hello(
    const uint8_t *frame, size_t frame_length,
    uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES]);

size_t djonehub_sms_encode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES],
    enum djonehub_sms_operation operation, uint64_t request_id,
    const uint8_t *payload, size_t payload_length, uint8_t *output,
    size_t output_capacity);

int djonehub_sms_decode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, struct djonehub_sms_request *request);

size_t djonehub_sms_encode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES],
    enum djonehub_sms_status status, uint64_t request_id,
    enum djonehub_sms_operation operation, const uint8_t *payload,
    size_t payload_length, uint8_t *output, size_t output_capacity);

int djonehub_sms_decode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, enum djonehub_sms_status *status,
    uint64_t *request_id, enum djonehub_sms_operation *operation,
    uint8_t *payload, size_t payload_capacity, size_t *payload_length);

#endif
