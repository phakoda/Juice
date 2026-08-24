#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

static void (*JuiceOriginalLaunchTapped)(id, SEL);
static void (*JuiceOriginalStopTapped)(id, SEL);

static id JuiceLaunchValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceLaunchSetValue(id self, NSString *key, id value)
{
    @try { [self setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceLaunchAppend(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static id JuiceLaunchObjectResult(id self, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if (![self respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(self, selector);
}

static void JuiceLaunchVoid(id self, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL))objc_msgSend)(self, selector);
}

static void JuiceLaunchReject(id self, NSString *message)
{
    SEL selector = NSSelectorFromString(@"rejectLaunch:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, message);
    else
        JuiceLaunchAppend(self, [NSString stringWithFormat:@"LAUNCH_REJECTED %@\n", message]);
}

static char **JuiceCopyStrings(NSArray<NSString *> *strings)
{
    char **result = calloc(strings.count + 1, sizeof(*result));
    if (!result) return NULL;

    for (NSUInteger index = 0; index < strings.count; index++)
    {
        const char *utf8 = strings[index].UTF8String;
        if (!utf8 || !(result[index] = strdup(utf8)))
        {
            for (NSUInteger cleanup = 0; cleanup < index; cleanup++) free(result[cleanup]);
            free(result);
            return NULL;
        }
    }
    return result;
}

static void JuiceFreeStrings(char **strings)
{
    if (!strings) return;
    for (NSUInteger index = 0; strings[index]; index++) free(strings[index]);
    free(strings);
}

static BOOL JuiceIsWhitespace(unichar character)
{
    static NSCharacterSet *whitespace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet; });
    return [whitespace characterIsMember:character];
}

static NSArray<NSString *> *JuiceParseArguments(NSString *line, NSString **failure)
{
    if (!line.length) return @[];

    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    unichar quote = 0;
    BOOL tokenStarted = NO;

    for (NSUInteger index = 0; index < line.length; index++)
    {
        unichar character = [line characterAtIndex:index];

        if (quote)
        {
            if (character == quote)
            {
                quote = 0;
                tokenStarted = YES;
                continue;
            }
            if (character == '\\' && index + 1 < line.length)
            {
                unichar next = [line characterAtIndex:index + 1];
                if (next == quote || next == '\\')
                {
                    [current appendFormat:@"%C", next];
                    index++;
                    tokenStarted = YES;
                    continue;
                }
            }
            [current appendFormat:@"%C", character];
            tokenStarted = YES;
            continue;
        }

        if (character == '"' || character == '\'')
        {
            quote = character;
            tokenStarted = YES;
            continue;
        }
        if (JuiceIsWhitespace(character))
        {
            if (tokenStarted)
            {
                [arguments addObject:[current copy]];
                [current setString:@""];
                tokenStarted = NO;
            }
            continue;
        }
        if (character == '\\' && index + 1 < line.length)
        {
            unichar next = [line characterAtIndex:index + 1];
            if (JuiceIsWhitespace(next) || next == '"' || next == '\'' || next == '\\')
            {
                [current appendFormat:@"%C", next];
                index++;
                tokenStarted = YES;
                continue;
            }
        }
        [current appendFormat:@"%C", character];
        tokenStarted = YES;
    }

    if (quote)
    {
        if (failure) *failure = @"Arguments contain an unterminated quote.";
        return nil;
    }
    if (tokenStarted) [arguments addObject:[current copy]];
    return arguments;
}

static BOOL JuiceProcessExists(pid_t pid)
{
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0 || errno == EPERM) return YES;
    return errno != ESRCH;
}

static void JuiceRefreshServerState(id self)
{
    pid_t server = [JuiceLaunchValue(self, @"server") intValue];
    if (server <= 0) return;

    int status = 0;
    pid_t waited = waitpid(server, &status, WNOHANG);
    if (waited == server || (waited < 0 && errno == ECHILD && !JuiceProcessExists(server)))
    {
        JuiceLaunchSetValue(self, @"server", @(-1));
        JuiceLaunchAppend(self, [NSString stringWithFormat:
            @"WINE_SERVER_STALE pid=%d reaped=%d\n", server, waited == server]);
    }
}

static BOOL JuiceStartServerIfNeeded(id self, NSString *serverPath, NSArray<NSString *> *environment)
{
    JuiceRefreshServerState(self);
    pid_t current = [JuiceLaunchValue(self, @"server") intValue];
    if (current > 0) return YES;

    char **env = JuiceCopyStrings(environment);
    char **argv = JuiceCopyStrings(@[serverPath, @"-f"]);
    if (!env || !argv)
    {
        JuiceFreeStrings(env);
        JuiceFreeStrings(argv);
        JuiceLaunchAppend(self, @"WINE_SERVER_FAILED reason=argv-allocation\n");
        return NO;
    }

    posix_spawn_file_actions_t actions;
    int actionStatus = posix_spawn_file_actions_init(&actions);
    if (!actionStatus)
    {
        actionStatus = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
        if (!actionStatus) actionStatus = posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }

    pid_t serverPID = -1;
    int spawnStatus = actionStatus ?: posix_spawn(&serverPID, serverPath.fileSystemRepresentation,
                                                   &actions, NULL, argv, env);
    if (!actionStatus) posix_spawn_file_actions_destroy(&actions);
    JuiceFreeStrings(argv);
    JuiceFreeStrings(env);

    if (spawnStatus)
    {
        JuiceLaunchSetValue(self, @"server", @(-1));
        JuiceLaunchAppend(self, [NSString stringWithFormat:
            @"WINE_SERVER_FAILED status=%d error=%s\n", spawnStatus, strerror(spawnStatus)]);
        return NO;
    }

    JuiceLaunchSetValue(self, @"server", @(serverPID));
    JuiceLaunchAppend(self, [NSString stringWithFormat:@"Wine server: 0 pid=%d\n", serverPID]);
    /* Keep the historical startup grace period, but shorter; Wine's loader
       will still synchronize with wineserver if it needs longer. */
    usleep(150000);
    return YES;
}

static void JuiceTerminateForeground(id self)
{
    int inputFD = [JuiceLaunchValue(self, @"childInput") intValue];
    if (inputFD >= 0)
    {
        close(inputFD);
        JuiceLaunchSetValue(self, @"childInput", @(-1));
    }

    pid_t child = [JuiceLaunchValue(self, @"child") intValue];
    if (child <= 0) return;

    errno = 0;
    int groupResult = kill(-child, SIGTERM);
    int groupError = errno;
    if (groupResult != 0) kill(child, SIGTERM);
    JuiceLaunchSetValue(self, @"child", @(-1));
    JuiceLaunchAppend(self, [NSString stringWithFormat:
        @"FOREGROUND_STOP pid=%d group=%d group_errno=%d\n",
        child, groupResult == 0, groupError]);
}

static NSString *JuiceDecodeLogData(NSData *data)
{
    if (!data.length) return @"";
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text ?: @"";
}

static void JuiceConsumeChildOutput(id self, int readFD, pid_t childPID, int inputFD)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *pending = [NSMutableData data];
        uint8_t buffer[4096];

        for (;;)
        {
            ssize_t count = read(readFD, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            [pending appendBytes:buffer length:(NSUInteger)count];

            const uint8_t *bytes = pending.bytes;
            NSUInteger start = 0;
            for (NSUInteger index = 0; index < pending.length; index++)
            {
                if (bytes[index] != '\n') continue;
                NSUInteger length = index + 1 - start;
                NSData *line = [NSData dataWithBytes:bytes + start length:length];
                JuiceLaunchAppend(self, JuiceDecodeLogData(line));
                start = index + 1;
            }
            if (start)
                [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];

            /* A program that emits megabytes without newlines must not make
               this line buffer itself unbounded. */
            if (pending.length >= 64 * 1024)
            {
                JuiceLaunchAppend(self, JuiceDecodeLogData(pending));
                [pending setLength:0];
            }
        }
        if (pending.length) JuiceLaunchAppend(self, JuiceDecodeLogData(pending));
        close(readFD);

        int status = 0;
        pid_t waited;
        do { waited = waitpid(childPID, &status, 0); }
        while (waited < 0 && errno == EINTR);

        dispatch_async(dispatch_get_main_queue(), ^{
            pid_t currentChild = [JuiceLaunchValue(self, @"child") intValue];
            if (currentChild == childPID)
            {
                JuiceLaunchSetValue(self, @"child", @(-1));
                int currentInput = [JuiceLaunchValue(self, @"childInput") intValue];
                if (currentInput == inputFD && currentInput >= 0)
                {
                    close(currentInput);
                    JuiceLaunchSetValue(self, @"childInput", @(-1));
                }
            }
            NSString *result;
            if (waited == childPID && WIFEXITED(status))
                result = [NSString stringWithFormat:@"exit=%d", WEXITSTATUS(status)];
            else if (waited == childPID && WIFSIGNALED(status))
                result = [NSString stringWithFormat:@"signal=%d", WTERMSIG(status)];
            else
                result = [NSString stringWithFormat:@"wait=%d errno=%d", waited, errno];
            JuiceLaunchAppend(self, [NSString stringWithFormat:
                @"FOREGROUND_EXIT pid=%d %@\n", childPID, result]);
        });
    });
}

