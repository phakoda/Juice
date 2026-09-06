#import <Foundation/Foundation.h>
#import <assert.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../JuiceAsyncWriter.h"
#import "../JuiceKeyChord.h"

@interface TestSelection : NSObject
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) int clientFD;
@end
@implementation TestSelection
@end
@interface TestInputOwner : NSObject
@property(nonatomic,strong) TestSelection *canvas;
@property(nonatomic,strong) NSMutableDictionary *wineWindows;
@property(nonatomic,strong) NSMutableArray *clients;
@property(nonatomic) int activeClient;
- (void)append:(NSString *)line;
@end
@implementation TestInputOwner
- (void)append:(NSString *)line { (void)line; }
@end
static void ReadExact(int fd,void *bytes,size_t length)
{
    uint8_t *cursor=bytes;
    while(length) {
        struct pollfd p={.fd=fd,.events=POLLIN}; assert(poll(&p,1,2000)==1);
        ssize_t got=read(fd,cursor,length); assert(got>0);
        cursor+=got; length-=(size_t)got;
    }
}
int main(void)
{
    @autoreleasepool {
        int first[2],other[2]; assert(!socketpair(AF_UNIX,SOCK_STREAM,0,first));
        assert(!socketpair(AF_UNIX,SOCK_STREAM,0,other));
        TestInputOwner *owner=[TestInputOwner new]; owner.canvas=[TestSelection new]; owner.canvas.hwnd=0x1234;
        TestSelection *state=[TestSelection new]; state.hwnd=0x1234; state.clientFD=first[0];
        owner.wineWindows=[@{@0x1234:state} mutableCopy];
        owner.clients=[@[@(first[0]),@(other[0])] mutableCopy];
        owner.activeClient=other[0]; /* Last active is deliberately the wrong route. */
        assert(JuiceQueueKeyChord(owner,0x2e,0x53,YES,JUICE_CHORD_CONTROL|JUICE_CHORD_ALT));
        JuiceKeyPacket actual[6],expected[JUICE_CHORD_MAX_MESSAGES]; ReadExact(first[1],actual,sizeof(actual));
        assert(JuiceBuildKeyChord(0x1234,0x2e,0x53,true,3,expected,10)==6);
        assert(!memcmp(actual,expected,sizeof(actual)));
        struct pollfd wrong={.fd=other[1],.events=POLLIN}; assert(poll(&wrong,1,0)==0);
        owner.canvas.hwnd=0x5678; assert(!JuiceQueueKeyChord(owner,65,30,NO,1));
        owner.canvas.hwnd=0x1234;
        @synchronized(owner.clients) {
            [owner.clients removeObject:@(first[0])]; JuiceCancelDisplayWriter(owner,first[0]);
        }
        assert(!JuiceQueueKeyChord(owner,65,30,NO,1));
        assert(!JuiceQueueKeyChord(owner,65,0,NO,1));
        for(int i=0;i<2;i++) { close(first[i]); close(other[i]); }
        puts("INPUT_BATCH_TESTS_OK production-writer selected-hwnd atomic-batch stale-route disconnected-route");
    }
    return 0;
}
