#include "djonehub_control_protocol.h"

#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__, \
                    #condition);                                                \
            return 1;                                                           \
        }                                                                       \
    } while (0)

static int test_hmac_vector(void)
{
    static const uint8_t expected[DJONEHUB_SHA256_BYTES] = {
        0xb0U, 0x34U, 0x4cU, 0x61U, 0xd8U, 0xdbU, 0x38U, 0x53U,
        0x5cU, 0xa8U, 0xafU, 0xceU, 0xafU, 0x0bU, 0xf1U, 0x2bU,
        0x88U, 0x1dU, 0xc2U, 0x00U, 0xc9U, 0x83U, 0x3dU, 0xa7U,
        0x26U, 0xe9U, 0x37U, 0x6cU, 0x2eU, 0x32U, 0xcfU, 0xf7U
    };
    const uint8_t message[] = "Hi There";
    uint8_t key[20];
    uint8_t digest[DJONEHUB_SHA256_BYTES];

    memset(key, 0x0b, sizeof(key));
    djonehub_hmac_sha256(key, sizeof(key), message, sizeof(message) - 1U,
                         digest);
    CHECK(djonehub_secure_equal(digest, expected, sizeof(expected)));
    digest[0] ^= 1U;
    CHECK(!djonehub_secure_equal(digest, expected, sizeof(expected)));
    CHECK(!djonehub_secure_equal(NULL, expected, sizeof(expected)));
    return 0;
}

static void fill_material(uint8_t key[DJONEHUB_PAIRING_KEY_BYTES],
                          uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES])
{
    unsigned int index;

    for (index = 0U; index < DJONEHUB_PAIRING_KEY_BYTES; ++index) {
        key[index] = (uint8_t)(index + 1U);
        nonce[index] = (uint8_t)(0xa0U + index);
    }
}

static int test_hello(void)
{
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t decoded[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t frame[DJONEHUB_CONTROL_HELLO_BYTES];
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    size_t length;

    fill_material(key, nonce);
    length = djonehub_control_encode_hello(nonce, frame, sizeof(frame));
    CHECK(length == sizeof(frame));
    CHECK(djonehub_control_decode_hello(frame, length, decoded) == 0);
    CHECK(memcmp(nonce, decoded, sizeof(nonce)) == 0);
    frame[7] = 1U;
    CHECK(djonehub_control_decode_hello(frame, length, decoded) == -1);
    return 0;
}

static int test_request_authentication(void)
{
    const uint8_t number[] = "+8613800138000";
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t wrong_key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t next_nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t frame[DJONEHUB_CONTROL_MAX_FRAME_BYTES];
    struct djonehub_control_request request;
    size_t length;

    fill_material(key, nonce);
    memcpy(wrong_key, key, sizeof(key));
    wrong_key[0] ^= 1U;
    memcpy(next_nonce, nonce, sizeof(nonce));
    next_nonce[31] ^= 1U;
    length = djonehub_control_encode_request(
        key, nonce, DJONEHUB_VOICE_DIAL, 0x0102030405060708ULL, number,
        sizeof(number) - 1U, frame, sizeof(frame));
    CHECK(length != 0U);
    CHECK(djonehub_control_decode_request(key, nonce, frame, length,
                                          &request) == 0);
    CHECK(request.operation == DJONEHUB_VOICE_DIAL);
    CHECK(request.request_id == 0x0102030405060708ULL);
    CHECK(request.payload_length == sizeof(number) - 1U);
    CHECK(memcmp(request.payload, number, sizeof(number) - 1U) == 0);
    CHECK(djonehub_control_decode_request(wrong_key, nonce, frame, length,
                                          &request) == -2);
    CHECK(djonehub_control_decode_request(key, next_nonce, frame, length,
                                          &request) == -2);
    frame[6] = 4U;
    CHECK(djonehub_control_decode_request(key, nonce, frame, length,
                                          &request) == -1);
    return 0;
}

static int test_request_validation(void)
{
    const uint8_t invalid_number[] = "12;reboot";
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t frame[DJONEHUB_CONTROL_MAX_FRAME_BYTES];
    uint8_t call_id = 7U;

    fill_material(key, nonce);
    CHECK(djonehub_control_encode_request(
              key, nonce, DJONEHUB_VOICE_STATUS, 1U, NULL, 0U, frame,
              sizeof(frame)) != 0U);
    CHECK(djonehub_control_encode_request(
              key, nonce, DJONEHUB_VOICE_STATUS, 0U, NULL, 0U, frame,
              sizeof(frame)) == 0U);
    CHECK(djonehub_control_encode_request(
              key, nonce, DJONEHUB_VOICE_DIAL, 2U, invalid_number,
              sizeof(invalid_number) - 1U, frame, sizeof(frame)) == 0U);
    CHECK(djonehub_control_encode_request(
              key, nonce, DJONEHUB_VOICE_ANSWER, 3U, &call_id, 1U, frame,
              sizeof(frame)) != 0U);
    call_id = 0U;
    CHECK(djonehub_control_encode_request(
              key, nonce, DJONEHUB_VOICE_END, 4U, &call_id, 1U, frame,
              sizeof(frame)) == 0U);
    return 0;
}

static int test_response(void)
{
    uint8_t key[DJONEHUB_PAIRING_KEY_BYTES];
    uint8_t nonce[DJONEHUB_CONTROL_NONCE_BYTES];
    uint8_t frame[DJONEHUB_CONTROL_MAX_FRAME_BYTES];
    struct djonehub_control_result encoded;
    struct djonehub_control_result decoded;
    enum djonehub_control_status status;
    uint64_t request_id;
    size_t length;

    fill_material(key, nonce);
    memset(&encoded, 0, sizeof(encoded));
    encoded.operation = DJONEHUB_VOICE_ANSWER;
    encoded.action_call_id = 1U;
    encoded.confirmed = 1U;
    encoded.snapshot.count = 1U;
    encoded.snapshot.calls[0].id = 1U;
    encoded.snapshot.calls[0].state = 3U;
    encoded.snapshot.calls[0].type = 2U;
    encoded.snapshot.calls[0].direction = 2U;
    encoded.snapshot.calls[0].mode = 4U;
    length = djonehub_control_encode_response(
        key, nonce, DJONEHUB_CONTROL_OK, 42U, &encoded, frame,
        sizeof(frame));
    CHECK(length != 0U);
    CHECK(djonehub_control_decode_response(key, nonce, frame, length, &status,
                                           &request_id, &decoded) == 0);
    CHECK(status == DJONEHUB_CONTROL_OK);
    CHECK(request_id == 42U);
    CHECK(decoded.operation == DJONEHUB_VOICE_ANSWER);
    CHECK(decoded.confirmed == 1U);
    CHECK(decoded.snapshot.count == 1U);
    CHECK(decoded.snapshot.calls[0].state == 3U);

    length = djonehub_control_encode_response(
        key, nonce, DJONEHUB_CONTROL_PRECONDITION, 43U, NULL, frame,
        sizeof(frame));
    CHECK(length != 0U);
    CHECK(djonehub_control_decode_response(key, nonce, frame, length, &status,
                                           &request_id, &decoded) == 0);
    CHECK(status == DJONEHUB_CONTROL_PRECONDITION);
    CHECK(request_id == 43U);
    return 0;
}

int main(void)
{
    CHECK(test_hmac_vector() == 0);
    CHECK(test_hello() == 0);
    CHECK(test_request_authentication() == 0);
    CHECK(test_request_validation() == 0);
    CHECK(test_response() == 0);
    puts("djonehub_control_protocol_test: ok");
    return 0;
}
