#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

extern int ptrace(
    int request,
    pid_t pid,
    char *address,
    int signal_number
);

#ifndef PT_CONTINUE
#define PT_CONTINUE 7
#endif

#ifndef PT_DETACH
#define PT_DETACH 11
#endif

static volatile sig_atomic_t forwarded_signal;
static volatile sig_atomic_t wine_child = -1;

static void forward_termination_signal(int signal_number)
{
    pid_t child = (pid_t)wine_child;

    forwarded_signal = signal_number;
    if (child > 0)
        kill(child, signal_number);
}

static int install_signal_policy(void)
{
    static const int forwarded[] = { SIGHUP, SIGINT, SIGTERM, SIGQUIT };
    struct sigaction action;
    size_t index;

    /* Logging goes to a pipe owned by the UIKit host. If that reader closes
       during shutdown, diagnostics must not kill the supervisor and orphan
       the Wine process. */
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR)
        return -1;

    memset(&action, 0, sizeof(action));
    action.sa_handler = forward_termination_signal;
    sigemptyset(&action.sa_mask);

    for (index = 0; index < sizeof(forwarded) / sizeof(forwarded[0]); index++)
        if (sigaction(forwarded[index], &action, NULL) == -1)
            return -1;

    return 0;
}

/*
 * The Linux-built TIPA carries target-side libraries (currently FreeType) in
 * Juice.app/Libraries.  The UIKit launcher starts this tracer, which in turn
 * starts Wine, so this is the last reliable place to prepend the bundle path
 * before dyld initializes the Wine process.  Existing rootless library paths
 * are retained as fallbacks for the rest of the Procursus runtime.
 */
static void prepend_bundle_libraries(const char *program)
{
    const char *marker;
    const char *old;
    size_t root_length;
    size_t length;
    char *value;

    marker = strstr(program, "/Grape-X64/");
    if (!marker)
        marker = strstr(program, "/Grape/");
    if (!marker)
        return;

    root_length = (size_t)(marker - program);
    old = getenv("DYLD_LIBRARY_PATH");
    length = root_length + strlen("/Libraries") + 1;
    if (old && *old)
        length += 1 + strlen(old);

    value = malloc(length);
    if (!value)
        return;

    if (old && *old)
        snprintf(
            value,
            length,
            "%.*s/Libraries:%s",
            (int)root_length,
            program,
            old
        );
    else
        snprintf(
            value,
            length,
            "%.*s/Libraries",
            (int)root_length,
            program
        );

    if (!setenv("DYLD_LIBRARY_PATH", value, 1))
        fprintf(
            stderr,
            "[JuiceWine parent] bundle libraries path=%s\n",
            value
        );

    free(value);
}

static int ptrace_continue(
    pid_t child,
    int signal_number
)
{
    errno = 0;

    if (ptrace(
            PT_CONTINUE,
            child,
            (char *)1,
            signal_number
        ) == -1)
    {
        fprintf(
            stderr,
            "[JuiceWine parent] PT_CONTINUE failed: "
            "errno=%d (%s)\n",
            errno,
            strerror(errno)
        );

        return -1;
    }

    return 0;
}

static int ptrace_detach(
    pid_t child
)
{
    int result;
    int saved_errno;

    errno = 0;

    result = ptrace(
        PT_DETACH,
        child,
        (char *)1,
        0
    );

    saved_errno = errno;

    fprintf(
        stderr,
        "[JuiceWine parent] PT_DETACH "
        "pid=%d result=%d",
        child,
        result
    );

    if (result == -1)
    {
        fprintf(
            stderr,
            " errno=%d (%s)",
            saved_errno,
            strerror(saved_errno)
        );
    }

    fputc('\n', stderr);

    errno = saved_errno;
    return result;
}

