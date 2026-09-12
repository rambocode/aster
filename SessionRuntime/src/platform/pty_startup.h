#ifndef ASTER_PTY_STARTUP_H
#define ASTER_PTY_STARTUP_H
#include <stddef.h>
#include <sys/types.h>

/* Owns an unreaped direct child until transferred or cleanup completes.
 * Never reap this PID outside this object while it owns the child. */
struct session_pty_startup {
  pid_t pid;
  int master;
  int report;
  int stage;
  int failure;
  unsigned char bytes[2 * sizeof(int)];
  size_t received;
};
int session_pty_startup_begin(struct session_pty_startup *, const char *cwd,
    const char *executable, char *const argv[], char *const envp[],
    unsigned short rows, unsigned short columns,
    unsigned short pixel_width, unsigned short pixel_height);
/* 0 pending, 1 exec handshake succeeded, -1 failure; never waits. */
int session_pty_startup_poll(struct session_pty_startup *);
/* Idempotent cancellation; closes descriptors before eventual reaping. */
void session_pty_startup_cancel(struct session_pty_startup *);
/* 0 child still running, 1 ownership released, -1 unexpected wait error. */
int session_pty_startup_reap(struct session_pty_startup *, int blocking);
#endif
