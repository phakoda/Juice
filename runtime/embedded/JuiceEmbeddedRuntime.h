#ifndef JUICE_EMBEDDED_RUNTIME_H
#define JUICE_EMBEDDED_RUNTIME_H

/* A process-local ABI. No PID in this interface is an independently killable
 * Wine process. The UIKit process owns all workers and every executable page. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JUICE_EMBEDDED_ABI 1u
#define JUICE_EMBEDDED_MAX_THREADS 256u
#define JUICE_EMBEDDED_ARENA_BYTES (384u * 1024u * 1024u)

enum JuiceRuntimeRole { JUICE_ROLE_HOST, JUICE_ROLE_SERVER, JUICE_ROLE_GUEST };
enum JuiceRuntimeEvent {
    JUICE_RUNTIME_SERVER_READY = 1, JUICE_RUNTIME_STARTED,
    JUICE_RUNTIME_EXITED, JUICE_RUNTIME_FAILED
};
typedef void (*JuiceRuntimeNotify)(void *context, int event, int code, const char *message);
typedef struct JuiceRuntimeConfiguration {
    uint32_t abi;
    uint32_t size;
    const char *runtime_root;
    const char *frameworks_root;
    const char *prefix;
    const char *working_directory;
    char *const *environment;
    int standard_fds[3];  /* duplicated, never installed over the host's 0/1/2 */
    JuiceRuntimeNotify notify;
    void *context;
} JuiceRuntimeConfiguration;
typedef int (*JuiceWineServerEntry)(int connected_fd);
typedef void (*JuiceWineClientEntry)(int argc, char **argv);

unsigned juice_runtime_abi(void);
int juice_runtime_configure(const JuiceRuntimeConfiguration *configuration);
int juice_runtime_start(JuiceWineServerEntry server, JuiceWineClientEntry client,
                        int argc, char *const argv[]);
void juice_runtime_request_stop(void);
int juice_runtime_stopping(void);
int juice_runtime_consumed(void);
void juice_runtime_server_ready(void);
void juice_runtime_mark_guest_thread_ready(void);
const char *juice_runtime_root(void);
const char *juice_runtime_frameworks(void);
int juice_runtime_client_socket(void);
int juice_runtime_standard_fd(int index);
FILE *juice_runtime_stream(int index);
ssize_t juice_runtime_read(int fd, void *buffer, size_t size);
ssize_t juice_runtime_write(int fd, const void *buffer, size_t size);
int juice_runtime_close(int fd);
int juice_runtime_dup2(int old_fd, int new_fd);
mode_t juice_runtime_umask(mode_t mask);
int juice_runtime_is_guest_thread(void);

/* Called on a non-UIKit worker, only after a real external debugger attaches.
 * mode=0 uses debug-authorized RX mmap; mode=1 uses universal.js PREPARE_REGION.
 * Readiness includes a dual-alias write and executable-code round-trip probe. */
int juice_runtime_prepare_jit(int universal_protocol);
int juice_runtime_jit_ready(void);
int juice_runtime_jit_allocate(void **writable, void **executable, size_t size);
int juice_runtime_jit_free(void *writable, void *executable, size_t size);
int juice_runtime_jit_seal(void);

/* Component-scoped POSIX boundary. These are compile-time substitutions in
 * Wine only, not dyld interposing on UIKit, Foundation, or the application. */
extern char **juice_runtime_environ;
char *juice_runtime_getenv(const char *name);
int juice_runtime_setenv(const char *name, const char *value, int overwrite);
int juice_runtime_unsetenv(const char *name);
int juice_runtime_putenv(char *entry);
int juice_runtime_chdir(const char *path);
int juice_runtime_fchdir(int fd);
int juice_runtime_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int juice_runtime_send_thread_signal(unsigned long native_thread, int signal_number);
int juice_runtime_sigaction(int, const struct sigaction *, struct sigaction *);
void (*juice_runtime_signal(int, void (*)(int)))(int);
int juice_runtime_kill(pid_t, int);
int juice_runtime_raise(int);
pid_t juice_runtime_fork(void);
int juice_runtime_execve(const char *, char *const [], char *const []);
int juice_runtime_execv(const char *, char *const []);
int juice_runtime_posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
                              const posix_spawnattr_t *, char *const [], char *const []);
int juice_runtime_atexit(void (*function)(void));
__attribute__((noreturn)) void juice_runtime_exit(int);
__attribute__((noreturn)) void juice_runtime_abort(void);
__attribute__((noreturn)) void juice_runtime_assert(const char *, const char *, int, const char *);
void *juice_runtime_dlopen(const char *, int);
void *juice_runtime_mmap(void *, size_t, int, int, int, off_t);
int juice_runtime_munmap(void *, size_t);
int juice_runtime_mprotect(void *, size_t, int);
int juice_runtime_copy_guest(void *destination, const void *source, size_t size, int write_guest);

#ifdef __cplusplus
}
#endif
#endif
