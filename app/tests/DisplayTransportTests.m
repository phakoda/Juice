/* Compile and exercise the production framebuffer implementation, not a copy. */
#import "../JuiceDisplayTransportHardening.m"
#import <assert.h>

int main(void)
{
    @autoreleasepool
    {
        NSObject *owner=[NSObject new];
        JuiceDisplayMsg full={JUICE_DISPLAY_MAGIC,JUICE_DISPLAY_FRAME,48,1,0,0,4,3,16,0};
        NSMutableData *original=[NSMutableData dataWithLength:48];
        JuiceDisplayFramebuffer *frame=JuiceApplyFull(owner,full,original,7,100);
        assert(frame&&frame.bytes==original);
        NSMutableData *replacement=[NSMutableData dataWithLength:48];
        memset(replacement.mutableBytes,0x44,48);
        assert(JuiceApplyFull(owner,full,replacement,7,100)==frame);
        assert(frame.bytes==replacement&&((const uint8_t *)original.bytes)[0]==0);
        puts("PASS full frames transfer backing storage without a redundant copy");

        JuiceDisplayMsg dirty={JUICE_DISPLAY_MAGIC,JUICE_DISPLAY_FRAME,4,1,1,1,1,1,4,JUICE_DISPLAY_DIRTY};
        const uint8_t pixel[]={1,2,3,4};NSData *data=[NSData dataWithBytes:pixel length:4];
        assert(!JuiceApplyDirty(owner,dirty,data,8,100));
        assert(!JuiceApplyDirty(owner,dirty,data,7,101));
        assert(((const uint8_t *)frame.bytes.bytes)[20]==0x44);
        assert(JuiceApplyDirty(owner,dirty,data,7,100)==frame);
        assert(memcmp((const uint8_t *)frame.bytes.bytes+20,pixel,4)==0);
        dirty.x=4;assert(!JuiceApplyDirty(owner,dirty,data,7,100));
        puts("PASS dirty rectangles require the matching baseline owner and bounds");

        JuiceInvalidateHWND(owner,1,8);assert(JuiceDisplayFrames(owner)[@1]==frame);
        JuiceInvalidateHWND(owner,1,7);assert(!JuiceDisplayFrames(owner)[@1]);
        assert(frame.invalidated);puts("PASS stale owners cannot destroy a replacement framebuffer");
        JuiceDisplayMsg invalid=full;invalid.stride=UINT32_MAX;
        assert(!JuiceFullHeaderValid(invalid));invalid=full;invalid.width=-1;
        assert(!JuiceFullHeaderValid(invalid));invalid=full;invalid.size--;
        assert(!JuiceFullHeaderValid(invalid));
        puts("PASS malformed dimensions, stride and payload size");

        assert(JuiceReserveDisplayPayload(owner,JUICE_DISPLAY_MAX_BYTES));
        assert(!JuiceReserveDisplayPayload(owner,1));
        JuiceReleaseDisplayPayload(owner,JUICE_DISPLAY_MAX_BYTES);
        assert(JuiceReserveDisplayPayload(owner,1));JuiceReleaseDisplayPayload(owner,1);
        JuiceDisplayMsg tiny={JUICE_DISPLAY_MAGIC,JUICE_DISPLAY_FRAME,4,0,0,0,1,1,4,0};
        for(unsigned i=1;i<=JUICE_DISPLAY_MAX_RETAINED_WINDOWS;i++)
        {
            tiny.hwnd=i;
            assert(JuiceApplyFull(owner,tiny,[NSMutableData dataWithLength:4],7,100));
        }
        tiny.hwnd=1000;assert(!JuiceApplyFull(owner,tiny,[NSMutableData dataWithLength:4],7,100));
        tiny.hwnd=1;assert(JuiceApplyFull(owner,tiny,[NSMutableData dataWithLength:4],7,100));
        JuiceInvalidateClient(owner,7);assert(JuiceDisplayFrames(owner).count==0);
        tiny.hwnd=1000;assert(JuiceApplyFull(owner,tiny,[NSMutableData dataWithLength:4],7,100));
        puts("PASS aggregate in-flight and retained-window budgets recover after teardown");
        puts("JUICE_DISPLAY_TRANSPORT_TESTS_OK");
    }
}
