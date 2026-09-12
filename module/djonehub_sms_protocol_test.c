#include "djonehub_sms_protocol.h"

#include <stdio.h>
#include <string.h>

#define CHECK(value)                                                         \
    do {                                                                     \
        if (!(value)) {                                                      \
            fprintf(stderr, "check failed at line %d: %s\n", __LINE__,      \
                    #value);                                                 \
            return 1;                                                        \
        }                                                                    \
    } while (0)

int main(void)
{
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t bad_key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t nonce[DJONEHUB_SMS_NONCE_BYTES];
    uint8_t decoded_nonce[DJONEHUB_SMS_NONCE_BYTES];
    uint8_t frame[DJONEHUB_SMS_MAX_RESPONSE_FRAME_BYTES];
    uint8_t payload[64];
    uint8_t decoded_payload[64];
    struct djonehub_sms_request request;
    enum djonehub_sms_status status;
    enum djonehub_sms_operation operation;
    uint64_t request_id;
    size_t length;
    size_t decoded_length;
    size_t index;

    for (index = 0U; index < sizeof(key); ++index) {
        key[index] = (uint8_t)(index + 1U);
        bad_key[index] = key[index];
        nonce[index] = (uint8_t)(0xa0U + index);
    }
    bad_key[0] ^= 0xffU;

    length = djonehub_sms_encode_hello(nonce, frame, sizeof(frame));
    CHECK(length == DJONEHUB_SMS_HELLO_BYTES);
    CHECK(djonehub_sms_decode_hello(frame, length, decoded_nonce) == 0);
    CHECK(memcmp(nonce, decoded_nonce, sizeof(nonce)) == 0);
    frame[0] ^= 1U;
    CHECK(djonehub_sms_decode_hello(frame, length, decoded_nonce) != 0);

    payload[0] = 1U;
    payload[1] = 0U;
    payload[2] = 0U;
    payload[3] = 0U;
    payload[4] = 7U;
    length = djonehub_sms_encode_request(
        key, nonce, DJONEHUB_SMS_READ, UINT64_C(0x0102030405060708),
        payload, 5U, frame, sizeof(frame));
    CHECK(length == DJONEHUB_SMS_HEADER_BYTES + 5U + DJONEHUB_SMS_TAG_BYTES);
    CHECK(djonehub_sms_decode_request(key, nonce, frame, length, &request) ==
          0);
    CHECK(request.operation == DJONEHUB_SMS_READ);
    CHECK(request.request_id == UINT64_C(0x0102030405060708));
    CHECK(request.payload_length == 5U);
    CHECK(memcmp(request.payload, payload, 5U) == 0);
    CHECK(djonehub_sms_decode_request(bad_key, nonce, frame, length, &request) ==
          -2);

    payload[0] = 0x06U;
    payload[1] = 0U;
    payload[2] = 3U;
    payload[3] = 0x11U;
    payload[4] = 0x22U;
    payload[5] = 0x33U;
    CHECK(djonehub_sms_encode_request(key, nonce, DJONEHUB_SMS_SEND_RAW, 9U,
                                      payload, 6U, frame,
                                      sizeof(frame)) != 0U);
    payload[2] = 4U;
    CHECK(djonehub_sms_encode_request(key, nonce, DJONEHUB_SMS_SEND_RAW, 9U,
                                      payload, 6U, frame,
                                      sizeof(frame)) == 0U);
    payload[2] = 3U;
    payload[0] = 0U;
    CHECK(djonehub_sms_encode_request(key, nonce, DJONEHUB_SMS_SEND_RAW, 9U,
                                      payload, 6U, frame,
                                      sizeof(frame)) == 0U);

    payload[0] = 1U;
    payload[1] = 2U;
    payload[2] = 3U;
    length = djonehub_sms_encode_response(
        key, nonce, DJONEHUB_SMS_OK, 42U, DJONEHUB_SMS_STATUS, payload, 3U,
        frame, sizeof(frame));
    CHECK(length != 0U);
    CHECK(djonehub_sms_decode_response(
              key, nonce, frame, length, &status, &request_id, &operation,
              decoded_payload, sizeof(decoded_payload), &decoded_length) ==
          0);
    CHECK(status == DJONEHUB_SMS_OK);
    CHECK(operation == DJONEHUB_SMS_STATUS);
    CHECK(request_id == 42U);
    CHECK(decoded_length == 3U);
    CHECK(memcmp(payload, decoded_payload, 3U) == 0);

    length = djonehub_sms_encode_response(
        key, nonce, DJONEHUB_SMS_FORBIDDEN, 43U, DJONEHUB_SMS_DELETE, NULL,
        0U, frame, sizeof(frame));
    CHECK(length != 0U);
    CHECK(djonehub_sms_decode_response(
              key, nonce, frame, length, &status, &request_id, &operation,
              decoded_payload, sizeof(decoded_payload), &decoded_length) ==
          0);
    CHECK(status == DJONEHUB_SMS_FORBIDDEN);
    CHECK(operation == DJONEHUB_SMS_DELETE);
    CHECK(decoded_length == 0U);

    frame[length - 1U] ^= 1U;
    CHECK(djonehub_sms_decode_response(
              key, nonce, frame, length, &status, &request_id, &operation,
              decoded_payload, sizeof(decoded_payload), &decoded_length) ==
          -2);

    puts("djonehub_sms_protocol_test: ok");
    return 0;
}
