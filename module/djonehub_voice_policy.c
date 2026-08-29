#include "djonehub_voice_policy.h"

#include <stddef.h>

#define QMI_VOICE_STATE_ORIGINATION 0x01U
#define QMI_VOICE_STATE_INCOMING 0x02U
#define QMI_VOICE_STATE_CONVERSATION 0x03U
#define QMI_VOICE_STATE_CC_IN_PROGRESS 0x04U
#define QMI_VOICE_STATE_ALERTING 0x05U
#define QMI_VOICE_STATE_WAITING 0x07U
#define QMI_VOICE_STATE_END 0x09U

static const struct djonehub_voice_call *find_call(
    const struct djonehub_voice_snapshot *snapshot, uint8_t call_id)
{
    size_t index;

    if (snapshot == NULL || call_id == 0U) {
        return NULL;
    }
    for (index = 0U; index < snapshot->count; ++index) {
        if (snapshot->calls[index].id == call_id) {
            return &snapshot->calls[index];
        }
    }
    return NULL;
}

static int snapshot_is_idle(const struct djonehub_voice_snapshot *snapshot)
{
    size_t index;

    if (snapshot == NULL) {
        return 0;
    }
    for (index = 0U; index < snapshot->count; ++index) {
        if (snapshot->calls[index].state != QMI_VOICE_STATE_END) {
            return 0;
        }
    }
    return 1;
}

int djonehub_voice_action_allowed(
    enum djonehub_voice_operation operation,
    const struct djonehub_voice_snapshot *snapshot, uint8_t call_id)
{
    const struct djonehub_voice_call *call;

    if (operation == DJONEHUB_VOICE_DIAL) {
        return snapshot_is_idle(snapshot);
    }
    call = find_call(snapshot, call_id);
    if (call == NULL) {
        return 0;
    }
    if (operation == DJONEHUB_VOICE_ANSWER) {
        return call->state == QMI_VOICE_STATE_INCOMING ||
               call->state == QMI_VOICE_STATE_WAITING;
    }
    if (operation == DJONEHUB_VOICE_END) {
        return call->state != QMI_VOICE_STATE_END;
    }
    return 0;
}

int djonehub_voice_action_confirmed(
    enum djonehub_voice_operation operation,
    const struct djonehub_voice_snapshot *snapshot, uint8_t call_id)
{
    const struct djonehub_voice_call *call = find_call(snapshot, call_id);

    if (operation == DJONEHUB_VOICE_END) {
        return call == NULL || call->state == QMI_VOICE_STATE_END;
    }
    if (call == NULL) {
        return 0;
    }
    if (operation == DJONEHUB_VOICE_ANSWER) {
        return call->state == QMI_VOICE_STATE_CONVERSATION;
    }
    if (operation == DJONEHUB_VOICE_DIAL) {
        return call->state == QMI_VOICE_STATE_ORIGINATION ||
               call->state == QMI_VOICE_STATE_CONVERSATION ||
               call->state == QMI_VOICE_STATE_CC_IN_PROGRESS ||
               call->state == QMI_VOICE_STATE_ALERTING;
    }
    return 0;
}
