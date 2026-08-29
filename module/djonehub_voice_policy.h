#ifndef DJONEHUB_VOICE_POLICY_H
#define DJONEHUB_VOICE_POLICY_H

#include <stdint.h>

#include "djonehub_voice_codec.h"

enum djonehub_voice_operation {
    DJONEHUB_VOICE_STATUS,
    DJONEHUB_VOICE_DIAL,
    DJONEHUB_VOICE_ANSWER,
    DJONEHUB_VOICE_END
};

int djonehub_voice_action_allowed(
    enum djonehub_voice_operation operation,
    const struct djonehub_voice_snapshot *snapshot, uint8_t call_id);

int djonehub_voice_action_confirmed(
    enum djonehub_voice_operation operation,
    const struct djonehub_voice_snapshot *snapshot, uint8_t call_id);

#endif
