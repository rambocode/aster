// SCM_RIGHTS helper: send/receive file descriptors over Unix domain sockets.
// Zig cannot easily construct the cmsg macros, so this thin C wrapper does
// the sendmsg/recvmsg ancillary-data dance.
#ifndef ASTER_SCM_RIGHTS_H
#define ASTER_SCM_RIGHTS_H

#include <stddef.h>

// Send file descriptors with optional inline data over a Unix socket.
// Returns 0 on success, -1 on error (errno set).
int aster_scm_send_fds(int socket_fd, const int *fds, int fd_count,
                       const void *data, size_t data_len);

// Receive file descriptors with optional inline data from a Unix socket.
// On success returns the number of received FDs (stored in fds[0..result]),
// and sets *data_len to the number of bytes actually read into data.
// Returns -1 on error (errno set).
int aster_scm_recv_fds(int socket_fd, int *fds, int max_fds,
                       void *data, size_t *data_len);

#endif // ASTER_SCM_RIGHTS_H
