#ifndef DJONEHUB_CONTROL_PROTOCOL_H
#define DJONEHUB_CONTROL_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#include "djonehub_crypto.h"
#include "djonehub_voice_codec.h"
#include "djonehub_voice_policy.h"

#define DJONEHUB_CONTROL_VERSION 1U
#define DJONEHUB_CONTROL_HEADER_BYTES 20U
#define DJONEHUB_CONTROL_NONCE_BYTES 32U
#define DJONEHUB_CONTROL_TAG_BYTES 32U
#define DJONEHUB_CONTROL_MAX_PAYLOAD DJONEHUB_VOICE_MAX_NUMBER_BYTES
#define DJONEHUB_CONTROL_HELLO_BYTES                                      \
    (DJONEHUB_CONTROL_HEADER_BYTES + DJONEHUB_CONTROL_NONCE_BYTES)
#define DJONEHUB_CONTROL_MAX_FRAME_BYTES                                 \
    (DJONEHUB_CONTROL_HEADER_BYTES + DJONEHUB_CONTROL_MAX_PAYLOAD +       \
     DJONEHUB_CONTROL_TAG_BYTES)
#define DJONEHUB_CONTROL_SNAPSHOT_BYTES                                  \
    (4U + DJONEHUB_VOICE_MAX_CALLS * 7U)

enum djonehub_control_status {
    DJONEHUB_CONTROL_OK = 0,
    DJONEHUB_CONTROL_MALFORMED = 1,
    DJONEHUB_CONTROL_AUTH_FAILED = 2,
    DJONEHUB_CONTROL_PRECONDITION = 3,
    DJONEHUB_CONTROL_QMI_FAILED = 4,
    DJONEHUB_CONTROL_CONFIRM_TIMEOUT = 5,
    DJONEHUB_CONTROL_INTERNAL = 6
};

struct djonehub_control_request {
    enum djonehub_voice_operation operation;
    uint64_t request_id;
    size_t payload_length;
    uint8_t payload[DJONEHUB_CONTROL_MAX_PAYLOAD];
};

struct djonehub_control_result {
    enum djonehub_voice_operation operation;
    uint8_t action_call_id;
    uint8_t confirmed;
    struct djonehub_voice_snapshot snapshot;
};

size_t djonehub_control_encode_hello(
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], uint8_t *output,
    size_t output_capacity);

int djonehub_control_decode_hello(
    const uint8_t *frame, size_t frame_length,
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES]);

size_t djonehub_control_encode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES],
    enum djonehub_voice_operation operation, uint64_t request_id,
    const uint8_t *payload, size_t payload_length, uint8_t *output,
    size_t output_capacity);

int djonehub_control_decode_request(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, struct djonehub_control_request *request);

size_t djonehub_control_encode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES],
    enum djonehub_control_status status, uint64_t request_id,
    const struct djonehub_control_result *result, uint8_t *output,
    size_t output_capacity);

int djonehub_control_decode_response(
    const uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
    const uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES], const uint8_t *frame,
    size_t frame_length, enum djonehub_control_status *status,
    uint64_t *request_id, struct djonehub_control_result *result);

#endif
