/* White-box host tests: private worker creation is visible only in this test
 * translation unit. The shipping library exports no JIT-test bypass. */
#include "../runtime/embedded/JuiceEmbeddedRuntime.c"
#include <assert.h>
#include <sys/mman.h>

static _Atomic unsigned host_signals, guest_signals_seen;
static char host_directory[PATH_MAX], guest_directory[PATH_MAX];
static void host_handler(int value) { (void)value; atomic_fetch_add(&host_signals, 1); }
static void guest_handler(int value) { (void)value; atomic_fetch_add(&guest_signals_seen, 1); }

static void *inherited_worker(void *unused)
{
    (void)unused;
    char cwd[PATH_MAX]; assert(getcwd(cwd, sizeof(cwd)));
    assert(!strcmp(cwd, guest_directory));
    assert(juice_runtime_is_guest_thread());
    assert(!strcmp(juice_runtime_getenv("JUICE_ISOLATION_TEST"), "guest-updated"));
    assert(!strcmp(getenv("JUICE_ISOLATION_TEST"), "host-untouched"));
    return NULL;
}
static void *guest_worker(void *unused)
{
    (void)unused;
    char cwd[PATH_MAX]; assert(getcwd(cwd, sizeof(cwd)));
    assert(!strcmp(cwd, guest_directory));
    assert(!juice_runtime_setenv("JUICE_ISOLATION_TEST", "guest-updated", 1));
    assert(!strcmp(getenv("JUICE_ISOLATION_TEST"), "host-untouched"));
    assert(juice_runtime_fork() == -1 && errno == ENOTSUP);
    assert(juice_runtime_kill(getpid(), SIGKILL) == -1 && errno == EPERM);
    assert(juice_runtime_posix_spawn(NULL, "unused", NULL, NULL, NULL, NULL) == ENOTSUP);
    assert(juice_runtime_dup2(juice_runtime_standard_fd(1), 1) == -1 && errno == EPERM);
    assert(juice_runtime_close(1) == 0 && fcntl(STDOUT_FILENO, F_GETFD) >= 0);
    assert(juice_runtime_umask(0077) == 0077);
    assert(juice_runtime_umask(0022) == 0077);
    pthread_t inherited;
    assert(!juice_runtime_pthread_create(&inherited, NULL, inherited_worker, NULL));
    assert(!pthread_join(inherited, NULL));
    juice_runtime_mark_guest_thread_ready();
    struct sigaction action = {0}; action.sa_handler = guest_handler; sigemptyset(&action.sa_mask);
    assert(!juice_runtime_sigaction(SIGUSR2, &action, NULL));
    assert(!juice_runtime_raise(SIGUSR2));
    assert(atomic_load(&guest_signals_seen) == 1 && atomic_load(&host_signals) == 0);
    const char text[] = "private-output";
    assert(juice_runtime_write(1, text, sizeof(text)) == sizeof(text));
    return NULL;
}

int main(void)
{
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    unsigned char *host_mapping = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(host_mapping != MAP_FAILED); memset(host_mapping, 0x5a, page);
    assert(juice_runtime_mprotect(host_mapping, page, PROT_NONE) == -1 && errno == EPERM);
    assert(juice_runtime_munmap(host_mapping, page) == -1 && errno == EPERM);
    assert(juice_runtime_mmap(host_mapping, page, PROT_READ | PROT_WRITE,
        MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED);
    for (size_t i = 0; i < page; ++i) assert(host_mapping[i] == 0x5a);
    assert(!munmap(host_mapping, page));
    unsigned char *guest_mapping = juice_runtime_mmap(NULL, 4 * page, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(guest_mapping != MAP_FAILED); memset(guest_mapping, 0x73, 4 * page);
    assert(!juice_runtime_mprotect(guest_mapping, page, PROT_READ));
    assert(!juice_runtime_mprotect(guest_mapping, page, PROT_READ | PROT_WRITE));
    assert(juice_runtime_mprotect(guest_mapping, page, PROT_READ | PROT_WRITE | PROT_EXEC) == -1 && errno == EACCES);
    assert(!juice_runtime_munmap(guest_mapping + page, 2 * page));
    assert(!juice_runtime_munmap(guest_mapping, page));
    assert(!juice_runtime_munmap(guest_mapping + 3 * page, page));
    assert(getcwd(host_directory, sizeof(host_directory)));
    char temporary[] = "/tmp/juice-embedded-isolation.XXXXXX";
    assert(mkdtemp(temporary));
    assert(realpath(temporary, guest_directory));
    const char *old_value = getenv("JUICE_ISOLATION_TEST");
    char *saved = old_value ? strdup(old_value) : NULL;
    assert(!setenv("JUICE_ISOLATION_TEST", "host-untouched", 1));
    int input[2], output[2]; assert(!pipe(input) && !pipe(output));
    char *env[] = {"JUICE_ISOLATION_TEST=guest-initial", NULL};
    JuiceRuntimeConfiguration config = {.abi=JUICE_EMBEDDED_ABI, .size=sizeof(config),
        .runtime_root=guest_directory, .frameworks_root=guest_directory, .prefix=guest_directory,
        .working_directory=guest_directory, .environment=env,
        .standard_fds={input[0], output[1], output[1]}};
    assert(!juice_runtime_configure(&config));
    assert(juice_runtime_configure(&config) == EALREADY);
    struct sigaction action = {0}, original;
    action.sa_handler = host_handler; sigemptyset(&action.sa_mask);
    assert(!sigaction(SIGUSR2, &action, &original));
    pthread_t thread;
    assert(!create_owned_thread(&thread, NULL, guest_worker, NULL, JUICE_ROLE_GUEST, 0));
    assert(!pthread_join(thread, NULL));
    assert(live_threads == 0);
    assert(!pthread_kill(pthread_self(), SIGUSR2));
    assert(atomic_load(&guest_signals_seen) == 1 && atomic_load(&host_signals) == 1);
    assert(!sigaction(SIGUSR2, &original, NULL));
    char bytes[64] = {0}; assert(read(output[0], bytes, sizeof(bytes)) > 0);
    assert(!strcmp(bytes, "private-output"));
    char cwd[PATH_MAX]; assert(getcwd(cwd, sizeof(cwd)) && !strcmp(cwd, host_directory));
    assert(!strcmp(getenv("JUICE_ISOLATION_TEST"), "host-untouched"));
    assert(!juice_runtime_consumed() && !juice_runtime_stopping());
    if (saved) { setenv("JUICE_ISOLATION_TEST", saved, 1); free(saved); }
    else unsetenv("JUICE_ISOLATION_TEST");
    assert(!rmdir(guest_directory));
    puts("JUICE_EMBEDDED_ISOLATION_OK environment=1 thread_cwd=1 inherited_cwd=1 stdio=1 host_signal=1 guest_signal=1 spawn_denied=1 host_mappings_preserved=1 rwx_denied=1 host_alive=1");
    return 0;
}
