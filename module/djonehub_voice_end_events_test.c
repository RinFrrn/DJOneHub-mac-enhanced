/* Include the engine to exercise its private callback cache without a modem. */
#include "djonehub_qmi_voice_engine.c"
#include <stdio.h>
#include <assert.h>

int main(void)
{
    struct djonehub_voice_snapshot snapshot = {0};
    uint64_t first;
    snapshot.count = 1;
    snapshot.calls[0].id = 7;
    snapshot.calls[0].state = 1;
    observe_snapshot(&snapshot);
    snapshot.count = 0;
    observe_snapshot(&snapshot);
    assert(event_count == 1 && events[0].reason == 0xFFFF);
    first = events[0].sequence;
    snapshot.end_reason_count = 1;
    snapshot.end_reasons[0].call_id = 7;
    snapshot.end_reasons[0].reason = 146;
    observe_snapshot(&snapshot);
    observe_snapshot(&snapshot);
    assert(event_count == 1 && events[0].sequence == first && events[0].reason == 146);
    snapshot.count = 1;
    snapshot.calls[0].state = 3;
    observe_snapshot(&snapshot);
    assert(event_count == 1); /* Old reason cannot end the reused active ID. */
    snapshot.end_reason_count = 0;
    snapshot.count = 0;
    observe_snapshot(&snapshot);
    assert(event_count == 2 && events[1].sequence > first && events[1].reason == 0xFFFF);
    for (unsigned int i = 0; i < 30; ++i) {
        snapshot.count = 1;
        snapshot.calls[0].state = 1;
        observe_snapshot(&snapshot);
        snapshot.count = 0;
        observe_snapshot(&snapshot);
    }
    assert(event_count == DJONEHUB_VOICE_MAX_END_EVENTS);
    copy_events(&snapshot);
    assert(snapshot.event_session != 0 && snapshot.end_event_count == 16);
    puts("djonehub_voice_end_events_test: ok");
    return 0;
}
