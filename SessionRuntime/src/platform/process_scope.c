#include "process_scope.h"
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
/* Apple xnu proc_info_private.h ABI; size is asserted before using flavor 17. */
struct scope_unique { uint8_t uuid[16]; uint64_t unique, parent; int32_t version, original_parent_version; uint64_t r2, r3; };
_Static_assert(sizeof(struct scope_unique) == 56, "proc identity ABI");
static int (*scope_signal)(audit_token_t *, int);
#else
#include <dirent.h>
#include <stdio.h>
#include <sys/prctl.h>
#endif
static pid_t initialized_owner;
int session_scope_initialize(void) {
#if defined(__APPLE__)
    scope_signal = (int (*)(audit_token_t *, int))dlsym(RTLD_DEFAULT, "proc_signal_with_audittoken");
    if (!scope_signal) return ENOTSUP;
#else
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)) return errno;
#endif
    initialized_owner = getpid();
    return 0;
}
int session_scope_observe(pid_t root, int *exited, int *status) {
    if (root <= 0 || !exited || !status) return EINVAL;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)root, &info, WEXITED | WNOHANG | WNOWAIT)) return errno;
    *exited = info.si_pid != 0;
    if (*exited) {
        if (info.si_code == CLD_EXITED) *status = info.si_status << 8;
        else if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED)
            *status = info.si_status | (info.si_code == CLD_DUMPED ? 0x80 : 0);
        else return EPROTO;
    }
    return 0;
}
#if !defined(__APPLE__)
/* Direct children cannot have their PID recycled while this single owner has
 * not reaped them. Parent verification precedes SID checks and kill/waitpid. */
