#include "../JuiceJITState.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static JuiceJITState fresh(void) { return (JuiceJITState){JuiceJITOpening, 120000, false}; }
static JuiceJITAction step(JuiceJITState *s,JuiceJITEvent e,uint64_t now,bool owns,bool active)
{ return JuiceJITTransition(s,e,now,owns,active); }
int main(void)
{
    JuiceJITState s=fresh();
    assert(step(&s,JuiceJITDebugged,0,true,true)==JuiceJITNoAction);
    assert(s.phase==JuiceJITOpening);
    step(&s,JuiceJITOpenAccepted,1,true,true);
    assert(step(&s,JuiceJITDebugged,2,true,false)==JuiceJITNoAction);
    assert(step(&s,JuiceJITDebugged,3,true,true)==JuiceJITResume);
    assert(s.phase==JuiceJITStarting);
    assert(step(&s,JuiceJITDebugged,4,true,true)==JuiceJITNoAction);
    step(&s,JuiceJITRuntimeAck,5,true,true);assert(s.phase==JuiceJITReady);
    assert(step(&s,JuiceJITOpenRejected,6,true,true)==JuiceJITNoAction);
    s=fresh();assert(step(&s,JuiceJITOpenRejected,1,true,true)==JuiceJITStop);
    assert(step(&s,JuiceJITOpenRejected,2,true,true)==JuiceJITNoAction);
    s=fresh();assert(step(&s,JuiceJITTick,120000,true,true)==JuiceJITStop);
    s=fresh();step(&s,JuiceJITOpenAccepted,1,true,true);
    assert(step(&s,JuiceJITDebugged,120001,true,true)==JuiceJITStop);
    s=fresh();step(&s,JuiceJITOpenAccepted,1,true,true);
    assert(step(&s,JuiceJITDebugged,2,false,true)==JuiceJITNoAction);
    assert(s.phase==JuiceJITCancelled);
    assert(step(&s,JuiceJITDebugged,3,true,true)==JuiceJITNoAction);
    s=fresh();step(&s,JuiceJITCancel,1,true,true);
    assert(step(&s,JuiceJITOpenAccepted,2,true,true)==JuiceJITNoAction);
    s=fresh();step(&s,JuiceJITOpenAccepted,1,true,true);
    step(&s,JuiceJITRuntimeAck,2,true,false);assert(s.phase==JuiceJITReady);
    s=fresh();step(&s,JuiceJITRuntimeAck,0,true,false);
    assert(s.phase==JuiceJITOpening);step(&s,JuiceJITOpenAccepted,1,true,true);
    assert(s.phase==JuiceJITReady);
    /* Exhaustively exercise short callback orderings, including an ownership
     * revocation. No ordering can resume twice or signal after revocation. */
    unsigned sequences=1;
    for(int i=0;i<6;i++)sequences*=6;
    for(unsigned sequence=0;sequence<sequences;sequence++)
    {
        unsigned code=sequence,resumes=0,stops=0;s=fresh();
        for(unsigned i=0;i<6;i++)
        {
            JuiceJITEvent event=(JuiceJITEvent)(code%6);code/=6;
            JuiceJITAction a=step(&s,event,i*30000,i<4,true);
            resumes+=a==JuiceJITResume;stops+=a==JuiceJITStop;
            assert(resumes<=1 && stops<=1);
            if(i>=4)assert(a==JuiceJITNoAction);
        }
    }
    printf("JUICE_JIT_STATE_TESTS_OK cases=9 orderings=%u\n",sequences);
    return 0;
}
