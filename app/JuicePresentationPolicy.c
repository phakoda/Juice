#include "JuicePresentationPolicy.h"
#include <math.h>
#include <stdatomic.h>

static atomic_uint snapshotFPS = 60;

bool JuicePixelLayoutValid(int width, int height, uint32_t stride,
                           size_t available, size_t *required)
{
    if (required) *required = 0;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) return false;
    if ((uint64_t)(unsigned)width * (unsigned)height > 4096ULL * 4096ULL) return false;
    if (stride < (uint64_t)(unsigned)width * 4) return false;
    uint64_t bytes = (uint64_t)stride * (unsigned)height;
    if (bytes > 128ULL * 1024 * 1024 || bytes > SIZE_MAX || bytes > available) return false;
    if (required) *required = (size_t)bytes;
    return true;
}

unsigned JuicePresentationFPS(unsigned requested, unsigned maximum,
                              unsigned thermal, bool lowPower, bool active)
{
    if (!active) return 0;
    if (!maximum || maximum > 240) maximum = 60;
    unsigned fps = requested;
    if (!fps) fps = maximum < 120 ? maximum : 120;
    else if (fps != 15 && fps != 30 && fps != 60 && fps != 120) fps = 60;
    if (fps > maximum) fps = maximum;
    if ((lowPower || thermal >= 2) && fps > 30) fps = 30;
    if (thermal >= 3 && fps > 15) fps = 15;
    return fps;
}

bool JuiceAspectFitPoint(double vw, double vh, double cw, double ch,
                         double x, double y, double *mx, double *my)
{
    if (!mx || !my || !isfinite(vw) || !isfinite(vh) || !isfinite(cw) ||
        !isfinite(ch) || !isfinite(x) || !isfinite(y) ||
        vw <= 0 || vh <= 0 || cw < 1 || ch < 1 || cw > 8192 || ch > 8192) return false;
    double scale = fmin(vw / cw, vh / ch);
    if (!isfinite(scale) || scale <= 0) return false;
    *mx = fmax(0, fmin(cw - 1, (x - (vw - cw * scale) / 2) / scale));
    *my = fmax(0, fmin(ch - 1, (y - (vh - ch * scale) / 2) / scale));
    return isfinite(*mx) && isfinite(*my);
}

static bool validRect(JuiceRect r)
{
    return isfinite(r.x) && isfinite(r.y) && isfinite(r.width) && isfinite(r.height) &&
        fabs(r.x) <= 131072 && fabs(r.y) <= 131072 &&
        r.width >= 1 && r.height >= 1 && r.width <= 8192 && r.height <= 8192;
}

bool JuiceCompositeQuad(JuiceRect v, JuiceRect w, unsigned iw, unsigned ih,
                        JuiceVertex out[4])
{
    if (!out || !validRect(v) || !validRect(w) || !iw || !ih || iw > 8192 || ih > 8192)
        return false;
    double left = fmax(v.x, w.x), top = fmax(v.y, w.y);
    double right = fmin(v.x + v.width, w.x + fmin(w.width, iw));
    double bottom = fmin(v.y + v.height, w.y + fmin(w.height, ih));
    if (left >= right || top >= bottom) return false;
    float x0 = (float)(2 * (left - v.x) / v.width - 1);
    float x1 = (float)(2 * (right - v.x) / v.width - 1);
    float y0 = (float)(1 - 2 * (top - v.y) / v.height);
    float y1 = (float)(1 - 2 * (bottom - v.y) / v.height);
    float u0 = (float)((left - w.x) / iw), u1 = (float)((right - w.x) / iw);
    float t0 = (float)((top - w.y) / ih), t1 = (float)((bottom - w.y) / ih);
    out[0] = (JuiceVertex){x0, y0, u0, t0};
    out[1] = (JuiceVertex){x0, y1, u0, t1};
    out[2] = (JuiceVertex){x1, y0, u1, t0};
    out[3] = (JuiceVertex){x1, y1, u1, t1};
    return true;
}

uint64_t JuiceSnapshotDelay(uint64_t previous, uint64_t now, unsigned fps)
{
    if (!previous || now < previous) return 0;
    if (!fps) fps = 15; /* Background safety ceiling; never divide by zero. */
    if (fps > 240) fps = 240;
    uint64_t interval = 1000000000ULL / fps;
    uint64_t elapsed = now - previous;
    return elapsed >= interval ? 0 : interval - elapsed;
}
void JuiceSetSnapshotFPS(unsigned fps)
{
    if (fps > 240) fps = 240;
    atomic_store_explicit(&snapshotFPS, fps, memory_order_relaxed);
}
unsigned JuiceGetSnapshotFPS(void)
{
    return atomic_load_explicit(&snapshotFPS, memory_order_relaxed);
}
