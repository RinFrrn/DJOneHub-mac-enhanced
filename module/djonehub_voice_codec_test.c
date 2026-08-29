#include "djonehub_voice_codec.h"
#include "djonehub_voice_policy.h"

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

static int test_empty_snapshot(void)
{
    const uint8_t response[] = {0x02U, 0x04U, 0x00U, 0x00U,
                                0x00U, 0x00U, 0x00U};
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 99U;

    CHECK(djonehub_voice_parse_snapshot(response, sizeof(response), &snapshot,
                                        &service_error) == 0);
    CHECK(service_error == 0U);
    CHECK(snapshot.count == 0U);
    return 0;
}

static int test_call_snapshot(void)
{
    const uint8_t response[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x0FU, 0x00U, 0x02U,
        0x01U, 0x02U, 0x00U, 0x02U, 0x05U, 0x00U, 0x00U,
        0x02U, 0x03U, 0x02U, 0x01U, 0x05U, 0x00U, 0x00U};
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_snapshot(response, sizeof(response), &snapshot,
                                        &service_error) == 0);
    CHECK(snapshot.count == 2U);
    CHECK(snapshot.calls[0].id == 1U);
    CHECK(snapshot.calls[0].state == 2U);
    CHECK(snapshot.calls[0].direction == 2U);
    CHECK(strcmp(djonehub_voice_call_state_name(snapshot.calls[0].state),
                 "incoming") == 0);
    CHECK(snapshot.calls[1].id == 2U);
    CHECK(snapshot.calls[1].state == 3U);
    CHECK(snapshot.calls[1].direction == 1U);
    return 0;
}

static int test_malformed_snapshot(void)
{
    const uint8_t response[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x08U, 0x00U, 0x02U,
        0x01U, 0x02U, 0x00U, 0x02U, 0x05U, 0x00U, 0x00U};
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_snapshot(response, sizeof(response), &snapshot,
                                        &service_error) == -1);
    return 0;
}

static int test_rejected_call_records(void)
{
    const uint8_t duplicate_ids[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x0FU, 0x00U, 0x02U,
        0x01U, 0x02U, 0x00U, 0x02U, 0x05U, 0x00U, 0x00U,
        0x01U, 0x03U, 0x00U, 0x01U, 0x05U, 0x00U, 0x00U};
    const uint8_t invalid_state[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x08U, 0x00U, 0x01U,
        0x01U, 0x0BU, 0x00U, 0x02U, 0x05U, 0x00U, 0x00U};
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_snapshot(duplicate_ids, sizeof(duplicate_ids),
                                        &snapshot, &service_error) == -1);
    CHECK(snapshot.count == 0U);
    CHECK(djonehub_voice_parse_snapshot(invalid_state, sizeof(invalid_state),
                                        &snapshot, &service_error) == -1);
    CHECK(snapshot.count == 0U);
    return 0;
}

static int test_service_error(void)
{
    const uint8_t response[] = {0x02U, 0x04U, 0x00U, 0x01U,
                                0x00U, 0x1AU, 0x00U};
    struct djonehub_voice_snapshot snapshot;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_snapshot(response, sizeof(response), &snapshot,
                                        &service_error) == 1);
    CHECK(service_error == 0x1AU);
    return 0;
}

static int test_request_builders(void)
{
    uint8_t request[96];
    size_t request_length = 0U;

    CHECK(djonehub_voice_build_dial_request("+8613800138000", request,
                                            sizeof(request),
                                            &request_length) == 0);
    CHECK(request_length == 17U);
    CHECK(request[0] == 0x01U && request[1] == 14U && request[2] == 0U);
    CHECK(memcmp(request + 3U, "+8613800138000", 14U) == 0);
    CHECK(djonehub_voice_build_dial_request("12 34", request,
                                            sizeof(request),
                                            &request_length) == -1);
    CHECK(djonehub_voice_build_dial_request("1+2", request, sizeof(request),
                                            &request_length) == -1);
    CHECK(request_length == 0U);
    CHECK(djonehub_voice_build_dial_request("+", request, sizeof(request),
                                            &request_length) == -1);
    CHECK(djonehub_voice_build_dial_request("1234", request, 6U,
                                            &request_length) == -1);
    CHECK(request_length == 0U);

    CHECK(djonehub_voice_build_call_id_request(7U, request, sizeof(request),
                                               &request_length) == 0);
    CHECK(request_length == 4U);
    CHECK(request[0] == 0x01U && request[1] == 0x01U &&
          request[2] == 0x00U && request[3] == 0x07U);
    CHECK(djonehub_voice_build_call_id_request(0U, request, sizeof(request),
                                               &request_length) == -1);
    CHECK(request_length == 0U);
    CHECK(djonehub_voice_build_call_id_request(1U, request, 3U,
                                               &request_length) == -1);
    CHECK(request_length == 0U);
    return 0;
}

