#define _POSIX_C_SOURCE 200809L

/* Command-line wrapper around the reusable, fixed-operation QMI engine. */

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "djonehub_qmi_voice_engine.h"

static void control_write(const char *data, size_t length)
{
#if defined(__arm__)
    register long result __asm__("r0") = 2L;
    register const char *buffer __asm__("r1") = data;
    register size_t count __asm__("r2") = length;
    register long syscall_number __asm__("r7") = 4L;

    __asm__ volatile("svc 0"
                     : "+r"(result)
                     : "r"(buffer), "r"(count), "r"(syscall_number)
                     : "memory", "cc");
    (void)result;
#else
#error "djonehub_qmi_voice_control requires the ARM EABI write syscall"
#endif
}

static void control_log(const char *text)
{
    size_t length = 0U;

    while (text[length] != '\0') {
        ++length;
    }
    control_write(text, length);
}

static void control_logf(const char *format, ...)
    __attribute__((format(printf, 1, 2)));

static void control_logf(const char *format, ...)
{
    char buffer[768];
    va_list arguments;
    int length;
    size_t output_length;

    va_start(arguments, format);
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-nonliteral"
#endif
    length = vsnprintf(buffer, sizeof(buffer), format, arguments);
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    va_end(arguments);
    if (length <= 0) {
        return;
    }
    output_length = (size_t)length;
    if (output_length >= sizeof(buffer)) {
        output_length = sizeof(buffer) - 1U;
    }
    control_write(buffer, output_length);
}

static int parse_call_id(const char *text, uint8_t *call_id)
{
    char *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] == '\0' || call_id == NULL) {
        return -1;
    }
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0UL ||
        value > 255UL) {
        return -1;
    }
    *call_id = (uint8_t)value;
    return 0;
}

static int parse_operation(int argc, char **argv,
                           enum djonehub_voice_operation *operation,
                           const char **number, uint8_t *call_id)
{
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        *operation = DJONEHUB_VOICE_STATUS;
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "dial") == 0) {
        *operation = DJONEHUB_VOICE_DIAL;
        *number = argv[2];
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "answer") == 0 &&
        parse_call_id(argv[2], call_id) == 0) {
        *operation = DJONEHUB_VOICE_ANSWER;
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "end") == 0 &&
        parse_call_id(argv[2], call_id) == 0) {
        *operation = DJONEHUB_VOICE_END;
        return 0;
    }
    return -1;
}

static const char *operation_name(enum djonehub_voice_operation operation)
{
    switch (operation) {
    case DJONEHUB_VOICE_STATUS:
        return "status";
    case DJONEHUB_VOICE_DIAL:
        return "dial";
    case DJONEHUB_VOICE_ANSWER:
        return "answer";
    case DJONEHUB_VOICE_END:
        return "end";
    default:
        return "invalid";
    }
}

static void print_snapshot(const struct djonehub_voice_snapshot *snapshot)
{
    size_t index;

    control_logf("{\"ok\":true,\"operation\":\"status\","
                 "\"call_count\":%u,\"calls\":[",
                 (unsigned int)snapshot->count);
    for (index = 0U; index < snapshot->count; ++index) {
        const struct djonehub_voice_call *call = &snapshot->calls[index];

        control_logf("%s{\"id\":%u,\"state\":%u,\"state_name\":\"%s\","
                     "\"type\":%u,\"direction\":%u,\"mode\":%u}",
                     index == 0U ? "" : ",", (unsigned int)call->id,
                     (unsigned int)call->state,
                     djonehub_voice_call_state_name(call->state),
                     (unsigned int)call->type,
                     (unsigned int)call->direction,
                     (unsigned int)call->mode);
    }
    control_log("]}\n");
}

int main(int argc, char **argv)
{
    struct djonehub_qmi_voice_result result;
    enum djonehub_voice_operation operation = DJONEHUB_VOICE_STATUS;
    enum djonehub_qmi_voice_error error;
    const char *number = NULL;
    uint8_t call_id = 0U;

    if (parse_operation(argc, argv, &operation, &number, &call_id) != 0) {
        control_log("usage: djonehub-qmi-voice-control "
                    "status|dial NUMBER|answer CALL_ID|end CALL_ID\n");
        return EXIT_FAILURE;
    }
    error = djonehub_qmi_voice_execute(operation, number, call_id, &result);
    if (error != DJONEHUB_QMI_VOICE_SUCCESS) {
        control_logf("{\"ok\":false,\"operation\":\"%s\","
                     "\"error\":\"%s\",\"transport_error\":%d,"
                     "\"service_error\":%u}\n",
                     operation_name(operation),
                     djonehub_qmi_voice_error_name(error),
                     result.transport_error, result.service_error);
        return EXIT_FAILURE;
    }
    if (operation == DJONEHUB_VOICE_STATUS) {
        print_snapshot(&result.snapshot);
    } else {
        control_logf("{\"ok\":true,\"operation\":\"%s\","
                     "\"call_id\":%u,\"confirmed\":true}\n",
                     operation_name(operation),
                     (unsigned int)result.action_call_id);
    }
    return EXIT_SUCCESS;
}
