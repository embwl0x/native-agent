#include "NativeAgentCTestSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now_seconds(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

static void sleep_seconds(double seconds) {
    if (seconds <= 0) { return; }
    struct timespec ts;
    ts.tv_sec = (time_t)seconds;
    ts.tv_nsec = (long)((seconds - (double)ts.tv_sec) * 1000000000.0);
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
}

static void mkdir_parent(const char *path) {
    char copy[PATH_MAX];
    size_t len = strnlen(path, sizeof(copy) - 1);
    if (len == 0 || len >= sizeof(copy) - 1) { return; }
    memcpy(copy, path, len);
    copy[len] = '\0';
    for (char *p = copy + 1; *p != '\0'; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(copy, 0700);
            *p = '/';
        }
    }
}

static int write_all(int fd, const char *bytes, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, bytes + off, len - off);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static int write_file(const char *path, const char *bytes) {
    if (path == NULL || path[0] == '\0') { return 0; }
    mkdir_parent(path);
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) { return -1; }
    int rc = write_all(fd, bytes, strlen(bytes));
    if (rc == 0) { fsync(fd); }
    close(fd);
    return rc;
}

static int write_time_marker(const char *path) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%.6f", now_seconds());
    return write_file(path, buf);
}

static int append_file(const char *path, const char *bytes) {
    mkdir_parent(path);
    int fd = open(path, O_CREAT | O_APPEND | O_WRONLY, 0600);
    if (fd < 0) { return -1; }
    int rc = write_all(fd, bytes, strlen(bytes));
    if (rc == 0) { fsync(fd); }
    close(fd);
    return rc;
}

static int wait_for_path(const char *path, double timeout_seconds) {
    if (path == NULL || path[0] == '\0') { return 1; }
    double deadline = now_seconds() + timeout_seconds;
    while (now_seconds() < deadline) {
        if (access(path, F_OK) == 0) { return 1; }
        sleep_seconds(0.02);
    }
    return access(path, F_OK) == 0;
}

static int open_and_lock(const char *lock_path) {
    mkdir_parent(lock_path);
    int fd = open(lock_path, O_CREAT | O_WRONLY, 0600);
    if (fd < 0) { return -1; }
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int read_file_alloc(const char *path, char **out, size_t *len_out) {
    *out = NULL;
    *len_out = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        *out = strdup("[]\n");
        *len_out = strlen(*out);
        return *out == NULL ? -1 : 0;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0) {
        close(fd);
        return -1;
    }
    size_t len = (size_t)st.st_size;
    char *buf = (char *)malloc(len + 1);
    if (buf == NULL) {
        close(fd);
        return -1;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            free(buf);
            close(fd);
            return -1;
        }
        if (n == 0) { break; }
        off += (size_t)n;
    }
    close(fd);
    buf[off] = '\0';
    *out = buf;
    *len_out = off;
    return 0;
}

static int write_mcp_record(const char *ledger_path, int index) {
    char *existing = NULL;
    size_t existing_len = 0;
    if (read_file_alloc(ledger_path, &existing, &existing_len) != 0) { return -1; }

    char object[1024];
    snprintf(
        object,
        sizeof(object),
        "  {\"argumentSummary\":\"external subprocess writer\",\"grantedAt\":\"2026-06-01T00:00:00+00:00\",\"id\":\"helper:tool.%d\",\"permissions\":[],\"revokedAt\":null,\"risk\":\"app_data_read\",\"scope\":\"server_tool\",\"serverId\":\"helper\",\"status\":\"granted\",\"toolName\":\"tool.%d\",\"updatedAt\":\"2026-06-01T00:00:00+00:00\"}",
        index,
        index
    );

    char *bracket = strchr(existing, '[');
    char *after = bracket == NULL ? existing : bracket + 1;
    while (*after == ' ' || *after == '\n' || *after == '\r' || *after == '\t') { after++; }
    int empty = (*after == ']');
    size_t needed = strlen(object) + strlen(existing) + 16;
    char *out = (char *)malloc(needed);
    if (out == NULL) {
        free(existing);
        return -1;
    }
    if (empty) {
        snprintf(out, needed, "[\n%s\n]\n", object);
    } else {
        snprintf(out, needed, "[\n%s,\n%s", object, bracket == NULL ? existing : bracket + 1);
    }

    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s.tmp-c-helper", ledger_path);
    int fd = open(tmp, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        free(out);
        free(existing);
        return -1;
    }
    int rc = write_all(fd, out, strlen(out));
    if (rc == 0) { fsync(fd); }
    close(fd);
    if (rc == 0) { rc = rename(tmp, ledger_path); }
    if (rc != 0) { unlink(tmp); }
    free(out);
    free(existing);
    return rc;
}