static int test_action_response(void)
{
    const uint8_t response[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x01U, 0x00U, 0x05U};
    uint8_t call_id = 0U;
    int call_id_present = 0;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_action_response(
              response, sizeof(response), &call_id, &call_id_present,
              &service_error) == 0);
    CHECK(service_error == 0U);
    CHECK(call_id_present == 1);
    CHECK(call_id == 5U);
    return 0;
}

static int test_rejected_action_response(void)
{
    const uint8_t service_failure[] = {0x02U, 0x04U, 0x00U, 0x01U,
                                       0x00U, 0x2AU, 0x00U};
    const uint8_t malformed_call_id[] = {
        0x02U, 0x04U, 0x00U, 0x00U, 0x00U, 0x00U, 0x00U,
        0x10U, 0x02U, 0x00U, 0x05U, 0x06U};
    uint8_t call_id = 99U;
    int call_id_present = 1;
    unsigned int service_error = 0U;

    CHECK(djonehub_voice_parse_action_response(
              service_failure, sizeof(service_failure), &call_id,
              &call_id_present, &service_error) == 1);
    CHECK(service_error == 0x2AU);
    CHECK(call_id == 0U && call_id_present == 0);
    CHECK(djonehub_voice_parse_action_response(
              malformed_call_id, sizeof(malformed_call_id), &call_id,
              &call_id_present, &service_error) == -1);
    return 0;
}

static int test_action_policy(void)
{
    struct djonehub_voice_snapshot snapshot;

    memset(&snapshot, 0, sizeof(snapshot));
    CHECK(djonehub_voice_action_allowed(DJONEHUB_VOICE_DIAL, &snapshot,
                                        0U));
    CHECK(!djonehub_voice_action_allowed(DJONEHUB_VOICE_ANSWER, &snapshot,
                                         1U));
    CHECK(djonehub_voice_action_confirmed(DJONEHUB_VOICE_END, &snapshot,
                                          1U));

    snapshot.count = 1U;
    snapshot.calls[0].id = 7U;
    snapshot.calls[0].state = 0x02U;
    CHECK(!djonehub_voice_action_allowed(DJONEHUB_VOICE_DIAL, &snapshot,
                                         0U));
    CHECK(djonehub_voice_action_allowed(DJONEHUB_VOICE_ANSWER, &snapshot,
                                        7U));
    CHECK(djonehub_voice_action_allowed(DJONEHUB_VOICE_END, &snapshot, 7U));
    CHECK(!djonehub_voice_action_confirmed(DJONEHUB_VOICE_ANSWER, &snapshot,
                                           7U));

    snapshot.calls[0].state = 0x03U;
    CHECK(!djonehub_voice_action_allowed(DJONEHUB_VOICE_ANSWER, &snapshot,
                                         7U));
    CHECK(djonehub_voice_action_confirmed(DJONEHUB_VOICE_ANSWER, &snapshot,
                                          7U));
    CHECK(djonehub_voice_action_confirmed(DJONEHUB_VOICE_DIAL, &snapshot,
                                          7U));

    snapshot.calls[0].state = 0x09U;
    CHECK(djonehub_voice_action_allowed(DJONEHUB_VOICE_DIAL, &snapshot, 0U));
    CHECK(!djonehub_voice_action_allowed(DJONEHUB_VOICE_END, &snapshot, 7U));
    CHECK(djonehub_voice_action_confirmed(DJONEHUB_VOICE_END, &snapshot,
                                          7U));
    CHECK(!djonehub_voice_action_allowed(DJONEHUB_VOICE_STATUS, &snapshot,
                                         7U));
    return 0;
}

int main(void)
{
    CHECK(test_empty_snapshot() == 0);
    CHECK(test_call_snapshot() == 0);
    CHECK(test_malformed_snapshot() == 0);
    CHECK(test_rejected_call_records() == 0);
    CHECK(test_service_error() == 0);
    CHECK(test_request_builders() == 0);
    CHECK(test_action_response() == 0);
    CHECK(test_rejected_action_response() == 0);
    CHECK(test_action_policy() == 0);
    puts("djonehub_voice_codec_test: ok");
    return 0;
}
