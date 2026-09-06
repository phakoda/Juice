#include "../JuiceJITState.h"
#include <assert.h>
#include <stdio.h>

static JuiceJITState fresh(void) { return (JuiceJITState){JuiceJITOpening, 120000, false}; }
static JuiceJITAction step(JuiceJITState *s, JuiceJITEvent e, uint64_t now, bool owns, bool active)
{ return JuiceJITTransition(s, e, now, owns, active); }

static void regressions(void)
{
    JuiceJITState s = fresh();
    assert(step(&s, JuiceJITDebugged, 0, true, true) == JuiceJITNoAction);
    assert(s.phase == JuiceJITOpeningAuthorized);
    assert(step(&s, JuiceJITOpenAccepted, 1, true, true) == JuiceJITResume);
    assert(s.phase == JuiceJITStarting);
    assert(step(&s, JuiceJITDebugged, 2, true, true) == JuiceJITNoAction);
    step(&s, JuiceJITRuntimeAck, 3, true, true);
    assert(s.phase == JuiceJITReady);
    assert(step(&s, JuiceJITOpenRejected, 4, true, true) == JuiceJITNoAction);

    /* An output marker is not proof of authorization. */
    s = fresh();
    step(&s, JuiceJITOpenAccepted, 1, true, true);
    step(&s, JuiceJITRuntimeAck, 2, true, true);
    assert(s.phase == JuiceJITAttaching);
    assert(step(&s, JuiceJITDebugged, 3, true, true) == JuiceJITNoAction);
    assert(s.phase == JuiceJITReady); /* Already resumed by debugger; no SIGCONT. */

    /* Preserve early acknowledgement but require handoff + authorization. */
    s = fresh();
    step(&s, JuiceJITRuntimeAck, 0, true, false);
    step(&s, JuiceJITDebugged, 1, true, false);
    step(&s, JuiceJITOpenAccepted, 2, true, false);
    assert(s.phase == JuiceJITAuthorized);
    step(&s, JuiceJITTick, 3, true, false);
    assert(s.phase == JuiceJITAuthorized);
    step(&s, JuiceJITTick, 4, true, true);
    assert(s.phase == JuiceJITReady);

    s = fresh();
    step(&s, JuiceJITOpenAccepted, 1, true, false);
    step(&s, JuiceJITDebugged, 2, true, false);
    assert(step(&s, JuiceJITTick, 3, true, true) == JuiceJITResume);
    step(&s, JuiceJITRuntimeAck, 4, true, false);
    assert(s.phase == JuiceJITStarting);
    step(&s, JuiceJITTick, 5, true, true);
    assert(s.phase == JuiceJITReady);

    s = fresh();
    assert(step(&s, JuiceJITOpenRejected, 1, true, true) == JuiceJITStop);
    assert(step(&s, JuiceJITOpenRejected, 2, true, true) == JuiceJITNoAction);
    s = fresh();
    assert(step(&s, JuiceJITTick, 120000, true, true) == JuiceJITStop);
    s = fresh();
    step(&s, JuiceJITOpenAccepted, 1, true, true);
    assert(step(&s, JuiceJITDebugged, 120001, true, true) == JuiceJITStop);
    s = fresh();
    step(&s, JuiceJITOpenAccepted, 1, true, true);
    assert(step(&s, JuiceJITDebugged, 2, false, true) == JuiceJITNoAction);
    assert(s.phase == JuiceJITCancelled);
    assert(step(&s, JuiceJITDebugged, 3, true, true) == JuiceJITNoAction);
    s = fresh();
    step(&s, JuiceJITCancel, 1, true, true);
    assert(step(&s, JuiceJITOpenAccepted, 2, true, true) == JuiceJITNoAction);
    s = fresh();
    assert(step(&s, (JuiceJITEvent)-1, 1, true, true) == JuiceJITStop);
    s = fresh(); s.phase = (JuiceJITPhase)99;
    assert(step(&s, JuiceJITTick, 0, false, true) == JuiceJITNoAction);
    assert(s.phase == JuiceJITCancelled);
    s = fresh(); s.deadlineMS = UINT64_MAX;
    assert(step(&s, JuiceJITTick, UINT64_MAX, true, true) == JuiceJITStop);
    assert(step(NULL, JuiceJITTick, 0, true, true) == JuiceJITNoAction);
}

int main(void)
{
    regressions();
    unsigned sequences = 1;
    for (unsigned i = 0; i < 7; ++i) sequences *= 6;
    for (unsigned mode = 0; mode < 8; ++mode)
    for (unsigned sequence = 0; sequence < sequences; ++sequence) {
        JuiceJITState s = fresh();
        unsigned code = sequence, resumes = 0, stops = 0;
        bool accepted = false, authorized = false, acknowledged = false;
        for (unsigned i = 0; i < 7; ++i) {
            JuiceJITEvent event = (JuiceJITEvent)(code % 6); code /= 6;
            bool owns = !(mode & 1) || i < 4;
            bool active = !(mode & 2) || i >= 3;
            uint64_t now = (mode & 4) ? i * 30000 : i;
            bool pending = JuiceJITPending(s);
            if (pending && owns && now < s.deadlineMS && event != JuiceJITCancel && event != JuiceJITOpenRejected) {
                accepted |= event == JuiceJITOpenAccepted;
                authorized |= event == JuiceJITDebugged;
                acknowledged |= event == JuiceJITRuntimeAck;
            }
            JuiceJITAction action = step(&s, event, now, owns, active);
            resumes += action == JuiceJITResume; stops += action == JuiceJITStop;
            assert(resumes <= 1 && stops <= 1);
            if (!owns || !pending) assert(action == JuiceJITNoAction);
            if (action == JuiceJITResume) assert(accepted && authorized && !acknowledged && active && owns);
            if (pending && s.phase == JuiceJITReady) assert(accepted && authorized && acknowledged && active && owns);
        }
    }
    printf("JUICE_JIT_STATE_TESTS_OK orderings=%u environments=8\n", sequences);
}
