#include "../JuiceKeyChord.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    JuiceKeyPacket frames[JUICE_CHORD_MAX_MESSAGES], before[JUICE_CHORD_MAX_MESSAGES];
    memset(frames, 0xa5, sizeof(frames)); memcpy(before, frames, sizeof(frames));
    assert(!JuiceBuildKeyChord(0, 65, 30, false, 0, frames, 10));
    assert(!JuiceBuildKeyChord(1, 0, 30, false, 0, frames, 10));
    assert(!JuiceBuildKeyChord(1, 256, 30, false, 0, frames, 10));
    assert(!JuiceBuildKeyChord(1, 65, 0, false, 0, frames, 10));
    assert(!JuiceBuildKeyChord(1, 65, 128, false, 0, frames, 10));
    assert(!JuiceBuildKeyChord(1, 65, 30, false, 16, frames, 10));
    assert(!JuiceBuildKeyChord(1, 65, 30, false, 0, NULL, 10));
    assert(!JuiceBuildKeyChord(1, 65, 30, false, 15, frames, 9));
    assert(!memcmp(frames, before, sizeof(frames)));
    size_t cases = 0;
    for (unsigned key=1;key<=255;key++) for(unsigned modifiers=0;modifiers<16;modifiers++)
        for(unsigned extended=0;extended<2;extended++) {
            size_t n = JuiceBuildKeyChord(UINT64_MAX, key, 30, extended, modifiers, frames, 10);
            if (!n) {
                assert(key==0x10 || key==0x11 || key==0x12 || key==0x5b || key==0x5c ||
                       (key>=0xa0 && key<=0xa5)); continue;
            }
            int held[256]={0}; unsigned downs=0, ups=0;
            assert(n>=2 && n<=10 && !(n%2));
            for(size_t i=0;i<n;i++) {
                JuiceKeyPacket f=frames[i];
                assert(f.magic==0x4a554943u && f.type==103 && f.hwnd==UINT64_MAX);
                assert(!f.size && !f.width && !f.height && !f.stride);
                assert(f.x>0 && f.x<=255 && f.y>0 && f.y<=127 && (f.flags & 3u));
                const unsigned char *raw=(const unsigned char *)&frames[i];
                assert(!raw[12] && !raw[13] && !raw[14] && !raw[15]);
                if(f.flags & 1) { assert(!held[f.x]); held[f.x]++; downs++; }
                else { assert(held[f.x]==1); held[f.x]--; ups++; }
            }
            assert(downs==ups);
            for(unsigned i=0;i<256;i++) assert(!held[i]);
            for(size_t i=0;i<n/2;i++) {
                assert(frames[i].x==frames[n-1-i].x);
                assert((frames[i].flags ^ frames[n-1-i].flags)==3);
            }
            cases++;
        }
    size_t n=JuiceBuildKeyChord(9,0x2e,0x53,true,JUICE_CHORD_CONTROL|JUICE_CHORD_ALT,frames,10);
    assert(n==6 && frames[2].x==0x2e && frames[2].flags==5 && frames[3].flags==6);
    printf("KEY_CHORD_TESTS_OK balanced_cases=%zu selected_hwnd padding bounds modifiers\n", cases);
    return 0;
}
