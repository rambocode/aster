#ifndef ASTER_PROCESS_SCOPE_H
#define ASTER_PROCESS_SCOPE_H
#include <sys/types.h>
/* All APIs return 0 or an errno value. Confine to the service's reaping thread;
 * no other thread/handler may reap children, especially via waitpid(-1).
 * initialize enables Linux subreaping only in this calling process. macOS needs
 * the audit-token signal API and returns ENOTSUP when it is unavailable. */
int session_scope_initialize(void);
/* WNOWAIT preserves the direct child's PID/SID identity; status is waitpid form. */
int session_scope_observe(pid_t root, int *exited, int *status);
/* One bounded cleanup pass. Root must be our unreaped POSIX session leader.
 * Caller proves root was created with setsid (zombie SID lookup is unavailable
 * on macOS). Live roots are checked; WNOWAIT protects the retained identity.
 * Signal only its original SID; no setsid escapees or other roots are reaped.
 * complete means all owned live SID members are gone and root was reaped.
 * Call again while incomplete; TERM grace/deadline is caller-owned. */
struct session_scope_context;
int session_scope_context_create(struct session_scope_context **out);
void session_scope_context_destroy(struct session_scope_context *context);
/* Context binds one root transaction; successful TERM is sent once per process
 * identity, while newly discovered/adopted members are still scanned. */
int session_scope_context_step(struct session_scope_context *context, pid_t root, int force, int *complete, int *status);

/* Monitor a non-child process for exit. Used by adopted terminals whose
 * processes are NOT children of this service (siblings after handoff).
 * macOS: kqueue EVFILT_PROC NOTE_EXIT — exit status available.
 * Linux: pidfd_open — exit notification only, no status for non-children.
 * Returns a pollable FD (>= 0) or -1 on failure (errno set). */
int session_scope_watch_exit(pid_t pid);
/* Non-blocking check: did the watched process exit?
 * exited=1 means yes; status is waitpid-form on macOS, 0 on Linux.
 * Returns 0 on success, errno on error. The FD stays valid after exit. */
int session_scope_poll_exit(int watch_fd, int *exited, int *status);
/* Close the watcher FD. */
void session_scope_close_watch(int watch_fd);
#endif

