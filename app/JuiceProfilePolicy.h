#ifndef JUICE_PROFILE_POLICY_H
#define JUICE_PROFILE_POLICY_H
#include <stdbool.h>
#include <stddef.h>
/* Bounded Wine override grammar: module[,module]*=n|b|native|builtin;
 * up to two distinct orders. An empty order disables the named modules. */
bool JuiceDLLOverridesValid(const char *text, size_t length);
#endif
