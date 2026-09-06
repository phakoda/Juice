#include "../JuiceIO.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #x, errno); abort(); } } while (0)

static int64_t milliseconds(void)
{
    struct timespec t; CHECK(!clock_gettime(CLOCK_MONOTONIC, &t));
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void pause_ms(long ms)
{
    struct timespec t = { ms / 1000, (ms % 1000) * 1000000 };
    while (nanosleep(&t, &t) && errno == EINTR) {}
}
static void nonblocking(int fd);
static void sockets(int fd[2])
{
    CHECK(!socketpair(AF_UNIX, SOCK_STREAM, 0, fd));
    nonblocking(fd[0]);
#ifdef SO_NOSIGPIPE
    int one = 1;
    CHECK(!setsockopt(fd[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)));
#endif
}
static void nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL); CHECK(flags >= 0);
    CHECK(!fcntl(fd, F_SETFL, flags | O_NONBLOCK));
}
static void fill(int fd, bool socket)
{
    char bytes[4096] = {0};
    for (;;)
    {
        ssize_t n = socket ? send(fd, bytes, sizeof(bytes), 0) : write(fd, bytes, sizeof(bytes));
        if (n < 0) { CHECK(errno == EAGAIN || errno == EWOULDBLOCK); return; }
        CHECK(n > 0);
    }
}
struct reader { int fd; const unsigned char *expected; size_t length; };
static void *read_data(void *opaque)
{
    struct reader *r = opaque;
    unsigned char buffer[3071]; size_t offset = 0;
    while (offset < r->length)
    {
        size_t count = r->length - offset;
        if (count > sizeof(buffer)) count = sizeof(buffer);
        ssize_t n = read(r->fd, buffer, count);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0);
        CHECK(!memcmp(buffer, r->expected + offset, (size_t)n));
        offset += (size_t)n;
    }
    return NULL;
}
static void test_large_ordered_write(void)
{
    int fd[2]; sockets(fd);
    size_t size = 1024 * 1024;
    unsigned char *data = malloc(size); CHECK(data);
    for (size_t i = 0; i < size; ++i) data[i] = (unsigned char)(i * 13 + i / 17);
    struct reader r = {fd[1], data, size}; pthread_t thread;
    CHECK(!pthread_create(&thread, NULL, read_data, &r));
    CHECK(!JuiceWriteWithDeadline(fd[0], data, size, true, 5000, NULL));
    CHECK(!pthread_join(thread, NULL));
    CHECK(fcntl(fd[0], F_GETFL) & O_NONBLOCK);
    free(data); close(fd[0]); close(fd[1]);
}
static void test_deadlines(void)
{
    for (int socket = 0; socket <= 1; ++socket)
    {
        int fd[2];
        if (socket) sockets(fd); else { CHECK(!pipe(fd)); nonblocking(fd[1]); }
        int output = socket ? fd[0] : fd[1]; fill(output, socket);
        int64_t start = milliseconds();
        CHECK(JuiceWriteWithDeadline(output, "x", 1, socket, 80, NULL) == -1);
        CHECK(errno == ETIMEDOUT);
        CHECK(milliseconds() - start < 1500);
        close(fd[0]); close(fd[1]);
    }
}
struct cancel_task { atomic_bool *flag; };
static void *cancel_later(void *opaque)
{
    struct cancel_task *task = opaque; pause_ms(40);
    atomic_store_explicit(task->flag, true, memory_order_relaxed);
    return NULL;
}
static void test_cancel(void)
{
    int fd[2]; sockets(fd); fill(fd[0], true);
    atomic_bool flag; atomic_init(&flag, false);
    struct cancel_task task = {&flag}; pthread_t thread;
    CHECK(!pthread_create(&thread, NULL, cancel_later, &task));
    int64_t start = milliseconds();
    CHECK(JuiceWriteWithDeadline(fd[0], "x", 1, true, 5000, &flag) == -1);
    CHECK(errno == ECANCELED); CHECK(milliseconds() - start < 1500);
    CHECK(!pthread_join(thread, NULL)); close(fd[0]); close(fd[1]);
}
static void interrupted(int signal_number) { (void)signal_number; }
static void *interrupt_later(void *opaque)
{
    pthread_t *target = opaque;
    for (unsigned i = 0; i < 5; ++i) { pause_ms(10); CHECK(!pthread_kill(*target, SIGUSR1)); }
    return NULL;
}
static void test_eintr(void)
{
    struct sigaction action = {0}; action.sa_handler = interrupted;
    CHECK(!sigemptyset(&action.sa_mask)); CHECK(!sigaction(SIGUSR1, &action, NULL));
    int fd[2]; sockets(fd); fill(fd[0], true);
    pthread_t target = pthread_self(), thread;
    CHECK(!pthread_create(&thread, NULL, interrupt_later, &target));
    CHECK(JuiceWriteWithDeadline(fd[0], "x", 1, true, 120, NULL) == -1);
    CHECK(errno == ETIMEDOUT); CHECK(!pthread_join(thread, NULL));
    close(fd[0]); close(fd[1]);
}
static void test_closed_and_invalid(void)
{
    int fd[2]; sockets(fd);
    int flags = fcntl(fd[0], F_GETFL); CHECK(flags >= 0);
    CHECK(!fcntl(fd[0], F_SETFL, flags & ~O_NONBLOCK));
    CHECK(JuiceWriteWithDeadline(fd[0], "x", 1, true, 100, NULL) == -1);
    CHECK(errno == EINVAL); /* Blocking sockets are rejected too, including Darwin. */
    nonblocking(fd[0]); close(fd[1]);
    CHECK(JuiceWriteWithDeadline(fd[0], "x", 1, true, 100, NULL) == -1);
    CHECK(errno == EPIPE || errno == ECONNRESET); close(fd[0]);
    CHECK(!pipe(fd));
    CHECK(JuiceWriteWithDeadline(fd[1], "x", 1, false, 100, NULL) == -1);
    CHECK(errno == EINVAL); /* Never accept a blocking pipe by accident. */
    nonblocking(fd[1]); close(fd[0]);
    CHECK(JuiceWriteWithDeadline(fd[1], "x", 1, false, 100, NULL) == -1);
    CHECK(errno == EPIPE); close(fd[1]);
    CHECK(JuiceWriteWithDeadline(-1, "x", 1, true, 100, NULL) == -1);
    CHECK(errno == EINVAL);
}
int main(void)
{
    alarm(30);setvbuf(stdout,NULL,_IONBF,0);
    CHECK(signal(SIGPIPE, SIG_IGN) != SIG_ERR);
    puts("JUICE_IO_CASE large_ordered_write");test_large_ordered_write();
    puts("JUICE_IO_CASE deadlines");test_deadlines();
    puts("JUICE_IO_CASE cancel");test_cancel();
    puts("JUICE_IO_CASE eintr");test_eintr();
    puts("JUICE_IO_CASE closed_and_invalid");test_closed_and_invalid();
    puts("JUICE_IO_TESTS_OK cases=5 socket_and_pipe=1");
    return 0;
}
