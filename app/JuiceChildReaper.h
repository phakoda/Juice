#ifndef JUICE_CHILD_REAPER_H
#define JUICE_CHILD_REAPER_H
#import <Foundation/Foundation.h>
#include <errno.h>
#include <sys/wait.h>

/* The owner queue must also serialize launch replacement and termination.
 * Keep the ownership check, reap and state update in ONE nonblocking turn.
 * A stale owner leaves the child for the termination path to reap after its
 * final signal, so a delayed kill cannot target a recycled leader PID. */
static void JuicePollCurrentChild(dispatch_queue_t ownerQueue,pid_t child,
                                  BOOL (^isCurrent)(void),
                                  void (^finished)(pid_t,int,int))
{
    dispatch_assert_queue(ownerQueue);
    if(!isCurrent())return;
    if(child<=0){finished(-1,0,EINVAL);return;}
    int status=0;
    pid_t waited;
    do{waited=waitpid(child,&status,WNOHANG);}while(waited<0&&errno==EINTR);
    int waitError=waited<0?errno:0;
    if(!waited)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),ownerQueue,^{
            JuicePollCurrentChild(ownerQueue,child,isCurrent,finished);
        });
        return;
    }
    finished(waited,status,waitError);
}
#endif
