#define _POSIX_C_SOURCE 200809L
/* Read-only preflight: no call mutations, numbers, keys or audio operations. */
#include "djonehub_qmi_voice_engine.h"
#include <unistd.h>
#include <time.h>

int main(void)
{
    struct djonehub_qmi_voice_result result;
    size_t i;
    struct timespec delay = {2, 0};
    djonehub_radio_start();
    (void)nanosleep(&delay, NULL);
    if (djonehub_qmi_voice_execute(DJONEHUB_VOICE_STATUS, NULL, 0, &result)
        != DJONEHUB_QMI_VOICE_SUCCESS) return 2;
    for (i = 0; i < result.snapshot.count; ++i) {
        if (result.snapshot.calls[i].state != 0x09U) return 3;
    }
    djonehub_qmi_voice_shutdown();
    djonehub_radio_stop();
    return 0;
}
