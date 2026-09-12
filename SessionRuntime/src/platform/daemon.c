#include "daemon.h"
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <limits.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#else
#include <dirent.h>
#endif

static int close_unrelated(void) {
#ifdef __APPLE__
  int needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
  if (needed <= 0 || needed > INT_MAX - 256) return -1;
  int capacity = needed + 256;
  struct proc_fdinfo *entries = malloc((size_t)capacity);
  if (!entries) return -1;
  int length = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, entries, capacity);
  if (length <= 0 || length >= capacity || length % sizeof(*entries)) {
    free(entries); errno = EIO; return -1;
  }
  for (int i = 0; i < length / (int)sizeof(*entries); ++i)
    if (entries[i].proc_fd >= 5) close(entries[i].proc_fd);
  free(entries);
#else
  DIR *directory = opendir("/proc/self/fd");
  if (!directory) return -1;
  int *fds = NULL;
  size_t count = 0, capacity = 0;
  int scan_fd = dirfd(directory);
  struct dirent *entry;
  int error = 0;
  for (;;) {
    errno = 0;
    entry = readdir(directory);
    if (!entry) { error = errno; break; }
    if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
    char *end;
    long fd = strtol(entry->d_name, &end, 10);
    if (errno || *end || fd > INT_MAX) { error = EIO; break; }
    if (fd < 5 || fd == scan_fd) continue;
    if (count == capacity) {
      size_t next = capacity ? capacity * 2 : 16;
      if (next > (size_t)INT_MAX / sizeof(*fds)) { error = ENOMEM; break; }
      int *grown = realloc(fds, next * sizeof(*fds));
      if (!grown) { error = ENOMEM; break; }
      fds = grown;
      capacity = next;
    }
    fds[count++] = (int)fd;
  }
  closedir(directory);
  if (error) { free(fds); errno = error; return -1; }
  /* No descriptor mutations during enumeration; no unrelated threads exist. */
  for (size_t i = 0; i < count; ++i) close(fds[i]);
  free(fds);
#endif
  return 0;
}

int session_daemon_prepare(int *parent_fd, int *report_fd) {
  if (setsid() < 0) return -1;
  int parent = fcntl(*parent_fd, F_DUPFD_CLOEXEC, 5);
  if (parent < 0) return -1;
  int report = fcntl(*report_fd, F_DUPFD_CLOEXEC, 5);
  if (report < 0) { close(parent); return -1; }
  if (dup2(parent, 3) < 0 || dup2(report, 4) < 0) {
    close(parent); close(report); return -1;
  }
  *parent_fd = 3;
  *report_fd = 4;
  if (fcntl(3, F_SETFD, FD_CLOEXEC) < 0 || fcntl(4, F_SETFD, FD_CLOEXEC) < 0) return -1;
  int nullfd = open("/dev/null", O_RDWR | O_CLOEXEC);
  if (nullfd < 0) return -1;
  for (int fd = 0; fd < 3; ++fd) {
    if (dup2(nullfd, fd) < 0) return -1;
  }
  if (nullfd > 4) close(nullfd);
  return close_unrelated();
}
