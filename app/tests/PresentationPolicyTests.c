#include "../JuicePresentationPolicy.h"
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void closeTo(double a, double b) { assert(fabs(a - b) < 0.00001); }
static uint64_t rng = 0x123456789abcdefULL;
static uint32_t random32(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)rng; }

int main(void)
{
    size_t bytes = 123;
    assert(JuicePixelLayoutValid(2, 3, 12, 36, &bytes) && bytes == 36);
    assert(!JuicePixelLayoutValid(2, 3, 7, 36, &bytes) && bytes == 0);
    assert(!JuicePixelLayoutValid(2, 3, 12, 35, &bytes));
    assert(!JuicePixelLayoutValid(INT_MAX, INT_MAX, UINT_MAX, SIZE_MAX, &bytes));
    assert(!JuicePixelLayoutValid(-1, 10, 40, 400, &bytes));
    assert(!JuicePixelLayoutValid(0, 10, 40, 400, &bytes));
    assert(!JuicePixelLayoutValid(8192, 8192, 32768, SIZE_MAX, &bytes));
    assert(JuicePixelLayoutValid(8192, 2048, 32768, 67108864, NULL));
    assert(!JuicePixelLayoutValid(1, 8192, UINT_MAX, SIZE_MAX, &bytes));

    for (unsigned cap = 0; cap <= 240; cap++)
        for (unsigned screen = 1; screen <= 240; screen++)
            for (unsigned thermal = 0; thermal <= 4; thermal++)
                for (unsigned low = 0; low <= 1; low++) {
                    unsigned fps = JuicePresentationFPS(cap, screen, thermal, low, true);
                    assert(fps && fps <= screen && fps <= 120);
                    if (thermal >= 2 || low) assert(fps <= 30);
                    if (thermal >= 3) assert(fps <= 15);
                    if (cap == 15 || cap == 30 || cap == 60 || cap == 120) assert(fps <= cap);
                    assert(!JuicePresentationFPS(cap, screen, thermal, low, false));
                }
    assert(JuicePresentationFPS(0, 120, 0, false, true) == 120);
    assert(JuicePresentationFPS(0, 0, 0, false, true) == 60);
    assert(JuicePresentationFPS(99, UINT_MAX, 0, false, true) == 60);

    double x = -1, y = -1;
    assert(JuiceAspectFitPoint(1000, 1000, 640, 480, 500, 500, &x, &y));
    closeTo(x, 320); closeTo(y, 240);
    assert(JuiceAspectFitPoint(1000, 1000, 640, 480, -100, 5000, &x, &y));
    closeTo(x, 0); closeTo(y, 479);
    assert(!JuiceAspectFitPoint(NAN, 10, 10, 10, 0, 0, &x, &y));
    assert(!JuiceAspectFitPoint(10, 0, 10, 10, 0, 0, &x, &y));
    assert(!JuiceAspectFitPoint(10, 10, 10, 10, INFINITY, 0, &x, &y));
    assert(!JuiceAspectFitPoint(10, 10, 10, 10, 0, 0, NULL, &y));

    JuiceVertex q[4];
    JuiceRect viewport = {10, 20, 100, 100}, window = {10, 20, 100, 100};
    assert(JuiceCompositeQuad(viewport, window, 100, 100, q));
    closeTo(q[0].x, -1); closeTo(q[0].y, 1); closeTo(q[0].u, 0); closeTo(q[0].v, 0);
    closeTo(q[3].x, 1); closeTo(q[3].y, -1); closeTo(q[3].u, 1); closeTo(q[3].v, 1);
    /* Stale larger backing is clipped, never scaled to the new window geometry. */
    window.width = 50; window.height = 25;
    assert(JuiceCompositeQuad(viewport, window, 100, 100, q));
    closeTo(q[3].x, 0); closeTo(q[3].y, 0.5); closeTo(q[3].u, 0.5); closeTo(q[3].v, 0.25);
    /* Negative window origin clips the source UVs as well as destination position. */
    window = (JuiceRect){-40, -30, 100, 100};
    assert(JuiceCompositeQuad(viewport, window, 100, 100, q));
    closeTo(q[0].u, 0.5); closeTo(q[0].v, 0.5);
    assert(!JuiceCompositeQuad(viewport, (JuiceRect){1000, 1000, 10, 10}, 10, 10, q));
    assert(!JuiceCompositeQuad((JuiceRect){NAN, 0, 100, 100}, window, 100, 100, q));
    assert(!JuiceCompositeQuad(viewport, window, 0, 100, q));

    for (unsigned i = 0; i < 100000; i++) {
        int width = (int)(random32() % 10000) - 1000;
        int height = (int)(random32() % 10000) - 1000;
        uint32_t stride = random32();
        if (JuicePixelLayoutValid(width, height, stride, SIZE_MAX, &bytes)) {
            assert(width > 0 && height > 0 && bytes <= 128ULL * 1024 * 1024);
            assert(bytes == (uint64_t)stride * (unsigned)height);
        }
        JuiceRect w = {(int)(random32() % 20000) - 10000,
                       (int)(random32() % 20000) - 10000,
                       random32() % 9000, random32() % 9000};
        if (JuiceCompositeQuad((JuiceRect){0, 0, 4096, 4096}, w, 2048, 2048, q))
            for (unsigned j = 0; j < 4; j++) {
                assert(q[j].x >= -1 && q[j].x <= 1 && q[j].y >= -1 && q[j].y <= 1);
                assert(q[j].u >= 0 && q[j].u <= 1 && q[j].v >= 0 && q[j].v <= 1);
            }
    }
    assert(JuiceSnapshotDelay(0, 100, 60) == 0);
    assert(JuiceSnapshotDelay(100, 99, 60) == 0);
    assert(JuiceSnapshotDelay(100, 100, 60) == 16666666);
    assert(JuiceSnapshotDelay(1, UINT64_MAX, 60) == 0);
    assert(JuiceSnapshotDelay(100, 100, 0) == 66666666);
    JuiceSetSnapshotFPS(120); assert(JuiceGetSnapshotFPS() == 120);
    JuiceSetSnapshotFPS(UINT_MAX); assert(JuiceGetSnapshotFPS() == 240);
    puts("PRESENTATION_POLICY_OK matrices=578400 geometry_mutations=100000");
    return 0;
}
