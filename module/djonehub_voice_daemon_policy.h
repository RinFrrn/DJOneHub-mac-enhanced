#ifndef DJONEHUB_VOICE_DAEMON_POLICY_H
#define DJONEHUB_VOICE_DAEMON_POLICY_H

enum djonehub_voice_daemon_client_outcome {
    DJONEHUB_DAEMON_CLIENT_REJECTED = 0,
    DJONEHUB_DAEMON_AUTHENTICATED_RESPONSE_SENT = 1
};

static inline int djonehub_voice_daemon_operation_allowed(int status_only,
                                                           int is_status)
{
    return status_only == 0 || is_status != 0;
}

static inline int djonehub_voice_daemon_should_stop(
    int one_shot, enum djonehub_voice_daemon_client_outcome outcome)
{
    return one_shot != 0 &&
           outcome == DJONEHUB_DAEMON_AUTHENTICATED_RESPONSE_SENT;
}

#endif
