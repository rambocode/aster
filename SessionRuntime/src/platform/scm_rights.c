// SCM_RIGHTS helper: sendmsg/recvmsg with ancillary file-descriptor passing.
// A thin wrapper because Zig's comptime cannot evaluate the CMSG_* macros.
#include "scm_rights.h"
#include <errno.h>
#include <string.h>
#include <sys/socket.h>

// Send `fd_count` file descriptors alongside `data_len` bytes of inline data.
int aster_scm_send_fds(int socket_fd, const int *fds, int fd_count,
                       const void *data, size_t data_len) {
    if (fd_count <= 0 || fd_count > 64) { errno = EINVAL; return -1; }

    // At least one byte of real data is required by the protocol even when
    // only ancillary FDs matter; a zero-length iov confuses some kernels.
    char dummy = 0;
    struct iovec iov = {
        .iov_base = data_len > 0 ? (void *)data : &dummy,
        .iov_len  = data_len > 0 ? data_len : 1,
    };

    // Control buffer sized for up to 64 FDs.
    union {
        char buf[CMSG_SPACE(64 * sizeof(int))];
        struct cmsghdr align;
    } control;
    memset(&control, 0, sizeof(control));

    size_t cmsg_len = CMSG_LEN((size_t)fd_count * sizeof(int));
    size_t cmsg_space = CMSG_SPACE((size_t)fd_count * sizeof(int));

    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = cmsg_space;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = cmsg_len;
    memcpy(CMSG_DATA(cmsg), fds, (size_t)fd_count * sizeof(int));

    ssize_t sent = sendmsg(socket_fd, &msg, 0);
    if (sent < 0) return -1;
    return 0;
}

// Receive up to `max_fds` file descriptors and up to `*data_len` bytes.
// On return *data_len holds actual bytes read; return value is FD count.
int aster_scm_recv_fds(int socket_fd, int *fds, int max_fds,
                       void *data, size_t *data_len) {
    if (max_fds <= 0 || max_fds > 64) { errno = EINVAL; return -1; }

    char dummy;
    size_t buf_len = (data && data_len && *data_len > 0) ? *data_len : 1;
    struct iovec iov = {
        .iov_base = (data && data_len && *data_len > 0) ? data : &dummy,
        .iov_len  = buf_len,
    };

    union {
        char buf[CMSG_SPACE(64 * sizeof(int))];
        struct cmsghdr align;
    } control;
    memset(&control, 0, sizeof(control));

    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = sizeof(control.buf);

    ssize_t received = recvmsg(socket_fd, &msg, 0);
    if (received < 0) return -1;
    if (received == 0) { errno = ECONNRESET; return -1; }

    if (data_len) *data_len = (size_t)received;

    // Walk ancillary data for SCM_RIGHTS.
    int count = 0;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
         cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS)
            continue;
        size_t payload = cmsg->cmsg_len - CMSG_LEN(0);
        int n = (int)(payload / sizeof(int));
        const int *received_fds = (const int *)CMSG_DATA(cmsg);
        for (int i = 0; i < n && count < max_fds; ++i)
            fds[count++] = received_fds[i];
    }
    return count;
}
