#import <UIKit/UIKit.h>

void JuiceSideStoreAttach(id controller);
void JuiceSideStoreLaunch(id controller);
void JuiceSideStoreStop(id controller, NSString *reason);
void JuiceSideStoreEnableJIT(id controller);
BOOL JuiceSideStoreRuntimeActive(void);
NSArray<NSString *> *JuiceSideStoreParseArguments(NSString *line, NSString **error);
