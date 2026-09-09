#ifndef ASTER_SESSION_PTY_H
#define ASTER_SESSION_PTY_H
#include <sys/types.h>
// On success returns a child PID and a nonblocking, close-on-exec master FD.
// On failure returns -1, closes/reaps acquired resources, and sets errno.
// startup_stage is 1 for chdir, 2 for exec, otherwise 0 for parent failures.
pid_t session_spawn_pty(const char *cwd, const char *executable,
                       char *const argv[], char *const envp[], int *master,
                       int *startup_stage, unsigned short rows,
                       unsigned short columns);
// Returns 1 only for an authenticated local peer with this effective UID.
int session_same_user(int fd);

#endif
