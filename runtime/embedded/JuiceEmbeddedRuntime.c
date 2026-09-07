#define _DARWIN_C_SOURCE 1
#include "JuiceEmbeddedRuntime.h"
#include "JuiceEmbeddedPolicy.h"
#include <stdatomic.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#ifdef __APPLE__
#include <mach/mach.h>
extern int pthread_chdir_np(const char *);
extern int pthread_fchdir_np(int);
#endif

#define ENV_LIMIT 512u
#define ENV_STORAGE_LIMIT (1024u * 1024u)
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t state_changed = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t env_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t signal_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int configured, consumed, stopping, server_ready;
static int runtime_exit_code, live_threads;
static char *root_path, *frameworks_path, *prefix_path, *working_path;
static int standard_fds[3] = {-1, -1, -1};
static FILE *standard_streams[3];
static int transport[2] = {-1, -1};
static JuiceRuntimeNotify notify;
static void *notify_context;
static char *environment[ENV_LIMIT + 1];
char **juice_runtime_environ = environment;
static size_t environment_count, environment_bytes;
/* Superseded environment values stay valid for readers. The total lifetime
 * allocation is bounded; runtime environment changes never reach libc environ. */
static char *environment_storage[4096];
static size_t environment_storage_count;
static _Thread_local int role;
static _Thread_local volatile sig_atomic_t guest_thread_ready;
struct owned_thread { pthread_t thread; unsigned long native_id; int role, occupied, ready; };
static struct owned_thread threads[JUICE_EMBEDDED_MAX_THREADS];
static struct sigaction previous_signals[NSIG];
static _Atomic(struct sigaction *) guest_signals[NSIG];
static unsigned signal_action_count;
static unsigned char installed_signals[NSIG];
static _Atomic unsigned private_umask = 0077;

static void report(int event, int code, const char *message)
{
    if (notify) notify(notify_context, event, code, message);
}
unsigned juice_runtime_abi(void) { return JUICE_EMBEDDED_ABI; }
const char *juice_runtime_root(void) { return root_path; }
const char *juice_runtime_frameworks(void) { return frameworks_path; }
int juice_runtime_client_socket(void) { return transport[0]; }
int juice_runtime_standard_fd(int index) { return index >= 0 && index < 3 ? standard_fds[index] : -1; }
FILE *juice_runtime_stream(int index)
{
    return index >= 0 && index < 3 && standard_streams[index] ? standard_streams[index] : stderr;
}
int juice_runtime_stopping(void) { return atomic_load(&stopping); }
int juice_runtime_consumed(void) { return atomic_load(&consumed); }
void juice_runtime_request_stop(void) { atomic_store(&stopping, 1); }
int juice_runtime_is_guest_thread(void) { return role == JUICE_ROLE_GUEST; }
ssize_t juice_runtime_read(int fd, void *buffer, size_t size)
{
    return read(fd >= 0 && fd < 3 ? standard_fds[fd] : fd, buffer, size);
}
ssize_t juice_runtime_write(int fd, const void *buffer, size_t size)
{
    return write(fd >= 0 && fd < 3 ? standard_fds[fd] : fd, buffer, size);
}
int juice_runtime_close(int fd)
{
    /* Wine's numeric standard descriptors are logical handles, never ownership
     * of UIKit's actual 0/1/2. The runtime closes its private copies at teardown. */
    if (fd >= 0 && fd < 3) return 0;
    return close(fd);
}
int juice_runtime_dup2(int old_fd, int new_fd)
{
    if (new_fd >= 0 && new_fd < 3) { errno = EPERM; return -1; }
    return dup2(old_fd >= 0 && old_fd < 3 ? standard_fds[old_fd] : old_fd, new_fd);
}
mode_t juice_runtime_umask(mode_t mask)
{
    return (mode_t)atomic_exchange(&private_umask, (unsigned)mask & 0777u);
}

