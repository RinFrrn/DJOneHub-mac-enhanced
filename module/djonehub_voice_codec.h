#ifndef DJONEHUB_VOICE_CODEC_H
#define DJONEHUB_VOICE_CODEC_H

#include <stddef.h>
#include <stdint.h>

#define DJONEHUB_VOICE_MAX_CALLS 8U
#define DJONEHUB_VOICE_MAX_NUMBER_BYTES 81U

struct djonehub_voice_call {
    uint8_t id;
    uint8_t state;
    uint8_t type;
    uint8_t direction;
    uint8_t mode;
    uint8_t multipart;
    uint8_t als;
};

struct djonehub_voice_snapshot {
    size_t count;
    struct djonehub_voice_call calls[DJONEHUB_VOICE_MAX_CALLS];
};

/*
 * Response parsers return 0 for QMI success, 1 for a QMI service error and
 * -1 for malformed input.  service_error is set to zero on success.
 */
int djonehub_voice_parse_snapshot(const uint8_t *response,
                                  size_t response_length,
                                  struct djonehub_voice_snapshot *snapshot,
                                  unsigned int *service_error);

int djonehub_voice_parse_action_response(const uint8_t *response,
                                         size_t response_length,
                                         uint8_t *call_id,
                                         int *call_id_present,
                                         unsigned int *service_error);

/* Request builders return 0 on success and -1 for invalid input/capacity. */
int djonehub_voice_build_dial_request(const char *number, uint8_t *request,
                                      size_t request_capacity,
                                      size_t *request_length);

int djonehub_voice_build_call_id_request(uint8_t call_id, uint8_t *request,
                                         size_t request_capacity,
                                         size_t *request_length);

const char *djonehub_voice_call_state_name(uint8_t state);

#endif