int na_spawn_flock_holder(
    const char *lock_path,
    const char *acquired_path,
    const char *released_path,
    const char *release_request_path,
    double hold_seconds,
    pid_t *pid_out
) {
    pid_t pid = fork();
    if (pid < 0) { return errno == 0 ? -1 : errno; }
    if (pid == 0) {
        int fd = open_and_lock(lock_path);
        if (fd < 0) { _exit(70); }
        if (write_file(acquired_path, "locked") != 0) { _exit(71); }
        if (release_request_path != NULL && release_request_path[0] != '\0') {
            wait_for_path(release_request_path, 30.0);
        } else {
            sleep_seconds(hold_seconds);
        }
        if (released_path != NULL && released_path[0] != '\0') {
            if (write_time_marker(released_path) != 0) { _exit(72); }
        }
        flock(fd, LOCK_UN);
        close(fd);
        _exit(0);
    }
    *pid_out = pid;
    return 0;
}

int na_spawn_locked_append_after_hold(
    const char *lock_path,
    const char *target_path,
    const char *acquired_path,
    const char *line,
    double hold_seconds,
    pid_t *pid_out
) {
    pid_t pid = fork();
    if (pid < 0) { return errno == 0 ? -1 : errno; }
    if (pid == 0) {
        int fd = open_and_lock(lock_path);
        if (fd < 0) { _exit(70); }
        if (write_file(acquired_path, "locked") != 0) { _exit(71); }
        sleep_seconds(hold_seconds);
        if (append_file(target_path, line) != 0) { _exit(72); }
        flock(fd, LOCK_UN);
        close(fd);
        _exit(0);
    }
    *pid_out = pid;
    return 0;
}

int na_spawn_rem_proposal_appender(
    const char *target_path,
    int count,
    pid_t *pid_out
) {
    pid_t pid = fork();
    if (pid < 0) { return errno == 0 ? -1 : errno; }
    if (pid == 0) {
        char lock_path[PATH_MAX];
        snprintf(lock_path, sizeof(lock_path), "%s.lock", target_path);
        for (int i = 0; i < count; i++) {
            int fd = open_and_lock(lock_path);
            if (fd < 0) { _exit(70); }
            char line[512];
            snprintf(
                line,
                sizeof(line),
                "{\"id\":\"helper-%d\",\"proposed_text\":\"helper write %d\",\"status\":\"pending\",\"target_doc\":\"SOUL.md\"}\n",
                i,
                i
            );
            if (append_file(target_path, line) != 0) { _exit(71); }
            flock(fd, LOCK_UN);
            close(fd);
            sleep_seconds(0.01);
        }
        _exit(0);
    }
    *pid_out = pid;
    return 0;
}

int na_spawn_mcp_consent_writer(
    const char *ledger_path,
    const char *ready_path,
    const char *ack_path,
    int count,
    pid_t *pid_out
) {
    pid_t pid = fork();
    if (pid < 0) { return errno == 0 ? -1 : errno; }
    if (pid == 0) {
        char lock_path[PATH_MAX];
        snprintf(lock_path, sizeof(lock_path), "%s.lock", ledger_path);
        for (int i = 0; i < count; i++) {
            int fd = open_and_lock(lock_path);
            if (fd < 0) { _exit(70); }
            if (i == 0) {
                if (write_file(ready_path, "ready") != 0) { _exit(71); }
                wait_for_path(ack_path, 5.0);
            }
            sleep_seconds(0.02);
            if (write_mcp_record(ledger_path, i) != 0) { _exit(72); }
            flock(fd, LOCK_UN);
            close(fd);
        }
        _exit(0);
    }
    *pid_out = pid;
    return 0;
}

int na_wait_pid(pid_t pid, double timeout_seconds, int *exit_status) {
    double deadline = now_seconds() + timeout_seconds;
    int status = 0;
    while (now_seconds() < deadline) {
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) {
            if (exit_status != NULL) {
                if (WIFEXITED(status)) {
                    *exit_status = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    *exit_status = 128 + WTERMSIG(status);
                } else {
                    *exit_status = status;
                }
            }
            return 1;
        }
        if (got < 0 && errno == ECHILD) {
            if (exit_status != NULL) { *exit_status = 0; }
            return 1;
        }
        sleep_seconds(0.05);
    }
    if (exit_status != NULL) { *exit_status = -1; }
    return 0;
}

void na_terminate_pid(pid_t pid) {
    if (pid <= 0) { return; }
    kill(pid, SIGTERM);
    int status = 0;
    if (na_wait_pid(pid, 2.0, &status) == 0) {
        kill(pid, SIGKILL);
        na_wait_pid(pid, 2.0, &status);
    }
}
