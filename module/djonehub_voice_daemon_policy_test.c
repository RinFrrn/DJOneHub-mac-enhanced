#include "djonehub_voice_daemon_policy.h"

#include <stdio.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__, \
                    #condition);                                                \
            return 1;                                                           \
        }                                                                       \
    } while (0)

int main(void)
{
	CHECK(djonehub_voice_daemon_operation_allowed(0, 0));
	CHECK(djonehub_voice_daemon_operation_allowed(0, 1));
	CHECK(djonehub_voice_daemon_operation_allowed(1, 1));
	CHECK(!djonehub_voice_daemon_operation_allowed(1, 0));
    CHECK(!djonehub_voice_daemon_should_stop(
        0, DJONEHUB_DAEMON_AUTHENTICATED_RESPONSE_SENT));
    CHECK(!djonehub_voice_daemon_should_stop(
        1, DJONEHUB_DAEMON_CLIENT_REJECTED));
    CHECK(djonehub_voice_daemon_should_stop(
        1, DJONEHUB_DAEMON_AUTHENTICATED_RESPONSE_SENT));
    puts("djonehub_voice_daemon_policy_test: ok");
    return 0;
}
