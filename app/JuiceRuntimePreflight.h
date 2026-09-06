#ifndef JUICE_RUNTIME_PREFLIGHT_H
#define JUICE_RUNTIME_PREFLIGHT_H
#import <Foundation/Foundation.h>
/* Known prerequisites only, not all dependencies or a compatibility guarantee.
 * Call after choosing a runtime and before spawning wineserver. */
NSDictionary<NSString *, id> *JuiceRuntimePreflight(NSString *executable, NSString *runtime,
                                                 BOOL x64, BOOL win32);
#endif