static int direct_child(pid_t pid) {
    char path[64], buffer[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE *file = fopen(path, "r");
    if (!file) return errno == ENOENT ? 0 : -errno;
    size_t count = fread(buffer, 1, sizeof(buffer)-1, file);
    int failed = ferror(file);
    fclose(file);
    if (failed) return -EIO;
    buffer[count] = 0;
    char *tail = strrchr(buffer, ')');
    char state; int parent;
    if (!tail || sscanf(tail + 1, " %c %d", &state, &parent) != 2) return -EPROTO;
    return parent == getpid();
}
#endif
struct scope_member { pid_t pid; uint64_t identity; };
struct session_scope_context {
    pid_t root;
    int complete;
    size_t count, capacity;
    struct scope_member *members;
};
int session_scope_context_create(struct session_scope_context **out) {
    if (!out) return EINVAL;
    *out = calloc(1, sizeof(**out));
    return *out ? 0 : ENOMEM;
}
void session_scope_context_destroy(struct session_scope_context *context) {
    if (!context) return;
    free(context->members);
    free(context);
}
static int member_seen(struct session_scope_context *context, pid_t pid, uint64_t identity) {
    for (size_t i=0; i<context->count; ++i)
        if (context->members[i].pid == pid && context->members[i].identity == identity) return 1;
    return 0;
}
/* Reserve before signaling, so recording an accepted TERM cannot fail. */
static int member_reserve(struct session_scope_context *context) {
    if (context->count < context->capacity) return 0;
    if (context->capacity >= 65536) return EOVERFLOW;
    size_t capacity = context->capacity ? context->capacity * 2 : 64;
    void *members = realloc(context->members, capacity * sizeof(*context->members));
    if (!members) return ENOMEM;
    context->members = members;
    context->capacity = capacity;
    return 0;
}
#if !defined(__APPLE__)
static void member_reaped(struct session_scope_context *context, pid_t pid) {
    for (size_t i=0; i<context->count; ++i) if (context->members[i].pid == pid) {
        context->members[i] = context->members[--context->count];
        return;
    }
}
#endif
int session_scope_context_step(struct session_scope_context *context, pid_t root, int force, int *complete, int *status) {
    if (initialized_owner != getpid()) return ENOTSUP;
    if (!context || !complete || !status || root <= 0 || (force != 0 && force != 1)) return EINVAL;
    if (context->complete || (context->root && context->root != root)) return EINVAL;
    context->root = root;
    *complete = 0;
    int root_exited = 0, result = session_scope_observe(root, &root_exited, status);
    if (result) return result;
    /* Root is still an unreaped child, preventing reuse of its numeric SID. */
    if (!root_exited) {
        pid_t root_sid = getsid(root);
        if (root_sid != root) {
            int failure = root_sid < 0 ? errno : EINVAL;
            if (failure != ESRCH) return failure;
            /* macOS can revoke SID visibility while root exit is still waiting
             * for PTY output to drain. Keep WNOWAIT ownership and let the owner
             * drain; never treat this transition as a completed cleanup pass. */
            result = session_scope_observe(root, &root_exited, status);
            if (result) return result;
            if (!root_exited) return 0;
        }
    }
    const int signum = force ? SIGKILL : SIGTERM;
    unsigned live = 0;
    unsigned reaped = 0;
#if defined(__APPLE__)
    const int capacity = 65536;
    pid_t *pids = malloc((size_t)capacity * sizeof(pid_t));
    if (!pids) return ENOMEM;
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity * (int)sizeof(pid_t));
    if (count <= 0 || count >= capacity * (int)sizeof(pid_t)) { free(pids); return count <= 0 ? EIO : EOVERFLOW; }
    for (int i = 0; i < count / (int)sizeof(pid_t); ++i) {
        pid_t pid = pids[i];
        if (pid <= 0 || (pid == root && root_exited)) continue;
        struct scope_unique identity;
        errno = 0;
        int size = proc_pidinfo(pid, 17, 0, &identity, sizeof(identity));
        if (size != sizeof(identity)) {
            int failure = errno ? errno : EIO;
            if (failure == ESRCH || failure == ENOENT) {
                if (getsid(pid) == root) ++live;
                continue;
            }
            /* Read-only classification after identity failure never authorizes
             * signaling; same-SID permission/ABI failures must fail closed. */
            if (getsid(pid) == root) { result = failure; break; }
            continue;
        }
        /* Capture version BEFORE SID classification. Reuse after this point
         * makes token signaling fail with ESRCH rather than target a successor. */
        if (getsid(pid) != root) continue;
        struct proc_bsdinfo info;
        errno = 0;
        size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        if (size != sizeof(info)) {
            int failure = errno ? errno : EIO;
            if (failure == ESRCH || failure == ENOENT) { ++live; continue; }
            result = failure;
            break;
        }
        if (info.pbi_status == 5) continue; /* SZOMB: no live resources to signal. */
        audit_token_t token = {{0}};
        token.val[5] = (unsigned)pid;
        token.val[7] = (unsigned)identity.version;
        ++live;
        if (!force && member_seen(context, pid, identity.unique)) continue;
        if (!force && (result = member_reserve(context))) break;
        result = scope_signal(&token, signum);
        if (result == ESRCH) { result = 0; continue; }
        if (result) break;
        if (!force) context->members[context->count++] = (struct scope_member){pid, identity.unique};
    }
    free(pids);
#else
    DIR *directory = opendir("/proc");
    if (!directory) return errno;
    struct dirent *entry;
    unsigned visited = 0;
    for (;;) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { result = errno; break; }
        if (++visited > 100000) { result = EOVERFLOW; break; }
        char *end; long value = strtol(entry->d_name, &end, 10);
        if (*end || value <= 0 || value > INT32_MAX) continue;
        pid_t pid = (pid_t)value;
        int child = direct_child(pid);
        if (child < 0) { result = -child; break; }
        if (!child || getsid(pid) != root) continue;
        int exited = 0, child_status = 0;
        result = session_scope_observe(pid, &exited, &child_status);
        if (result) break;
        if (exited) {
            if (pid != root) {
                if (waitpid(pid, NULL, WNOHANG) != pid) { result = errno ? errno : ECHILD; break; }
                member_reaped(context, pid);
                ++reaped;
            }
            continue;
        }
        ++live;
        /* PID is a stable lifetime key while this direct child is unreaped.
         * Remove its key only when this context performs the matching waitpid. */
        if (!force && member_seen(context, pid, 0)) continue;
        if (!force && (result = member_reserve(context))) break;
        if (kill(pid, signum)) {
            if (errno == ESRCH) continue;
            result = errno; break;
        }
        if (!force) context->members[context->count++] = (struct scope_member){pid, 0};
    }
    closedir(directory);
