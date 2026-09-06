#include "graphics_layout.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void store32(unsigned char *p,uint32_t v)
{ for(unsigned i=0;i<4;i++) p[i]=(unsigned char)(v>>(i*8)); }
int main(void)
{
    struct ios_graphics_layout p;
    assert(ios_graphics_layout(4096,4096,256,&p));
    assert(p.stride==16384 && p.size==67108864);
    assert(ios_graphics_layout(8192,2048,256,&p));
    assert(!ios_graphics_layout(8192,2049,256,&p));
    assert(!p.size && !p.stride);
    assert(!ios_graphics_layout(UINT64_MAX,2,256,&p));
    assert(!ios_graphics_layout(1,UINT64_MAX,256,&p));
    assert(!ios_graphics_layout(0,1,256,&p));
    assert(!ios_graphics_layout(1,1,0,&p));
    assert(!ios_graphics_layout(1,1,3,&p));
    assert(!ios_graphics_layout(1,1,SIZE_MAX,&p));
    assert(!ios_graphics_layout(1,1,1,NULL));
    size_t used=0;
    assert(ios_graphics_budget_reserve(&used,IOS_GRAPHICS_MAX_BYTES));
    assert(ios_graphics_budget_reserve(&used,IOS_GRAPHICS_MAX_BYTES));
    assert(!ios_graphics_budget_reserve(&used,1));
    assert(used==IOS_GRAPHICS_TOTAL_BYTES);
    used-=IOS_GRAPHICS_MAX_BYTES;
    assert(ios_graphics_budget_reserve(&used,1));
    used=SIZE_MAX;assert(!ios_graphics_budget_reserve(&used,1));
    unsigned char pixel[8];
    for(unsigned c=0;c<1024;c++)for(unsigned alpha=0;alpha<4;alpha++) {
        unsigned char expected=(unsigned char)((double)c*255.0/1023.0+0.5);
        for(int f=IOS_PIXEL_RGB10A2;f<=IOS_PIXEL_BGR10A2;f++)for(unsigned channel=0;channel<3;channel++) {
            store32(pixel+1,(c<<(channel*10))|(alpha<<30));
            pixel[0]=pixel[5]=0x9a;
            assert(ios_graphics_pack_bgra(pixel+1,4,1,1,4,(enum ios_pixel_format)f));
            unsigned index=f==IOS_PIXEL_RGB10A2?2-channel:channel;
            for(unsigned i=0;i<3;i++)assert(pixel[1+i]==(i==index?expected:0));
            assert(pixel[4]==alpha*85 && pixel[0]==0x9a && pixel[5]==0x9a);
        }
    }
    uint32_t seed=7;
    for(unsigned width=1;width<=65;width++)for(unsigned height=1;height<=17;height++) {
        assert(ios_graphics_layout(width,height,256,&p));
        unsigned char *storage=malloc(p.size+2),*expected=malloc(width*height*4);
        assert(storage && expected);
        for(int f=IOS_PIXEL_BGRA8;f<=IOS_PIXEL_RGBA8;f++) {
            memset(storage,0xdb,p.size+2);
            for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
                unsigned char values[4];
                for(unsigned k=0;k<4;k++) {seed=seed*1664525+1013904223;values[k]=(unsigned char)(seed>>24);}
                memcpy(storage+1+y*p.stride+x*4,values,4);
                size_t at=(y*width+x)*4;
                expected[at]=values[f==IOS_PIXEL_RGBA8?2:0];
                expected[at+1]=values[1];expected[at+2]=values[f==IOS_PIXEL_RGBA8?0:2];expected[at+3]=values[3];
            }
            assert(!ios_graphics_pack_bgra(storage+1,p.size-1,width,height,p.stride,(enum ios_pixel_format)f));
            assert(ios_graphics_pack_bgra(storage+1,p.size,width,height,p.stride,(enum ios_pixel_format)f));
            assert(!memcmp(storage+1,expected,width*height*4));
            assert(storage[0]==0xdb && storage[p.size+1]==0xdb);
        }
        free(expected);free(storage);
    }
    unsigned char saved[8]={0};
    assert(!ios_graphics_pack_bgra(saved,8,1,1,4,IOS_PIXEL_UNSUPPORTED));
    assert(!ios_graphics_pack_bgra(saved,8,1,1,SIZE_MAX,IOS_PIXEL_BGRA8));
    assert(!ios_graphics_pack_bgra(saved,8,UINT32_MAX,1,4,IOS_PIXEL_BGRA8));
    assert(!ios_graphics_pack_bgra(NULL,8,1,1,4,IOS_PIXEL_BGRA8));
    puts("JUICE_GRAPHICS_LAYOUT_TESTS_OK channel_cases=24576 padded_images=2210");
}