static int environment_name_valid(const char *name)
{
    size_t n = name ? strnlen(name, 256) : 0;
    return n && n < 256 && !strchr(name, '=');
}
char *juice_runtime_getenv(const char *name)
{
    char *result = NULL;
    if (!environment_name_valid(name)) return NULL;
    size_t n = strlen(name);
    pthread_mutex_lock(&env_lock);
    for (size_t i = 0; i < environment_count; ++i)
        if (!strncmp(environment[i], name, n) && environment[i][n] == '=') {
            result = environment[i] + n + 1;
            break;
        }
    pthread_mutex_unlock(&env_lock);
    return result;
}
int juice_runtime_setenv(const char *name, const char *value, int overwrite)
{
    if (!environment_name_valid(name) || !value || strnlen(value, 65537) > 65536) { errno = EINVAL; return -1; }
    size_t n = strlen(name), len = n + strlen(value) + 2, i;
    pthread_mutex_lock(&env_lock);
    for (i = 0; i < environment_count; ++i)
        if (!strncmp(environment[i], name, n) && environment[i][n] == '=') break;
    if (i < environment_count && !overwrite) { pthread_mutex_unlock(&env_lock); return 0; }
    if (i >= ENV_LIMIT || environment_storage_count >= 4096 || len > ENV_STORAGE_LIMIT - environment_bytes) {
        pthread_mutex_unlock(&env_lock); errno = E2BIG; return -1;
    }
    char *entry = malloc(len);
    if (!entry) { pthread_mutex_unlock(&env_lock); return -1; }
    memcpy(entry, name, n); entry[n] = '='; strcpy(entry + n + 1, value);
    environment_storage[environment_storage_count++] = entry;
    environment_bytes += len;
    environment[i] = entry;
    if (i == environment_count) environment[++environment_count] = NULL;
    pthread_mutex_unlock(&env_lock);
    return 0;
}
int juice_runtime_unsetenv(const char *name)
{
    if (!environment_name_valid(name)) { errno = EINVAL; return -1; }
    size_t n = strlen(name);
    pthread_mutex_lock(&env_lock);
    for (size_t i = 0; i < environment_count; ++i)
        if (!strncmp(environment[i], name, n) && environment[i][n] == '=') {
            memmove(environment + i, environment + i + 1, (environment_count - i) * sizeof(char *));
            --environment_count; break;
        }
    pthread_mutex_unlock(&env_lock);
    return 0;
}
int juice_runtime_putenv(char *entry)
{
    if (!entry) { errno = EINVAL; return -1; }
    const char *equals = strchr(entry, '=');
    if (!equals) return juice_runtime_unsetenv(entry);
    size_t n = (size_t)(equals - entry);
    if (!n || n > 255) { errno = EINVAL; return -1; }
    char name[256]; memcpy(name, entry, n); name[n] = 0;
    return juice_runtime_setenv(name, equals + 1, 1);
}

