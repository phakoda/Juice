#ifndef JUICE_EMBEDDED_SHIM_H
#define JUICE_EMBEDDED_SHIM_H
/* Included AFTER each native source's system/Wine headers. Never force-include
 * this ahead of headers: libc declarations must retain their real names. */
#include "JuiceEmbeddedRuntime.h"
#ifdef JUICE_EMBEDDED
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <dlfcn.h>
#undef environ
#define environ juice_runtime_environ
#define getenv juice_runtime_getenv
#define setenv juice_runtime_setenv
#define unsetenv juice_runtime_unsetenv
#define putenv juice_runtime_putenv
#define chdir juice_runtime_chdir
#define fchdir juice_runtime_fchdir
#define pthread_create juice_runtime_pthread_create
#define sigaction(...) juice_runtime_sigaction(__VA_ARGS__)
#define signal juice_runtime_signal
#define kill juice_runtime_kill
#define raise juice_runtime_raise
#define fork juice_runtime_fork
#define vfork juice_runtime_fork
#define execve juice_runtime_execve
#define execv juice_runtime_execv
#define execvp juice_runtime_execv
#define posix_spawn juice_runtime_posix_spawn
#define posix_spawnp juice_runtime_posix_spawn
#define atexit juice_runtime_atexit
#define exit juice_runtime_exit
#define _exit juice_runtime_exit
#define abort juice_runtime_abort
#define __assert_rtn juice_runtime_assert
#ifndef dlopen
#define dlopen juice_runtime_dlopen
#endif
#undef mmap
#define mmap juice_runtime_mmap
#define munmap juice_runtime_munmap
#define mprotect juice_runtime_mprotect
#ifndef MAP_TRYFIXED
#define MAP_TRYFIXED 0x40000000
#endif
#undef stdin
#undef stdout
#undef stderr
#define stdin (juice_runtime_stream(0))
#define stdout (juice_runtime_stream(1))
#define stderr (juice_runtime_stream(2))
#endif
#endif
