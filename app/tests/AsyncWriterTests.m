#import <Foundation/Foundation.h>
#import "../JuiceAsyncWriter.h"
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <sys/socket.h>
#import <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"%s:%d: %s errno=%d\n",__FILE__,__LINE__,#x,errno); abort(); } } while(0)

static NSData *ReadBytes(int fd,NSUInteger count)
{
    NSMutableData *data=[NSMutableData dataWithLength:count];
    uint8_t *cursor=data.mutableBytes;NSUInteger done=0;
    while(done<count)
    {
        struct pollfd p={.fd=fd,.events=POLLIN};CHECK(poll(&p,1,5000)>0);
        ssize_t n=read(fd,cursor+done,count-done);
        if(n<0&&errno==EINTR)continue;
        CHECK(n>0);done+=(NSUInteger)n;
    }
    return data;
}
static void OrderedCopies(void)
{
    int fd[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,fd));
    JuiceAsyncWriter *writer=[[JuiceAsyncWriter alloc]initWithFD:fd[0] socket:YES limit:65536 failure:nil];CHECK(writer);
    NSMutableData *expected=[NSMutableData data];
    for(unsigned i=0;i<100;i++)
    {
        NSMutableData *packet=[NSMutableData dataWithLength:32];memset(packet.mutableBytes,(int)i,packet.length);
        [expected appendData:packet];CHECK([writer enqueueData:packet]);memset(packet.mutableBytes,255,packet.length);
    }
    CHECK([ReadBytes(fd[1],expected.length) isEqualToData:expected]);
    CHECK(!(fcntl(fd[0],F_GETFL)&O_NONBLOCK));
    [writer cancel];close(fd[0]);close(fd[1]);
}
static void DescriptorReuse(void)
{
    int fd[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,fd));
    int borrowed=fd[0];
    JuiceAsyncWriter *writer=[[JuiceAsyncWriter alloc]initWithFD:borrowed socket:YES limit:4096 failure:nil];CHECK(writer);
    close(borrowed);
    int replacement[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,replacement));
    /* dup2 is safe here even when socketpair already reused borrowed. */
    if(replacement[0]!=borrowed){CHECK(dup2(replacement[0],borrowed)==borrowed);close(replacement[0]);}
    NSData *packet=[@"old connection only" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([writer enqueueData:packet]);CHECK([ReadBytes(fd[1],packet.length) isEqualToData:packet]);
    struct pollfd p={.fd=replacement[1],.events=POLLIN};CHECK(poll(&p,1,30)==0);
    [writer cancel];CHECK(![writer enqueueData:packet]);CHECK(errno==EPIPE);
    CHECK(write(borrowed,"new",3)==3);CHECK(ReadBytes(replacement[1],3).length==3);
    close(borrowed);close(fd[1]);close(replacement[1]);
}
static void BoundsAndPipe(void)
{
    int fd[2];CHECK(!pipe(fd));
    JuiceAsyncWriter *writer=[[JuiceAsyncWriter alloc]initWithFD:fd[1] socket:NO limit:4096 failure:nil];CHECK(writer);
    CHECK(![writer enqueueData:[NSMutableData dataWithLength:4097]]);CHECK(errno==ENOBUFS);
    NSData *packet=[@"command\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([writer enqueueData:packet]);CHECK([ReadBytes(fd[0],packet.length) isEqualToData:packet]);
    [writer cancel];close(fd[0]);close(fd[1]);
}
static void TimeoutAbandonsStream(void)
{
    int fd[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,fd));
    int size=4096;CHECK(!setsockopt(fd[0],SOL_SOCKET,SO_SNDBUF,&size,sizeof(size)));
    dispatch_semaphore_t failed=dispatch_semaphore_create(0);__block int failure=0;
    JuiceAsyncWriter *writer=[[JuiceAsyncWriter alloc]initWithFD:fd[0] socket:YES limit:2u*1024u*1024u failure:^(int error){failure=error;dispatch_semaphore_signal(failed);}];CHECK(writer);
    NSMutableData *packet=[NSMutableData dataWithLength:1024u*1024u];memset(packet.mutableBytes,'a',packet.length);
    double start=NSProcessInfo.processInfo.systemUptime;
    CHECK([writer enqueueData:packet]);
    CHECK([writer enqueueData:[@"MUST_NOT_FOLLOW" dataUsingEncoding:NSUTF8StringEncoding]]);
    CHECK(NSProcessInfo.processInfo.systemUptime-start<1.0);
    CHECK(!dispatch_semaphore_wait(failed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    CHECK(failure==ETIMEDOUT);
    CHECK(![writer enqueueData:packet]);CHECK(errno==EPIPE);
    char bytes[4096];ssize_t n;NSUInteger total=0;
    while((n=read(fd[1],bytes,sizeof(bytes)))>0)
    {for(ssize_t i=0;i<n;i++)CHECK(bytes[i]=='a');total+=(NSUInteger)n;}
    CHECK(n==0);CHECK(total>0&&total<packet.length);
    [writer cancel];close(fd[0]);close(fd[1]);
}
int main(void)
{
    @autoreleasepool
    {
        CHECK(signal(SIGPIPE,SIG_IGN)!=SIG_ERR);
        OrderedCopies();DescriptorReuse();BoundsAndPipe();TimeoutAbandonsStream();
        puts("JUICE_ASYNC_WRITER_TESTS_OK cases=4");
    }
    return 0;
}
