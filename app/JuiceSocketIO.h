#ifndef JUICE_SOCKET_IO_H
#define JUICE_SOCKET_IO_H

/* Socket-only exact I/O. MSG_DONTWAIT avoids changing the shared descriptor's
 * file status flags. A single monotonic deadline includes all short transfers,
 * EINTR retries and poll wakeups; a trickling peer cannot extend it forever.
 * Darwin callers must configure SO_NOSIGPIPE before writing. */
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <sys/socket.h>
#include <time.h>

static inline int64_t JuiceSocketNowMS(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static inline int JuiceSocketTransferUntil(int fd, void *buffer, size_t length,
                                           int writing, int64_t deadline)
{
    unsigned char *cursor = buffer;
    if (fd < 0 || (length && !buffer) || deadline < 0)
    { errno = EINVAL; return 0; }
    while (length)
    {
        int64_t now = JuiceSocketNowMS();
        if (now < 0) return 0;
        if (now >= deadline) { errno = ETIMEDOUT; return 0; }
        int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        size_t chunk = length > (size_t)SSIZE_MAX ? (size_t)SSIZE_MAX : length;
        ssize_t count = writing ? send(fd, cursor, chunk, flags)
                                : recv(fd, cursor, chunk, MSG_DONTWAIT);
        if (count > 0) { cursor += count; length -= (size_t)count; continue; }
        if (count == 0) { errno = writing ? EPIPE : ECONNRESET; return 0; }
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return 0;
        now = JuiceSocketNowMS();
        if (now < 0) return 0;
        int64_t remaining = deadline - now;
        if (remaining <= 0) { errno = ETIMEDOUT; return 0; }
        struct pollfd pending = { fd, writing ? POLLOUT : POLLIN, 0 };
        int result = poll(&pending, 1, remaining > INT_MAX ? INT_MAX : (int)remaining);
        if (result < 0 && errno != EINTR) return 0;
        if (result > 0 && (pending.revents & POLLNVAL)) { errno = EBADF; return 0; }
        /* Retry recv/send to consume buffered bytes on HUP or obtain the
         * socket's actual error. Always recheck the absolute deadline. */
    }
    return 1;
}
#endif
