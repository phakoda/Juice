#ifndef JUICE_JIT_STATE_H
#define JUICE_JIT_STATE_H
#include <stdbool.h>
#include <stdint.h>

/* Pure transition logic shared by the UIKit coordinator and host regressions.
 * Identity is checked by the caller on the same queue as signals and reaping.
 * Debugger permission alone never means the Wine/FEX runtime is ready. */
typedef enum { JuiceJITOpening, JuiceJITAttaching, JuiceJITStarting,
               JuiceJITReady, JuiceJITCancelled, JuiceJITFailed } JuiceJITPhase;
typedef enum { JuiceJITTick, JuiceJITOpenAccepted, JuiceJITOpenRejected,
               JuiceJITDebugged, JuiceJITRuntimeAck, JuiceJITCancel } JuiceJITEvent;
typedef enum { JuiceJITNoAction, JuiceJITResume, JuiceJITStop } JuiceJITAction;
typedef struct { JuiceJITPhase phase; uint64_t deadlineMS; bool runtimeAcknowledged; } JuiceJITState;

static inline bool JuiceJITPending(JuiceJITState state)
{
    return state.phase <= JuiceJITStarting;
}
static inline JuiceJITAction JuiceJITTransition(JuiceJITState *state,
    JuiceJITEvent event, uint64_t nowMS, bool ownsChild, bool foreground)
{
    if (!JuiceJITPending(*state)) return JuiceJITNoAction;
    if (!ownsChild || event == JuiceJITCancel)
    { state->phase = JuiceJITCancelled; return JuiceJITNoAction; }
    if (nowMS >= state->deadlineMS || event == JuiceJITOpenRejected)
    { state->phase = JuiceJITFailed; return JuiceJITStop; }
    if (event == JuiceJITRuntimeAck) state->runtimeAcknowledged = true;
    if (event == JuiceJITOpenAccepted && state->phase == JuiceJITOpening)
        state->phase = JuiceJITAttaching;
    /* The debugger may itself resume the stopped process. An acknowledged
     * runtime can therefore complete from Attaching as well as Starting. */
    if (state->runtimeAcknowledged && state->phase != JuiceJITOpening)
        state->phase = JuiceJITReady;
    if (event == JuiceJITDebugged && foreground && state->phase == JuiceJITAttaching)
    { state->phase = JuiceJITStarting; return JuiceJITResume; }
    return JuiceJITNoAction;
}
#endif
