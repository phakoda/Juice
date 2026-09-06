#import "../JuiceChildReaper.h"
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
#define CHECK(x) do { if(!(x)){fprintf(stderr,"%s:%d: %s errno=%d\n",__FILE__,__LINE__,#x,errno);abort();} } while(0)
static pid_t StartChild(const char *self,int *releaseFD)
{
    int gate[2];CHECK(!pipe(gate));
    posix_spawn_file_actions_t actions;CHECK(!posix_spawn_file_actions_init(&actions));
    CHECK(!posix_spawn_file_actions_adddup2(&actions,gate[0],STDIN_FILENO));
    if(gate[0]!=STDIN_FILENO)CHECK(!posix_spawn_file_actions_addclose(&actions,gate[0]));
    CHECK(!posix_spawn_file_actions_addclose(&actions,gate[1]));
    char *args[]={(char *)self,"--child",NULL};pid_t pid=-1;
    CHECK(!posix_spawn(&pid,self,&actions,NULL,args,environ));
    posix_spawn_file_actions_destroy(&actions);close(gate[0]);*releaseFD=gate[1];return pid;
}
static void ReleaseChild(int fd){CHECK(write(fd,"x",1)==1);close(fd);}
int main(int argc,char **argv)
{
    if(argc==2){char byte;ssize_t n;do{n=read(STDIN_FILENO,&byte,1);}while(n<0&&errno==EINTR);return 7;}
    @autoreleasepool
    {
        alarm(30);setvbuf(stdout,NULL,_IONBF,0);
        dispatch_queue_t owner=dispatch_queue_create("juice.child-reaper-test",DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        int releaseFD=-1;pid_t child=StartChild(argv[0],&releaseFD);
        dispatch_async(owner,^{
            JuicePollCurrentChild(owner,child,^BOOL{return YES;},^(pid_t waited,int status,int error){
                CHECK(waited==child&&error==0&&WIFEXITED(status)&&WEXITSTATUS(status)==7);
                dispatch_semaphore_signal(done);
            });
        });
        ReleaseChild(releaseFD);
        CHECK(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
        CHECK(waitpid(child,NULL,WNOHANG)==-1&&errno==ECHILD);

        /* Revoke ownership after the first nonblocking poll, before exit.
         * The stale poll must not reap, nor invoke the completion callback. */
        child=StartChild(argv[0],&releaseFD);__block BOOL current=YES;
        dispatch_semaphore_t cancelled=dispatch_semaphore_create(0);
        dispatch_sync(owner,^{
            JuicePollCurrentChild(owner,child,^BOOL{
                if(!current)dispatch_semaphore_signal(cancelled);
                return current;
            },^(pid_t waited,int status,int error){
                (void)waited;(void)status;(void)error;CHECK(0);
            });
            current=NO;
        });
        ReleaseChild(releaseFD);
        CHECK(!dispatch_semaphore_wait(cancelled,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
        int status=0;pid_t waited;
        do{waited=waitpid(child,&status,0);}while(waited<0&&errno==EINTR);
        CHECK(waited==child&&WIFEXITED(status)&&WEXITSTATUS(status)==7);
        puts("JUICE_CHILD_REAPER_TESTS_OK cases=2 stale_owner_preserves_child=1");
    }
    return 0;
}
