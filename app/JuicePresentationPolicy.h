#ifndef JUICE_PRESENTATION_POLICY_H
#define JUICE_PRESENTATION_POLICY_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Platform-independent policy shared by the production renderer and tests. */
typedef struct { double x, y, width, height; } JuiceRect;
typedef struct { float x, y, u, v; } JuiceVertex;
bool JuicePixelLayoutValid(int width, int height, uint32_t stride,
                           size_t available, size_t *required);
/* thermal: 0=nominal, 1=fair, 2=serious, 3=critical. Never raises a user cap. */
unsigned JuicePresentationFPS(unsigned requested, unsigned screenMaximum,
                              unsigned thermal, bool lowPower, bool active);
bool JuiceAspectFitPoint(double viewWidth, double viewHeight,
                         double contentWidth, double contentHeight,
                         double x, double y, double *mappedX, double *mappedY);
/* Preserve one source pixel per desktop unit, clip rather than stretch on resize. */
bool JuiceCompositeQuad(JuiceRect viewport, JuiceRect window,
                        unsigned imageWidth, unsigned imageHeight,
                        JuiceVertex vertices[4]);
/* Returns time until the next CPU snapshot; zero for first frames/clock reset. */
uint64_t JuiceSnapshotDelay(uint64_t previousNS, uint64_t nowNS, unsigned fps);
void JuiceSetSnapshotFPS(unsigned fps);
unsigned JuiceGetSnapshotFPS(void);
#endif
