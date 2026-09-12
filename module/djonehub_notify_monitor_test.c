#define _POSIX_C_SOURCE 200809L
#define main monitor_program_main
#include "djonehub_notify_monitor.c"
#undef main
#include <assert.h>
#include <unistd.h>

static int failure;
static unsigned int reads;

enum djonehub_qmi_voice_error djonehub_qmi_voice_execute(
    enum djonehub_voice_operation operation, const char *number,
    uint8_t call_id, struct djonehub_qmi_voice_result *result)
{
    assert(operation == DJONEHUB_VOICE_STATUS && number == NULL && call_id == 0U);
    if (failure) { return DJONEHUB_QMI_VOICE_STATUS_QUERY; }
    memset(result, 0, sizeof(*result));
    result->snapshot.count = 3U;
    result->snapshot.calls[0].id = 1U;
    result->snapshot.calls[0].state = 2U;
    result->snapshot.calls[0].remote_number_present = 1U;
    result->snapshot.calls[0].remote_number_length = 12U;
    memcpy(result->snapshot.calls[0].remote_number, "+86138001380", 13U);
    result->snapshot.calls[1].id = 2U;
    result->snapshot.calls[1].state = 7U;
    result->snapshot.calls[2].id = 3U;
    result->snapshot.calls[2].state = 3U;
    return DJONEHUB_QMI_VOICE_SUCCESS;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_list(
    uint8_t storage, struct djonehub_qmi_wms_result *result)
{
    assert(storage <= 1U);
    memset(result, 0, sizeof(*result));
    result->message_count = 3U;
    result->messages[0].index = 11U; result->messages[0].tag = 0U;
    result->messages[1].index = 12U; result->messages[1].tag = 1U;
    result->messages[2].index = 13U; result->messages[2].tag = 2U;
    return DJONEHUB_QMI_WMS_SUCCESS;
}

enum djonehub_qmi_wms_error djonehub_qmi_wms_read(
    uint8_t storage, uint32_t index, struct djonehub_qmi_wms_result *result)
{
    assert(storage <= 1U && (index == 11U || index == 12U));
    ++reads;
    if (failure && index == 12U) { return DJONEHUB_QMI_WMS_TRANSPORT; }
    memset(result, 0, sizeof(*result));
    result->message.format = DJONEHUB_WMS_FORMAT_GW_PP;
    result->message.pdu_length = 3U;
    result->message.pdu[2] = (uint8_t)index;
    return DJONEHUB_QMI_WMS_SUCCESS;
}

void djonehub_qmi_voice_shutdown(void) {}
void djonehub_qmi_wms_shutdown(void) {}

static void capture(int voice, const char *expected)
{
    FILE *file = tmpfile();
    char buffer[1024];
    size_t size;
    int saved;
    assert(file != NULL);
    (void)fflush(stdout);
    saved = dup(STDOUT_FILENO);
    assert(saved >= 0 && dup2(fileno(file), STDOUT_FILENO) >= 0);
    if (voice) { calls_snapshot(); } else { sms_snapshot(1U); }
    (void)fflush(stdout);
    assert(dup2(saved, STDOUT_FILENO) >= 0);
    (void)close(saved);
    rewind(file);
    size = fread(buffer, 1U, sizeof(buffer)-1U, file);
    buffer[size] = '\0';
    assert(strcmp(buffer, expected) == 0);
    (void)fclose(file);
}

int main(void)
{
    capture(1, "{\"kind\":\"calls\",\"calls\":[1,2],\"call_numbers\":{\"1\":\"+86138001380\"}}\n");
    capture(0, "{\"kind\":\"sms\",\"storage\":1,\"pdus\":[\"00000b\",\"00000c\"]}\n");
    assert(reads == 2U);
    failure = 1;
    capture(1, "");
    capture(0, "");
    (void)puts("notification monitor tests passed");
    return 0;
}