static char *existing_directory(const char *path)
{
    struct stat st;
    if (!path || path[0] != '/' || strnlen(path, PATH_MAX) == PATH_MAX ||
        stat(path, &st) || !S_ISDIR(st.st_mode)) return NULL;
    return realpath(path, NULL);
}
int juice_runtime_configure(const JuiceRuntimeConfiguration *c)
{
    if (!c || c->abi != JUICE_EMBEDDED_ABI || c->size != sizeof(*c)) return EINVAL;
    pthread_mutex_lock(&state_lock);
    if (atomic_load(&configured) || atomic_load(&consumed)) { pthread_mutex_unlock(&state_lock); return EALREADY; }
    char *paths[4] = {existing_directory(c->runtime_root), existing_directory(c->frameworks_root),
                      existing_directory(c->prefix), existing_directory(c->working_directory)};
    int fds[3] = {-1, -1, -1}, sockets[2] = {-1, -1}, error = 0;
    FILE *streams[3] = {NULL, NULL, NULL};
    for (int i = 0; i < 4; ++i) if (!paths[i]) error = EINVAL;
    if (!c->environment) error = EINVAL;
    for (int i = 0; !error && i < 3; ++i) {
        if (c->standard_fds[i] < 0 || (fds[i] = dup(c->standard_fds[i])) < 0) { error = errno ?: EBADF; break; }
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
#ifdef F_SETNOSIGPIPE
        fcntl(fds[i], F_SETNOSIGPIPE, 1);
#endif
        int stream_fd = dup(fds[i]);
        if (stream_fd < 0) { error = errno; break; }
        streams[i] = fdopen(stream_fd, i ? "w" : "r");
        if (!streams[i]) { error = errno; close(stream_fd); break; }
        setvbuf(streams[i], NULL, _IONBF, 0);
    }
    if (!error && socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) error = errno;
    char *original_environment[ENV_LIMIT + 1];
    size_t original_count;
    pthread_mutex_lock(&env_lock);
    memcpy(original_environment, environment, sizeof(environment));
    original_count = environment_count;
    pthread_mutex_unlock(&env_lock);
    if (!error) {
        for (size_t i = 0; c->environment[i]; ++i) {
            if (i >= ENV_LIMIT - 8 || juice_runtime_putenv(c->environment[i])) { error = E2BIG; break; }
        }
    }
    if (error) {
        pthread_mutex_lock(&env_lock);
        memcpy(environment, original_environment, sizeof(environment));
        environment_count = original_count;
        pthread_mutex_unlock(&env_lock);
        for (int i = 0; i < 4; ++i) free(paths[i]);
        for (int i = 0; i < 3; ++i) { if (fds[i] >= 0) close(fds[i]); if (streams[i]) fclose(streams[i]); }
        for (int i = 0; i < 2; ++i) if (sockets[i] >= 0) close(sockets[i]);
        pthread_mutex_unlock(&state_lock);
        return error;
    }
    root_path = paths[0]; frameworks_path = paths[1]; prefix_path = paths[2]; working_path = paths[3];
    memcpy(standard_fds, fds, sizeof(fds)); memcpy(standard_streams, streams, sizeof(streams));
    memcpy(transport, sockets, sizeof(sockets));
    for (int i = 0; i < 2; ++i) {
        fcntl(transport[i], F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
        int one = 1; setsockopt(transport[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    }
    notify = c->notify; notify_context = c->context;
    atomic_store(&configured, 1);
    pthread_mutex_unlock(&state_lock);
    return 0;
}

int juice_runtime_chdir(const char *path)
{
    if (!role || !path) { errno = EPERM; return -1; }
#ifdef __APPLE__
    return pthread_chdir_np(path);
#else
    (void)path; errno = ENOTSUP; return -1;
#endif
}
int juice_runtime_fchdir(int fd)
{
    if (!role || fd < 0) { errno = EPERM; return -1; }
#ifdef __APPLE__
    return pthread_fchdir_np(fd);
#else
    (void)fd; errno = ENOTSUP; return -1;
#endif
}

struct launch_thread {
    void *(*function)(void *);
    void *argument;
    int role, cwd;
    size_t slot;
};
static void thread_finished(void *slot_pointer)
{
    size_t slot = (size_t)(uintptr_t)slot_pointer;
    int done, code;
    pthread_mutex_lock(&state_lock);
    threads[slot].occupied = 0;
    done = --live_threads == 0 && atomic_load(&consumed);
    code = runtime_exit_code;
    pthread_cond_broadcast(&state_changed);
    pthread_mutex_unlock(&state_lock);
    role = JUICE_ROLE_HOST;
    guest_thread_ready = 0;
    if (done) report(code ? JUICE_RUNTIME_FAILED : JUICE_RUNTIME_EXITED, code,
                     "Runtime stopped. Reopen Juice before starting another guest session.");
}
static void *thread_entry(void *opaque)
{
    struct launch_thread request = *(struct launch_thread *)opaque;
    free(opaque);
    role = request.role;
    size_t slot = request.slot;
    pthread_mutex_lock(&state_lock);
    threads[slot] = (struct owned_thread){.thread=pthread_self(), .role=role, .occupied=1};
#ifdef __APPLE__
    threads[slot].native_id = pthread_mach_thread_np(pthread_self());
#else
    threads[slot].native_id = (unsigned long)(uintptr_t)pthread_self();
#endif
    pthread_mutex_unlock(&state_lock);
    void *result = NULL;
    pthread_cleanup_push(thread_finished, (void *)(uintptr_t)slot);
    int cwd_error = request.cwd >= 0 ? juice_runtime_fchdir(request.cwd) :
        juice_runtime_chdir(role == JUICE_ROLE_SERVER ? prefix_path : working_path);
    if (request.cwd >= 0) close(request.cwd);
    if (cwd_error) juice_runtime_exit(errno ?: EIO);
    if (!juice_runtime_stopping()) result = request.function(request.argument);
    pthread_cleanup_pop(1);
    return result;
}
static int create_owned_thread(pthread_t *thread, const pthread_attr_t *attr,
                              void *(*function)(void *), void *argument, int new_role, int inherit_cwd)
{
    if (!thread || !function || (new_role != JUICE_ROLE_GUEST && new_role != JUICE_ROLE_SERVER)) return EINVAL;
    if (juice_runtime_stopping()) return ECANCELED;
    struct launch_thread *request = calloc(1, sizeof(*request));
    if (!request) return ENOMEM;
    request->function = function; request->argument = argument; request->role = new_role;
    request->cwd = inherit_cwd ? open(".", O_RDONLY | O_CLOEXEC) : -1;
    if (inherit_cwd && request->cwd < 0) { int error = errno; free(request); return error; }
    pthread_mutex_lock(&state_lock);
    size_t slot;
    for (slot = 0; slot < JUICE_EMBEDDED_MAX_THREADS && threads[slot].occupied; ++slot) {}
    if (slot == JUICE_EMBEDDED_MAX_THREADS || juice_runtime_stopping()) {
        pthread_mutex_unlock(&state_lock);
        if (request->cwd >= 0) close(request->cwd);
        free(request); return EAGAIN;
    }
    /* Reserve before pthread_create: unscheduled workers count against the
     * same bound and cannot race to overcommit the thread table. */
    threads[slot] = (struct owned_thread){.role=new_role, .occupied=2};
    ++live_threads; request->slot = slot;
    pthread_mutex_unlock(&state_lock);
    int error = pthread_create(thread, attr, thread_entry, request);
    if (error) {
        pthread_mutex_lock(&state_lock);
        threads[slot].occupied = 0; --live_threads;
        pthread_mutex_unlock(&state_lock);
        if (request->cwd >= 0) close(request->cwd); free(request);
    }
    return error;
}
int juice_runtime_pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*f)(void *), void *p)
{
    return create_owned_thread(t, a, f, p, role, 1);
}
void juice_runtime_mark_guest_thread_ready(void)
{
    if (role != JUICE_ROLE_GUEST) return;
    guest_thread_ready = 1;
    pthread_mutex_lock(&state_lock);
    for (size_t i = 0; i < JUICE_EMBEDDED_MAX_THREADS; ++i)
        if (threads[i].occupied == 1 && pthread_equal(threads[i].thread, pthread_self())) threads[i].ready = 1;
    pthread_mutex_unlock(&state_lock);
}
int juice_runtime_send_thread_signal(unsigned long id, int sig)
{
    if (sig != SIGQUIT && sig != SIGUSR1 && sig != SIGUSR2 && sig != SIGINT) return 0;
    int success = 0;
    pthread_mutex_lock(&state_lock);
    for (size_t i = 0; i < JUICE_EMBEDDED_MAX_THREADS; ++i)
        if (threads[i].occupied == 1 && threads[i].role == JUICE_ROLE_GUEST && threads[i].ready &&
            threads[i].native_id == id && !pthread_equal(threads[i].thread, pthread_self())) {
            success = !pthread_kill(threads[i].thread, sig); break;
        }
    pthread_mutex_unlock(&state_lock);
    return success;
}
void juice_runtime_server_ready(void)
{
    pthread_mutex_lock(&state_lock);
    atomic_store(&server_ready, 1);
    pthread_cond_broadcast(&state_changed);
    pthread_mutex_unlock(&state_lock);
    report(JUICE_RUNTIME_SERVER_READY, 0, "Wine server ready on an in-process socketpair.");
}

static JuiceWineServerEntry server_entry;
static JuiceWineClientEntry client_entry;
static int client_argc;
static char **client_argv;
static void *run_server(void *unused)
{
    (void)unused;
    int result = server_entry(transport[1]);
    if (result) juice_runtime_exit(result);
    return NULL;
}
static void *run_client(void *unused)
{
    (void)unused;
    report(JUICE_RUNTIME_STARTED, 0, "Wine guest executing in the Juice application process.");
    client_entry(client_argc, client_argv);
    juice_runtime_exit(0);
}
int juice_runtime_start(JuiceWineServerEntry server, JuiceWineClientEntry client, int argc, char *const argv[])
{
    if (!atomic_load(&configured) || !juice_runtime_jit_ready() || !server || !client ||
        argc < 2 || argc > 256 || !argv || argv[argc]) return EINVAL;
    if (juice_runtime_consumed()) return EALREADY;
    char **arguments = calloc((size_t)argc + 1, sizeof(char *));
    if (!arguments) return ENOMEM;
    for (int i = 0; i < argc; ++i) {
        if (!argv[i] || strnlen(argv[i], 65537) > 65536 || !(arguments[i] = strdup(argv[i]))) {
            for (int j = 0; j < i; ++j) free(arguments[j]);
            free(arguments); return EINVAL;
        }
    }
    int expected = 0;
    if (!atomic_compare_exchange_strong(&consumed, &expected, 1)) {
        for (int i = 0; i < argc; ++i) free(arguments[i]); free(arguments); return EALREADY;
    }
    server_entry = server; client_entry = client; client_argc = argc; client_argv = arguments;
    pthread_t server_thread, client_thread;
    int error = create_owned_thread(&server_thread, NULL, run_server, NULL, JUICE_ROLE_SERVER, 0);
    if (error) { atomic_store(&stopping, 1); return error; }
    pthread_detach(server_thread);
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 15;
    pthread_mutex_lock(&state_lock);
    while (!atomic_load(&server_ready) && !juice_runtime_stopping()) {
        error = pthread_cond_timedwait(&state_changed, &state_lock, &until);
        if (error) break;
    }
    int ready = atomic_load(&server_ready) && !juice_runtime_stopping();
    pthread_mutex_unlock(&state_lock);
    if (!ready) { juice_runtime_request_stop(); return error ?: EIO; }
    error = create_owned_thread(&client_thread, NULL, run_client, NULL, JUICE_ROLE_GUEST, 0);
    if (error) { juice_runtime_request_stop(); return error; }
    pthread_detach(client_thread);
    return 0;
}

static void deliver_signal(const struct sigaction *a, int sig, siginfo_t *info, void *context)
{
    if (a->sa_handler == SIG_IGN) return;
    if (a->sa_handler != SIG_DFL) {
        if (a->sa_flags & SA_SIGINFO) a->sa_sigaction(sig, info, context);
        else a->sa_handler(sig);
        return;
    }
    /* A non-Wine thread retains the host's actual default behavior. Never
     * swallow a UIKit crash or try to interpret its registers as a Wine TEB. */
    sigaction(sig, a, NULL);
    pthread_kill(pthread_self(), sig);
}
static void dispatch_signal(int sig, siginfo_t *info, void *context)
{
    const struct sigaction *guest = atomic_load_explicit(&guest_signals[sig], memory_order_acquire);
    const struct sigaction *a = role == JUICE_ROLE_GUEST && guest_thread_ready && guest ? guest : &previous_signals[sig];
    deliver_signal(a, sig, info, context);
}
int juice_runtime_sigaction(int sig, const struct sigaction *action, struct sigaction *old)
{
    if (role != JUICE_ROLE_GUEST || sig <= 0 || sig >= NSIG || sig == SIGKILL || sig == SIGSTOP) { errno = EPERM; return -1; }
    pthread_mutex_lock(&signal_lock);
    if (old) {
        struct sigaction *saved = atomic_load_explicit(&guest_signals[sig], memory_order_acquire);
        if (saved) *old = *saved;
        else sigaction(sig, NULL, old);
    }
    int result = 0;
    if (action) {
        if (signal_action_count >= 4096) { pthread_mutex_unlock(&signal_lock); errno = ENOMEM; return -1; }
        struct sigaction *saved = malloc(sizeof(*saved));
        if (!saved) { pthread_mutex_unlock(&signal_lock); return -1; }
        *saved = *action;
        struct sigaction bridge = *action;
        bridge.sa_flags |= SA_SIGINFO;
        bridge.sa_sigaction = dispatch_signal;
        if (!installed_signals[sig]) {
            /* Signal disposition readers never observe a partially assigned
             * action. Published snapshots stay alive for the host lifetime. */
            if (sigaction(sig, NULL, &previous_signals[sig])) { free(saved); pthread_mutex_unlock(&signal_lock); return -1; }
            atomic_store_explicit(&guest_signals[sig], saved, memory_order_release);
            result = sigaction(sig, &bridge, NULL);
            if (!result) installed_signals[sig] = 1;
        }
        if (!result) {
            atomic_store_explicit(&guest_signals[sig], saved, memory_order_release);
            ++signal_action_count;
        } else {
            atomic_store_explicit(&guest_signals[sig], NULL, memory_order_release);
            free(saved);
        }
    }
    pthread_mutex_unlock(&signal_lock);
    return result;
}
void (*juice_runtime_signal(int sig, void (*handler)(int)))(int)
{
    struct sigaction action = {0}, old = {0};
    action.sa_handler = handler; sigemptyset(&action.sa_mask);
    if (juice_runtime_sigaction(sig, &action, &old)) return SIG_ERR;
    return old.sa_handler;
}
int juice_runtime_kill(pid_t pid, int sig) { (void)pid; (void)sig; errno = EPERM; return -1; }
int juice_runtime_raise(int sig)
{
    if (role != JUICE_ROLE_GUEST || !guest_thread_ready || sig == SIGSTOP || sig == SIGKILL) { errno = EPERM; return -1; }
    int error = pthread_kill(pthread_self(), sig); if (error) errno = error;
    return error ? -1 : 0;
}
pid_t juice_runtime_fork(void) { errno = ENOTSUP; return -1; }
int juice_runtime_execve(const char *path, char *const argv[], char *const envp[])
{ (void)path; (void)argv; (void)envp; errno = ENOTSUP; return -1; }
int juice_runtime_execv(const char *path, char *const argv[]) { return juice_runtime_execve(path, argv, NULL); }
int juice_runtime_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                              const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{ (void)pid; (void)path; (void)actions; (void)attr; (void)argv; (void)envp; return ENOTSUP; }
int juice_runtime_atexit(void (*function)(void)) { (void)function; return 0; /* shutdown is owned by the server worker */ }
void juice_runtime_exit(int code)
{
    if (!role) {
        report(JUICE_RUNTIME_FAILED, EPERM, "Rejected an attempt to exit the UIKit host through the Wine ABI.");
        /* This ABI is never callable on the main thread. Do not terminate the
         * process even after a caller violates that invariant. */
        pthread_exit(NULL);
    }
    pthread_mutex_lock(&state_lock);
    if (code && !runtime_exit_code) runtime_exit_code = code;
    atomic_store(&stopping, 1);
    pthread_cond_broadcast(&state_changed);
    pthread_mutex_unlock(&state_lock);
    pthread_exit(NULL);
}
void juice_runtime_abort(void) { juice_runtime_exit(134); }
void juice_runtime_assert(const char *function, const char *file, int line, const char *expression)
{
    fprintf(juice_runtime_stream(2), "EMBEDDED_ASSERT %s:%d %s: %s\n", file, line, function ?: "?", expression);
    juice_runtime_exit(134);
}

void *juice_runtime_dlopen(const char *path, int mode)
{
    if (!path) return dlopen(NULL, mode);
    const char *base = strrchr(path, '/'); base = base ? base + 1 : path;
    static const char *names[][2] = {
        {"ntdll.so", "JuiceNTDLL"}, {"win32u.so", "JuiceWin32U"},
        {"wineios.so", "JuiceWineIOS"}, {"winevulkan.so", "JuiceWineVulkan"},
        {"ws2_32.so", "JuiceWinsock"}, {"crypt32.so", "JuiceCrypt"},
        {"dnsapi.so", "JuiceDNS"}, {"secur32.so", "JuiceSecurity"},
        {"dwrite.so", "JuiceDWrite"}, {"mountmgr.so", "JuiceMountMgr"},
        {"opengl32.so", "JuiceOpenGL"}, {"libgnutls.30.dylib", "JuiceGnuTLS"},
        {"MoltenVK", "MoltenVK"}
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i)
        if (!strcmp(base, names[i][0]) && frameworks_path) {
            char mapped[PATH_MAX];
            int n = snprintf(mapped, sizeof(mapped), "%s/%s.framework/%s", frameworks_path, names[i][1], names[i][1]);
            if (n <= 0 || (size_t)n >= sizeof(mapped)) { errno = ENAMETOOLONG; return NULL; }
            return dlopen(mapped, mode);
        }
    /* Keep system frameworks and ordinary data libraries available; sandbox
     * code-signing still decides what may load. No unsigned-image fallback. */
    return dlopen(path, mode);
}