int main(int argc, char **argv)
{
    pid_t child;
    pid_t waited;

    int spawn_result;
    int status;
    int detached = 0;

    if (argc < 2)
    {
        fprintf(
            stderr,
            "Usage: %s PROGRAM [ARGUMENTS...]\n",
            argv[0]
        );

        return 64;
    }

    if (install_signal_policy() == -1)
    {
        fprintf(
            stderr,
            "[JuiceWine parent] could not install signal policy: "
            "errno=%d (%s)\n",
            errno,
            strerror(errno)
        );
        return 70;
    }

    prepend_bundle_libraries(argv[1]);

    fprintf(
        stderr,
        "[JuiceWine parent] launching %s\n",
        argv[1]
    );

    spawn_result = posix_spawn(
        &child,
        argv[1],
        NULL,
        NULL,
        &argv[1],
        environ
    );

    if (spawn_result)
    {
        fprintf(
            stderr,
            "[JuiceWine parent] posix_spawn failed: "
            "%d (%s)\n",
            spawn_result,
            strerror(spawn_result)
        );

        return 65;
    }

    wine_child = child;
    if (forwarded_signal)
        kill(child, forwarded_signal);

    fprintf(
        stderr,
        "[JuiceWine parent] child PID=%d\n",
        child
    );

    for (;;)
    {
        do
        {
            waited = waitpid(
                child,
                &status,
                WUNTRACED
            );
        }
        while (waited == -1 && errno == EINTR);

        if (waited == -1)
        {
            fprintf(
                stderr,
                "[JuiceWine parent] waitpid failed: "
                "errno=%d (%s)\n",
                errno,
                strerror(errno)
            );

            kill(child, SIGKILL);
            wine_child = -1;
            return 66;
        }

        if (WIFSTOPPED(status))
        {
            int stop_signal = WSTOPSIG(status);

            fprintf(
                stderr,
                "[JuiceWine parent] child stopped "
                "pid=%d signal=%d (%s)\n",
                child,
                stop_signal,
                strsignal(stop_signal)
            );

            /*
             * Wine deliberately raises SIGSTOP immediately after
             * PT_TRACE_ME. Detach only at that exact handshake.
             */
            if (!detached && stop_signal == SIGSTOP)
            {
                if (ptrace_detach(child) == -1)
                {
                    kill(child, SIGKILL);
                    wine_child = -1;
                    return 67;
                }

                detached = 1;

                fprintf(
                    stderr,
                    "[JuiceWine parent] child now running "
                    "untraced\n"
                );

                /* A Stop request can race the PT_TRACE_ME handshake. Re-send
                   it after detach so a signal delivered while the child was
                   stopped cannot be lost behind the tracing transition. */
                if (forwarded_signal)
                    kill(child, forwarded_signal);

                continue;
            }

            /*
             * Ignore harmless traced startup notifications while
             * waiting for Wine's deliberate SIGSTOP handshake.
             */
            if (!detached &&
                (stop_signal == SIGCHLD ||
                 stop_signal == SIGTRAP))
            {
                if (ptrace_continue(child, 0) == -1)
                {
                    kill(child, SIGKILL);
                    wine_child = -1;
                    return 68;
                }

                continue;
            }

            fprintf(
                stderr,
                "[JuiceWine parent] unexpected stop before "
                "detach; terminating diagnostic run\n"
            );

            kill(child, SIGKILL);
            wine_child = -1;
            return 69;
        }

        if (WIFEXITED(status))
        {
            int result = WEXITSTATUS(status);

            wine_child = -1;
            fprintf(
                stderr,
                "[JuiceWine parent] child exited with %d\n",
                result
            );

            return result;
        }

        if (WIFSIGNALED(status))
        {
            int signal_number = WTERMSIG(status);

            wine_child = -1;
            fprintf(
                stderr,
                "[JuiceWine parent] child terminated by "
                "signal %d (%s)\n",
                signal_number,
                strsignal(signal_number)
            );

            return 128 + signal_number;
        }
    }
}
