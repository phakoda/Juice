#define _POSIX_C_SOURCE 200809L
#include "../JuiceSocketIO.h"
#include "../JuiceUTF16.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void pause_ms(long ms)
{
    struct timespec delay = { ms / 1000, (ms % 1000) * 1000000 };
    while (nanosleep(&delay, &delay) < 0 && errno == EINTR) {}
}
struct producer { int fd; size_t count; long delay; pthread_t reader; int interrupt; };
static void *produce(void *argument)
{
    struct producer *p = argument;
    for (size_t i = 0; i < p->count; i++)
    {
        pause_ms(p->delay);
        if (p->interrupt) { pthread_kill(p->reader, SIGUSR1); continue; }
        unsigned char value = (unsigned char)i;
        if (send(p->fd, &value, 1, 0) != 1) break;
    }
    return NULL;
}
static void ignore_signal(int signal_number) { (void)signal_number; }
static void pair(int sockets[2]) { assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0); }
static void done(int sockets[2]) { close(sockets[0]); close(sockets[1]); }
int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action = {0};
    action.sa_handler = ignore_signal;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGUSR1, &action, NULL) == 0);
    alarm(20);
    int sockets[2]; unsigned char buffer[128]; pthread_t worker;

    pair(sockets);
    struct producer p = { sockets[1], 64, 1, pthread_self(), 0 };
    assert(pthread_create(&worker, NULL, produce, &p) == 0);
    assert(JuiceSocketTransferUntil(sockets[0], buffer, 64, 0, JuiceSocketNowMS()+2000));
    for (size_t i=0;i<64;i++) assert(buffer[i] == i);
    pthread_join(worker, NULL); done(sockets);
    puts("PASS fragmented header/payload exact read");

    pair(sockets);
    p = (struct producer){sockets[1], 15, 20, pthread_self(), 0};
    assert(pthread_create(&worker, NULL, produce, &p) == 0);
    int64_t started=JuiceSocketNowMS();
    assert(!JuiceSocketTransferUntil(sockets[0], buffer, 15, 0, started+100));
    assert(errno == ETIMEDOUT && JuiceSocketNowMS()-started < 1500);
    shutdown(sockets[0], SHUT_RDWR); pthread_join(worker,NULL); done(sockets);
    puts("PASS trickle cannot extend absolute deadline");

    pair(sockets);
    p = (struct producer){sockets[1], 20, 5, pthread_self(), 1};
    assert(pthread_create(&worker,NULL,produce,&p)==0);
    assert(!JuiceSocketTransferUntil(sockets[0],buffer,1,0,JuiceSocketNowMS()+75));
    assert(errno == ETIMEDOUT);
    pthread_join(worker,NULL);done(sockets);
    puts("PASS interrupted poll preserves deadline");

    pair(sockets);
    int tiny=4096; assert(setsockopt(sockets[0],SOL_SOCKET,SO_SNDBUF,&tiny,sizeof(tiny))==0);
    size_t length=4u*1024u*1024u; unsigned char *large=malloc(length); assert(large);
    memset(large,0x5a,length);
    assert(!JuiceSocketTransferUntil(sockets[0],large,length,1,JuiceSocketNowMS()+100));
    assert(errno==ETIMEDOUT); free(large); done(sockets);
    puts("PASS stalled short write times out");

    pair(sockets);close(sockets[1]);
    assert(!JuiceSocketTransferUntil(sockets[0],buffer,1,0,JuiceSocketNowMS()+100));
    assert(errno==ECONNRESET);
    assert(!JuiceSocketTransferUntil(sockets[0],buffer,1,1,JuiceSocketNowMS()+100));
    assert(errno==EPIPE || errno==ECONNRESET);close(sockets[0]);
    puts("PASS EOF and disconnected write");

    pair(sockets);
    assert(JuiceSocketTransferUntil(sockets[0],NULL,0,1,JuiceSocketNowMS()+100));
    assert(!JuiceSocketTransferUntil(sockets[0],NULL,1,1,JuiceSocketNowMS()+100));
    assert(errno==EINVAL); done(sockets);
    puts("PASS zero length and invalid arguments");

    /* Exercise the production text chunker at every position around a 60 KiB
     * boundary, including a supplementary character spanning that boundary. */
    size_t capacity=60u*1024u;
    unsigned char *text=calloc(capacity+16,1); assert(text);
    for(size_t pairStart=capacity-8;pairStart<=capacity+8;pairStart+=2)
    {
        memset(text,0,capacity+16);
        text[pairStart]=0x3d;text[pairStart+1]=0xd8;
        text[pairStart+2]=0x00;text[pairStart+3]=0xde;
        size_t offset=0;
        while(offset<capacity+16)
        {
            size_t n=JuiceUTF16ChunkLength(text+offset,capacity+16-offset,capacity);
            assert(n && !(n&1) && n<=capacity);
            assert(offset+n!=pairStart+2);
            offset+=n;
        }
        assert(offset==capacity+16);
    }
    assert(JuiceUTF16ChunkLength(text,3,2)==0);
    assert(JuiceUTF16ChunkLength(NULL,2,2)==0);
    unsigned char emoji[]={0x3d,0xd8,0x00,0xde};
    assert(JuiceUTF16ChunkLength(emoji,4,2)==0);
    assert(JuiceUTF16ChunkLength(emoji,4,4)==4);
    free(text);
    puts("PASS UTF-16 surrogate-safe chunk boundaries");
    puts("JUICE_SOCKET_IO_TESTS_OK");
    return 0;
}
