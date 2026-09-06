#import <Foundation/Foundation.h>
#import <spawn.h>

/* These functions are called only by the launch owner, never interposed on
 * process-wide posix_spawn. A successful spawn always remains a success: all
 * subsequent errors are cancelled through the adopted launch's Stop path. */
int JuiceSpawnForLaunch(id owner, pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
    char *const argv[], char *const envp[]);
void JuiceJITAdoptLaunch(id owner, pid_t pid, uint64_t generation);
void JuiceJITObserveOutput(id owner, pid_t pid, uint64_t generation, NSString *line);
void JuiceJITWillReap(id owner, pid_t pid, uint64_t generation);
