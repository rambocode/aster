#include "pty_startup.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static void close_owned(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}
static int configure(int fd, int nonblocking) {
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return -1;
  if (!nonblocking) return 0;
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
int session_pty_startup_begin(struct session_pty_startup *s, const char *cwd,
    const char *executable, char *const argv[], char *const envp[],
    unsigned short rows, unsigned short columns,
    unsigned short pixel_width, unsigned short pixel_height) {
  *s = (struct session_pty_startup){.pid = -1, .master = -1, .report = -1};
  if (!rows || !columns) { s->failure = EINVAL; return -1; }
  int pipefd[2];
  if (pipe(pipefd) < 0) { s->failure = errno; return -1; }
  if (configure(pipefd[0], 1) < 0 || configure(pipefd[1], 0) < 0) {
    s->failure = errno;
    close(pipefd[0]); close(pipefd[1]); return -1;
  }
  /* Keep the report writer away from forkpty's standard-descriptor setup. */
  if (pipefd[1] <= 2) {
    int replacement = fcntl(pipefd[1], F_DUPFD_CLOEXEC, 3);
    if (replacement < 0) {
      s->failure = errno;
      close(pipefd[0]); close(pipefd[1]); return -1;
    }
    close(pipefd[1]); pipefd[1] = replacement;
  }
  struct winsize size = {.ws_row = rows, .ws_col = columns,
      .ws_xpixel = pixel_width, .ws_ypixel = pixel_height};
  s->pid = forkpty(&s->master, NULL, NULL, &size);
  if (s->pid < 0) {
    s->failure = errno;
    close(pipefd[0]); close(pipefd[1]); return -1;
  }
  if (s->pid == 0) {
    /* Parent prepares all strings. Child uses only async-signal-safe calls. */
    if (pipefd[0] > 2) close(pipefd[0]);
    int report[2];
    if (chdir(cwd) != 0) { report[0] = 1; report[1] = errno; }
    else { execve(executable, argv, envp); report[0] = 2; report[1] = errno; }
    ssize_t written;
    do { written = write(pipefd[1], report, sizeof(report)); }
    while (written < 0 && errno == EINTR);
    _exit(127);
  }
  close(pipefd[1]); s->report = pipefd[0];
  if (configure(s->master, 1) < 0) {
    s->failure = errno;
    /* Caller still owns child and descriptors on this post-fork failure. */
    return -1;
  }
  return 0;
}
int session_pty_startup_poll(struct session_pty_startup *s) {
  if (s->failure) return -1;
  if (s->report < 0) return 1;
  ssize_t count = read(s->report, s->bytes + s->received,
                       sizeof(s->bytes) - s->received);
  if (count < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
    s->failure = errno; return -1;
  }
  if (count == 0) {
    close_owned(&s->report);
    if (s->received) { s->failure = EPROTO; return -1; }
    return 1;
  }
  s->received += (size_t)count;
  if (s->received < sizeof(s->bytes)) return 0;
  int report[2]; memcpy(report, s->bytes, sizeof(report));
  if ((report[0] != 1 && report[0] != 2) || report[1] <= 0) {
    s->failure = EPROTO;
  } else { s->stage = report[0]; s->failure = report[1]; }
  close_owned(&s->report);
  return -1;
}
void session_pty_startup_cancel(struct session_pty_startup *s) {
  close_owned(&s->report);
  close_owned(&s->master);
  if (s->pid > 0) {
    (void)kill(-s->pid, SIGKILL);
    (void)kill(s->pid, SIGKILL);
  }
}
int session_pty_startup_reap(struct session_pty_startup *s, int blocking) {
  if (s->pid <= 0) return 1;
  pid_t result = waitpid(s->pid, NULL, blocking ? 0 : WNOHANG);
  if (result == 0 || (result < 0 && errno == EINTR)) return 0;
  if (result == s->pid || (result < 0 && errno == ECHILD)) {
    s->pid = -1; return 1;
  }
  return -1;
}
