#include "bridge_signals.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int wake_pipe[2] = {-1, -1};
static const int watched[] = {SIGWINCH, SIGTERM, SIGHUP, SIGINT, SIGCHLD};
static struct sigaction previous[5];
static int installed = 0;
static volatile sig_atomic_t resize_pending = 0;
static volatile sig_atomic_t stop_pending = 0;
static volatile sig_atomic_t child_pending = 0;

static void wake(int number) {
  int saved = errno;
  if (number == SIGWINCH) resize_pending = 1;
  else if (number == SIGCHLD) child_pending = 1;
  else stop_pending = number;
  const unsigned char byte = 1;
  // Pipe saturation is safe: a readable wakeup already exists and the flags
  // above preserve termination even if resize notifications fill the pipe.
  (void)write(wake_pipe[1], &byte, 1);
  errno = saved;
}

void session_bridge_signals_stop(void) {
  for (int i = installed - 1; i >= 0; --i) (void)sigaction(watched[i], &previous[i], NULL);
  installed = 0;
  if (wake_pipe[0] >= 0) close(wake_pipe[0]);
  if (wake_pipe[1] >= 0) close(wake_pipe[1]);
  wake_pipe[0] = wake_pipe[1] = -1;
  resize_pending = stop_pending = child_pending = 0;
}

int session_bridge_signals_start(void) {
  if (wake_pipe[0] >= 0) { errno = EBUSY; return -1; }
  if (pipe(wake_pipe) < 0) return -1;
  for (int i = 0; i < 2; ++i) {
    int flags = fcntl(wake_pipe[i], F_GETFL);
    if (flags < 0 || fcntl(wake_pipe[i], F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(wake_pipe[i], F_SETFD, FD_CLOEXEC) < 0) goto fail;
  }
  struct sigaction action = {0};
  action.sa_handler = wake;
  sigemptyset(&action.sa_mask);
  for (int i = 0; i < 5; ++i) sigaddset(&action.sa_mask, watched[i]);
  for (int i = 0; i < 5; ++i) {
    if (sigaction(watched[i], &action, &previous[i]) != 0) goto fail;
    installed++;
  }
  return wake_pipe[0];
fail:;
  int saved = errno;
  session_bridge_signals_stop();
  errno = saved;
  return -1;
}

int session_bridge_signals_take(void) {
  sigset_t blocked, old;
  sigemptyset(&blocked);
  for (int i = 0; i < 5; ++i) sigaddset(&blocked, watched[i]);
  if (sigprocmask(SIG_BLOCK, &blocked, &old) != 0) return -1;
  unsigned char bytes[128];
  while (read(wake_pipe[0], bytes, sizeof(bytes)) > 0) {}
  int result = stop_pending ? stop_pending : (resize_pending ? SIGWINCH : (child_pending ? SIGCHLD : 0));
  stop_pending = resize_pending = child_pending = 0;
  if (sigprocmask(SIG_SETMASK, &old, NULL) != 0) return -1;
  return result;
}
