#ifndef NativeAgentCTestSupport_h
#define NativeAgentCTestSupport_h

#include <sys/types.h>

int na_spawn_flock_holder(
    const char *lock_path,
    const char *acquired_path,
    const char *released_path,
    const char *release_request_path,
    double hold_seconds,
    pid_t *pid_out
);

int na_spawn_locked_append_after_hold(
    const char *lock_path,
    const char *target_path,
    const char *acquired_path,
    const char *line,
    double hold_seconds,
    pid_t *pid_out
);

int na_spawn_rem_proposal_appender(
    const char *target_path,
    int count,
    pid_t *pid_out
);

int na_spawn_mcp_consent_writer(
    const char *ledger_path,
    const char *ready_path,
    const char *ack_path,
    int count,
    pid_t *pid_out
);

int na_wait_pid(pid_t pid, double timeout_seconds, int *exit_status);
void na_terminate_pid(pid_t pid);

#endif
