#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Owns a CLOEXEC duplicate, not the caller's descriptor. Sets O_NONBLOCK on
 * the shared open-file description; concurrent readers MUST handle EAGAIN.
 * Enqueue success means
 * accepted, not delivered. Frames are ordered per connection and never
 * interleaved. A timeout/partial-write failure shuts down a socket. */
@interface JuiceAsyncWriter : NSObject
- (nullable instancetype)initWithFD:(int)fd
                            socket:(BOOL)socket
                             limit:(NSUInteger)limit
                           failure:(nullable void (^)(int error))failure;
- (BOOL)enqueueData:(NSData *)data;
- (void)cancel;
@end

/* Call while removing display send membership, BEFORE close/reuse of fd. */
void JuiceCancelDisplayWriter(id controller, int fd);

NS_ASSUME_NONNULL_END