static void JuiceHardenedLaunchTapped(id self, SEL _cmd)
{
    (void)_cmd;
    JuiceTerminateForeground(self);
    JuiceLaunchVoid(self, @"preparePrefix");

    UITextField *argsField = JuiceLaunchValue(self, @"argsField");
    NSString *parseFailure = nil;
    NSArray<NSString *> *parts = JuiceParseArguments(argsField.text ?: @"", &parseFailure);
    if (!parts)
    {
        JuiceLaunchReject(self, parseFailure ?: @"Arguments could not be parsed.");
        return;
    }

    NSString *grape = JuiceLaunchValue(self, @"grape");
    NSString *build = [grape stringByAppendingPathComponent:@"build/wine-ios"];
    NSString *loader = [build stringByAppendingPathComponent:@"loader/wine"];
    NSString *server = [build stringByAppendingPathComponent:@"server/wineserver"];
    NSString *tracer = [grape stringByAppendingPathComponent:@"tools/grape-trace-parent"];
    NSString *exe = JuiceLaunchObjectResult(self, @"resolveExe");
    NSArray<NSString *> *environment = JuiceLaunchObjectResult(self, @"environment");

    if (!grape.length || !exe.length || !environment.count ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:loader] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:tracer])
    {
        JuiceLaunchReject(self, @"The selected Wine runtime is incomplete or not executable.");
        return;
    }

    if (!JuiceStartServerIfNeeded(self, server, environment))
    {
        JuiceLaunchReject(self, @"Juice could not start wineserver. Export the full log for details.");
        return;
    }

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:tracer, loader, exe, nil];
    [arguments addObjectsFromArray:parts];
    char **argv = JuiceCopyStrings(arguments);
    char **env = JuiceCopyStrings(environment);
    if (!argv || !env)
    {
        JuiceFreeStrings(argv);
        JuiceFreeStrings(env);
        JuiceLaunchReject(self, @"Juice ran out of memory while preparing the process arguments.");
        return;
    }

    int outputPipe[2] = {-1, -1};
    int inputPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0 || pipe(inputPipe) != 0)
    {
        int saved = errno;
        if (outputPipe[0] >= 0) close(outputPipe[0]);
        if (outputPipe[1] >= 0) close(outputPipe[1]);
        if (inputPipe[0] >= 0) close(inputPipe[0]);
        if (inputPipe[1] >= 0) close(inputPipe[1]);
        JuiceFreeStrings(argv);
        JuiceFreeStrings(env);
        JuiceLaunchReject(self, [NSString stringWithFormat:
            @"Juice could not create process pipes: %s", strerror(saved)]);
        return;
    }
    fcntl(outputPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(inputPipe[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    int actionStatus = posix_spawn_file_actions_init(&actions);
    if (!actionStatus) actionStatus = posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0);
    if (!actionStatus) actionStatus = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1);
    if (!actionStatus) actionStatus = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 2);
    if (!actionStatus) actionStatus = posix_spawn_file_actions_addclose(&actions, inputPipe[1]);
    if (!actionStatus) actionStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    if (!actionStatus && inputPipe[0] != 0)
        actionStatus = posix_spawn_file_actions_addclose(&actions, inputPipe[0]);
    if (!actionStatus && outputPipe[1] != 1 && outputPipe[1] != 2)
        actionStatus = posix_spawn_file_actions_addclose(&actions, outputPipe[1]);

    NSString *workingDirectory = exe.stringByDeletingLastPathComponent;
    if (!actionStatus && [exe containsString:@"/"] && workingDirectory.length)
        actionStatus = posix_spawn_file_actions_addchdir_np(&actions,
                                                             workingDirectory.fileSystemRepresentation);

    posix_spawnattr_t attributes;
    BOOL attributesReady = posix_spawnattr_init(&attributes) == 0;
    BOOL processGroup = NO;
    if (attributesReady && posix_spawnattr_setpgroup(&attributes, 0) == 0 &&
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP) == 0)
        processGroup = YES;

    pid_t childPID = -1;
    int spawnStatus = actionStatus ?: posix_spawn(&childPID, tracer.fileSystemRepresentation,
                                                   &actions,
                                                   processGroup ? &attributes : NULL,
                                                   argv, env);

    if (!actionStatus) posix_spawn_file_actions_destroy(&actions);
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    close(inputPipe[0]);
    close(outputPipe[1]);
    JuiceFreeStrings(argv);
    JuiceFreeStrings(env);

    if (spawnStatus)
    {
        close(inputPipe[1]);
        close(outputPipe[0]);
        JuiceLaunchSetValue(self, @"child", @(-1));
        JuiceLaunchSetValue(self, @"childInput", @(-1));
        JuiceLaunchReject(self, [NSString stringWithFormat:
            @"Wine could not start %@: %s", exe.lastPathComponent, strerror(spawnStatus)]);
        return;
    }

    JuiceLaunchSetValue(self, @"child", @(childPID));
    JuiceLaunchSetValue(self, @"childInput", @(inputPipe[1]));
    JuiceLaunchSetValue(self, @"serverUsingX64", JuiceLaunchValue(self, @"usingX64") ?: @NO);

    UISegmentedControl *mode = JuiceLaunchValue(self, @"mode");
    UIView *canvas = JuiceLaunchValue(self, @"canvas");
    BOOL cli = mode.selectedSegmentIndex == 1;
    canvas.hidden = cli;
    JuiceLaunchAppend(self, [NSString stringWithFormat:
        @"\n%@ launch %@: 0 pid=%d pgroup=%d argc=%lu cwd=%@\n",
        cli ? @"CLI" : @"GUI", exe, childPID, processGroup,
        (unsigned long)arguments.count, workingDirectory]);

    JuiceConsumeChildOutput(self, outputPipe[0], childPID, inputPipe[1]);
}

static void JuiceHardenedStopTapped(id self, SEL _cmd)
{
    (void)_cmd;
    JuiceTerminateForeground(self);
}

__attribute__((constructor))
static void JuiceInstallLaunchHardening(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method launch = class_getInstanceMethod(cls, NSSelectorFromString(@"launchTapped"));
    if (launch)
        JuiceOriginalLaunchTapped = (void (*)(id, SEL))
            method_setImplementation(launch, (IMP)JuiceHardenedLaunchTapped);

    Method stop = class_getInstanceMethod(cls, NSSelectorFromString(@"stopTapped"));
    if (stop)
        JuiceOriginalStopTapped = (void (*)(id, SEL))
            method_setImplementation(stop, (IMP)JuiceHardenedStopTapped);
}
