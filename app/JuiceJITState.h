#ifndef JUICE_JIT_STATE_H
#define JUICE_JIT_STATE_H
#include <stdbool.h>
#include <stdint.h>

/* Pure transition logic shared by the UIKit coordinator and host regressions.
 * The caller validates the launch generation/PID on its owner queue before
 * delivering events or signalling. These states never grant OS permission.
 * Keep the original terminal values stable for existing diagnostic logs. */
typedef enum { JuiceJITOpening, JuiceJITAttaching, JuiceJITStarting,
               JuiceJITReady, JuiceJITCancelled, JuiceJITFailed,
               JuiceJITOpeningAuthorized, JuiceJITAuthorized } JuiceJITPhase;
typedef enum { JuiceJITTick, JuiceJITOpenAccepted, JuiceJITOpenRejected,
               JuiceJITDebugged, JuiceJITRuntimeAck, JuiceJITCancel } JuiceJITEvent;
typedef enum { JuiceJITNoAction, JuiceJITResume, JuiceJITStop } JuiceJITAction;
typedef struct { JuiceJITPhase phase; uint64_t deadlineMS; bool runtimeAcknowledged; } JuiceJITState;

static inline bool JuiceJITPending(JuiceJITState state)
{
    switch (state.phase) {
    case JuiceJITOpening: case JuiceJITAttaching: case JuiceJITStarting:
    case JuiceJITOpeningAuthorized: case JuiceJITAuthorized: return true;
    default: return false;
    }
}
static inline JuiceJITAction JuiceJITTransition(JuiceJITState *state,
    JuiceJITEvent event, uint64_t nowMS, bool ownsChild, bool foreground)
{
    if (!state) return JuiceJITNoAction;
    if (state->phase == JuiceJITReady || state->phase == JuiceJITCancelled ||
        state->phase == JuiceJITFailed) return JuiceJITNoAction;
    /* Revocation is checked before errors: never signal a stale numeric PID. */
    if (!ownsChild || event == JuiceJITCancel)
    { state->phase = JuiceJITCancelled; return JuiceJITNoAction; }
    if (!JuiceJITPending(*state) || (unsigned)event > JuiceJITCancel ||
        nowMS >= state->deadlineMS || event == JuiceJITOpenRejected)
    { state->phase = JuiceJITFailed; return JuiceJITStop; }

    if (event == JuiceJITRuntimeAck) state->runtimeAcknowledged = true;
    if (event == JuiceJITOpenAccepted) {
        if (state->phase == JuiceJITOpening) state->phase = JuiceJITAttaching;
        else if (state->phase == JuiceJITOpeningAuthorized) state->phase = JuiceJITAuthorized;
    }
    if (event == JuiceJITDebugged) {
        if (state->phase == JuiceJITOpening) state->phase = JuiceJITOpeningAuthorized;
        else if (state->phase == JuiceJITAttaching) state->phase = JuiceJITAuthorized;
    }

    /* Three independent conditions: URL handoff accepted, debugger status
     * observed for the owned child, and nonce-matched runtime acknowledgement.
     * The debugger may resume first, so remember out-of-order observations.
     * Neither readiness nor our SIGCONT is permitted while backgrounded. */
    if (!foreground) return JuiceJITNoAction;
    if (state->phase == JuiceJITAuthorized || state->phase == JuiceJITStarting) {
        if (state->runtimeAcknowledged) state->phase = JuiceJITReady;
        else if (state->phase == JuiceJITAuthorized) {
            state->phase = JuiceJITStarting;
            return JuiceJITResume;
        }
    }
    return JuiceJITNoAction;
}
#endif
