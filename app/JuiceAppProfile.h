#ifndef JUICE_APP_PROFILE_H
#define JUICE_APP_PROFILE_H
#import <Foundation/Foundation.h>
NSString *JuiceProfilePrefixName(id owner, NSString *baseName);
NSArray<NSString *> *JuiceProfileEnvironment(id owner, NSArray<NSString *> *base);
/* nil means a saved working directory is no longer valid; launch must fail. */
NSString *JuiceProfileWorkingDirectory(id owner, NSString *fallback);
/* Non-nil when isolated-prefix preparation failed; launch must not fall back. */
NSString *JuiceProfilePreparationError(id owner);
BOOL JuiceProfileJITRequested(id owner);
#endif
