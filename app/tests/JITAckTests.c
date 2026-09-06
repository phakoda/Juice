#include "../JuiceJITAck.h"
#include "../JuiceJITState.h"
#include <assert.h>
#include <stdio.h>
#include <stdint.h>

static const char marker[]="JUICE_JIT_RUNTIME_READY pid=417 session=12345678-1234-1234-1234-123456789ABC";
static JuiceJITAck fresh(void)
{
    JuiceJITAck a;
    assert(JuiceJITAckInit(&a,marker,sizeof(marker)-1));
    return a;
}
int main(void)
{
    char line[256];
    int n=snprintf(line,sizeof(line),"unrelated log\n%s\r\nother log\n",marker);
    assert(n>0);
    for(int split=0;split<=n;split++) {
        JuiceJITAck a=fresh();
        bool matched=JuiceJITAckFeed(&a,line,(size_t)split);
        matched|=JuiceJITAckFeed(&a,line+split,(size_t)(n-split));
        assert(matched);
    }
    for(size_t step=1;step<sizeof(marker);step++) {
        JuiceJITAck a=fresh();bool matched=false;
        for(size_t i=0;i<(size_t)n;i+=step) {
            size_t len=(size_t)n-i<step?(size_t)n-i:step;
            matched|=JuiceJITAckFeed(&a,line+i,len);
        }
        assert(matched);
    }
    const char *bad[]={"prefix%s\n","%ssuffix\n","%s\r\r\n","%s", " %s\n"};
    for(size_t i=0;i<sizeof(bad)/sizeof(*bad);i++) {
        JuiceJITAck a=fresh();n=snprintf(line,sizeof(line),bad[i],marker);
        assert(!JuiceJITAckFeed(&a,line,(size_t)n));
    }
    n=snprintf(line,sizeof(line),"%s\n",marker);
    for(size_t i=0;i<sizeof(marker)-1;i++) {
        char changed[256];memcpy(changed,line,(size_t)n);changed[i]^=1;
        JuiceJITAck a=fresh();assert(!JuiceJITAckFeed(&a,changed,(size_t)n));
    }
    JuiceJITAck a=fresh();char junk[4096];memset(junk,'x',sizeof(junk));
    for(int i=0;i<1024;i++)assert(!JuiceJITAckFeed(&a,junk,sizeof(junk)));
    assert(!JuiceJITAckFeed(&a,marker,sizeof(marker)-1));
    assert(!JuiceJITAckFeed(&a,"\n",1));
    assert(JuiceJITAckFeed(&a,line,(size_t)n));
    a=fresh();assert(!JuiceJITAckFeed(&a,"\0",1));
    assert(!JuiceJITAckFeed(&a,line,(size_t)n));
    assert(JuiceJITAckFeed(&a,line,(size_t)n));
    assert(!JuiceJITAckInit(&a,"",0));
    assert(!JuiceJITAckInit(&a,"x\ny",3));
    assert(!JuiceJITAckInit(&a,junk,sizeof(junk)));
    /* Every event/foreground combination in 12^6 callback orderings. */
    unsigned count=1;for(int i=0;i<6;i++)count*=12;
    for(unsigned sequence=0;sequence<count;sequence++) {
        JuiceJITState s={.phase=JuiceJITOpening,.deadlineMS=100};
        unsigned code=sequence,resumes=0;
        bool observed=false,accepted=false,acknowledged=false;
        for(unsigned i=0;i<6;i++) {
            bool active=(code%12)>=6;
            JuiceJITEvent event=(JuiceJITEvent)(code%6);code/=12;
            JuiceJITPhase before=s.phase;
            observed|=event==JuiceJITDebugged;
            accepted|=event==JuiceJITOpenAccepted;
            acknowledged|=event==JuiceJITRuntimeAck;
            JuiceJITAction action=JuiceJITTransition(&s,event,i,true,active);
            resumes+=action==JuiceJITResume;assert(resumes<=1);
            if(action==JuiceJITResume)assert(active && observed && accepted);
            if(s.phase==JuiceJITReady && before!=JuiceJITReady)
                assert(active && observed && accepted && acknowledged && s.runtimeAcknowledged);
        }
    }
    printf("JUICE_JIT_ACK_TESTS_OK orderings=%u all_chunk_boundaries=1\n",count);
}
