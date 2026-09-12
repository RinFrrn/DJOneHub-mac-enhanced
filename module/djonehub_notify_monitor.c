#define _POSIX_C_SOURCE 200809L

/* Read-only module-local observer. stdout is a private pipe to djonehub-notify,
 * not a log. Separate Voice/WMS processes keep slow SMS scans off the call path.
 * No socket listener, AT, call mutation, SMS tag change or USB/audio operation. */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "djonehub_qmi_voice_engine.h"
#include "djonehub_qmi_wms_engine.h"

static volatile sig_atomic_t stopped;
static void stop_monitor(int sig) { (void)sig; stopped = 1; }

static void monitor_error(const char *message)
{
    ssize_t ignored = write(STDERR_FILENO, message, strlen(message));
    (void)ignored;
}

static void calls_snapshot(void)
{
    struct djonehub_qmi_voice_result result;
    size_t i;
    int comma = 0;
    if (djonehub_qmi_voice_execute(DJONEHUB_VOICE_STATUS, NULL, 0U, &result)
        != DJONEHUB_QMI_VOICE_SUCCESS) {
        monitor_error("notify: voice snapshot unavailable\n");
        return;
    }
    (void)printf("{\"kind\":\"calls\",\"calls\":[");
    for (i = 0U; i < result.snapshot.count; ++i) {
        const struct djonehub_voice_call *call = &result.snapshot.calls[i];
        if (call->state != 0x02U && call->state != 0x07U) { continue; }
        (void)printf("%s%u", comma ? "," : "", (unsigned int)call->id);
        comma = 1;
    }
    (void)printf("],\"call_numbers\":{");
    comma = 0;
    for (i = 0U; i < result.snapshot.count; ++i) {
        const struct djonehub_voice_call *call = &result.snapshot.calls[i];
        if ((call->state != 0x02U && call->state != 0x07U) ||
            call->remote_number_present == 0U ||
            call->remote_number_presentation != 0U ||
            call->remote_number_length == 0U) { continue; }
        /* voice codec accepts only digits, leading +, * and #. */
        (void)printf("%s\"%u\":\"%s\"", comma ? "," : "",
                     (unsigned int)call->id, call->remote_number);
        comma = 1;
    }
    (void)printf("}}\n");
    (void)fflush(NULL);
}

static void sms_snapshot(uint8_t storage)
{
    struct djonehub_qmi_wms_result list;
    struct djonehub_qmi_wms_result read_result;
    /* Build a complete snapshot before emitting anything. A read failure must
     * not make messages disappear and then trigger false arrivals next scan. */
    char pdus[DJONEHUB_WMS_MAX_MESSAGES][DJONEHUB_WMS_MAX_PDU_BYTES * 2U + 1U];
    size_t count = 0U;
    size_t i;
    if (djonehub_qmi_wms_list(storage, &list) != DJONEHUB_QMI_WMS_SUCCESS) {
        monitor_error("notify: SMS list unavailable\n");
        return;
    }
    for (i = 0U; i < list.message_count && !stopped; ++i) {
        size_t j;
        static const char hex[] = "0123456789abcdef";
        /* Received read/unread tags only. Never notify sent/draft messages. */
        if (list.messages[i].tag > 1U) { continue; }
        if (djonehub_qmi_wms_read(storage, list.messages[i].index, &read_result)
            != DJONEHUB_QMI_WMS_SUCCESS) {
            monitor_error("notify: SMS read unavailable\n");
            memset(pdus, 0, sizeof(pdus));
            return;
        }
        if (read_result.message.format != DJONEHUB_WMS_FORMAT_GW_PP) { continue; }
        for (j = 0U; j < read_result.message.pdu_length; ++j) {
            pdus[count][j * 2U] = hex[read_result.message.pdu[j] >> 4];
            pdus[count][j * 2U + 1U] = hex[read_result.message.pdu[j] & 15U];
        }
        pdus[count][read_result.message.pdu_length * 2U] = '\0';
        ++count;
        memset(&read_result, 0, sizeof(read_result));
    }
    if (!stopped) {
        (void)printf("{\"kind\":\"sms\",\"storage\":%u,\"pdus\":[", (unsigned int)storage);
        for (i = 0U; i < count; ++i) { (void)printf("%s\"%s\"", i ? "," : "", pdus[i]); }
        (void)printf("]}\n");
        (void)fflush(NULL);
    }
    memset(pdus, 0, sizeof(pdus));
}

int main(int argc, char **argv)
{
    int voice;
    int once;
    struct sigaction action;
    if ((argc != 2 && argc != 3) ||
        (strcmp(argv[1], "--calls") && strcmp(argv[1], "--sms")) ||
        (argc == 3 && strcmp(argv[2], "--once"))) {
        monitor_error("usage: djonehub-notify-monitor --calls|--sms [--once]\n");
        return EXIT_FAILURE;
    }
    voice = strcmp(argv[1], "--calls") == 0;
    once = argc == 3;
    memset(&action, 0, sizeof(action));
    action.sa_handler = stop_monitor;
    (void)sigemptyset(&action.sa_mask);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGINT, &action, NULL);
    while (!stopped) {
        struct timespec delay = {voice ? 1 : 10, 0};
        if (voice) { calls_snapshot(); }
        else { sms_snapshot(0U); if (!stopped) { sms_snapshot(1U); } }
        if (once) { break; }
        if (!stopped) { (void)nanosleep(&delay, NULL); }
    }
    if (voice) { djonehub_qmi_voice_shutdown(); }
    else { djonehub_qmi_wms_shutdown(); }
    return EXIT_SUCCESS;
}
