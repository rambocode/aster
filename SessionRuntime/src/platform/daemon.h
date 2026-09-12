#ifndef ASTER_DAEMON_H
#define ASTER_DAEMON_H
/* Single-threaded post-fork setup. Updates retained FD numbers even on failure. */
int session_daemon_prepare(int *parent_fd, int *report_fd);
#endif