#endif
    if (result) return result;
    if (root_exited && live == 0 && reaped == 0) {
        if (waitpid(root, status, WNOHANG) != root) return errno ? errno : ECHILD;
        context->complete = 1;
        *complete = 1;
    }
    return 0;
}

/* ─── Non-child process exit monitoring ─────────────────────────────────── */

#if defined(__APPLE__)
#include <sys/event.h>

int session_scope_watch_exit(pid_t pid) {
    /* Create a kqueue and register EVFILT_PROC NOTE_EXIT for the target PID.
     * Works for any visible process, not just children. */
    if (pid <= 0) { errno = EINVAL; return -1; }
    int kq = kqueue();
    if (kq < 0) return -1;
    struct kevent change;
    EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(kq, &change, 1, NULL, 0, NULL) < 0) {
        int saved = errno;
        close(kq);
        errno = saved;
        return -1;
    }
    return kq;
}

int session_scope_poll_exit(int watch_fd, int *exited, int *status) {
    /* Non-blocking kevent check. NOTE_EXIT fires when the process exits,
     * but event.data is NOT a reliable exit status for non-child processes:
     * macOS returns 0 regardless of the actual exit code. Use -1 to signal
     * "exit detected but status unavailable". */
    if (watch_fd < 0 || !exited || !status) return EINVAL;
    *exited = 0;
    struct kevent event;
    struct timespec zero = {0, 0};
    int n = kevent(watch_fd, NULL, 0, &event, 1, &zero);
    if (n < 0) return errno;
    if (n > 0 && (event.fflags & NOTE_EXIT)) {
        *exited = 1;
        /* Non-child: exit code unavailable via kqueue. Signal with -1. */
        *status = -1;
    }
    return 0;
}

void session_scope_close_watch(int watch_fd) {
    if (watch_fd >= 0) close(watch_fd);
}

#else /* Linux */
#include <sys/syscall.h>
#include <poll.h>

int session_scope_watch_exit(pid_t pid) {
    /* pidfd_open: returns a file descriptor that becomes readable when
     * the target process exits. Works for any visible process. */
    if (pid <= 0) { errno = EINVAL; return -1; }
#ifdef SYS_pidfd_open
    int fd = (int)syscall(SYS_pidfd_open, pid, 0);
    return fd; /* -1 on failure, errno set by kernel */
#else
    errno = ENOSYS;
    return -1;
#endif
}

int session_scope_poll_exit(int watch_fd, int *exited, int *status) {
    /* Poll the pidfd with zero timeout. POLLIN means process exited.
     * Exit status is NOT available for non-child processes on Linux. */
    if (watch_fd < 0 || !exited || !status) return EINVAL;
    *exited = 0;
    struct pollfd pfd = { .fd = watch_fd, .events = POLLIN, .revents = 0 };
    int n = poll(&pfd, 1, 0);
    if (n < 0) return errno;
    if (n > 0 && (pfd.revents & POLLIN)) {
        *exited = 1;
        *status = -1; /* 接管后两平台均无法获取非子进程的退出码 */
    }
    return 0;
}

void session_scope_close_watch(int watch_fd) {
    if (watch_fd >= 0) close(watch_fd);
}

#endif
