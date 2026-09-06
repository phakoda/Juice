#include "JuiceIO.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int64_t monotonic_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int JuiceWriteWithDeadline(int fd, const void *bytes, size_t length, bool socket,
                           unsigned timeout_ms, const atomic_bool *cancelled)
{
    if (fd < 0 || (!bytes && length) || !timeout_ms)
    {
        errno = EINVAL;
        return -1;
    }
    /* Darwin's MSG_DONTWAIT alone does not prevent sosendcheck from waiting
     * for socket-buffer space. Require O_NONBLOCK for sockets as well as pipes. */
    int descriptor_flags = fcntl(fd, F_GETFL);
    if (descriptor_flags < 0) return -1;
    if (!(descriptor_flags & O_NONBLOCK)) { errno = EINVAL; return -1; }
    int64_t start = monotonic_ms();
    if (start < 0) return -1;
    int64_t deadline = start + timeout_ms;
    const unsigned char *cursor = bytes;
    while (length)
    {
        if (cancelled && atomic_load_explicit(cancelled, memory_order_relaxed))
        {
            errno = ECANCELED;
            return -1;
        }
        int64_t now = monotonic_ms();
        if (now < 0) return -1;
        if (now >= deadline) { errno = ETIMEDOUT; return -1; }
        ssize_t count;
        if (socket)
        {
            int flags = 0;
#ifdef MSG_NOSIGNAL
            flags |= MSG_NOSIGNAL;
#endif
            count = send(fd, cursor, length, flags);
        }
        else count = write(fd, cursor, length);
        if (count > 0)
        {
            cursor += count;
            length -= (size_t)count;
            continue;
        }
        if (!count) { errno = EPIPE; return -1; }
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -1;

        /* Short polling slices let disconnect/launch cancellation interrupt a
         * stalled write, without a busy loop or an unbounded UIKit wait. */
        now = monotonic_ms();
        if (now < 0) return -1;
        int64_t remaining = deadline - now;
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int wait_ms = (int)(remaining < 25 ? remaining : 25);
        struct pollfd event = { .fd = fd, .events = POLLOUT };
        int result = poll(&event, 1, wait_ms);
        if (result < 0 && errno != EINTR) return -1;
        if (result > 0 && (event.revents & POLLNVAL))
        {
            errno = EBADF;
            return -1;
        }
        /* Retry the write for POLLERR/POLLHUP to obtain its real errno. */
    }
    return 0;
}
