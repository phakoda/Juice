#ifndef JUICE_IO_H
#define JUICE_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>

/* Bounded, cancellable writes. Both sockets and pipes MUST already have
 * O_NONBLOCK set. A failed framed socket write must be followed by
 * shutdown, never another message. The caller owns the descriptor and SIGPIPE
 * policy (SO_NOSIGPIPE/MSG_NOSIGNAL for sockets; SIG_IGN for pipes). */
int JuiceWriteWithDeadline(int fd, const void *bytes, size_t length, bool socket,
                           unsigned timeout_ms, const atomic_bool *cancelled);

#endif
