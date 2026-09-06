#import "JuiceAsyncWriter.h"
#import "JuiceIO.h"
#import "JuiceSocketIO.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>

#define JUICE_IO_GLOBAL_BYTES (8u * 1024u * 1024u)
#define JUICE_IO_MAX_PACKETS 512u
#define JUICE_IO_WRITE_TIMEOUT_MS 2000u

static atomic_size_t JuiceBufferedBytes;

static BOOL JuiceReserveBytes(size_t length)
{
    size_t total = atomic_load_explicit(&JuiceBufferedBytes, memory_order_relaxed);
    do
    {
        if (length > JUICE_IO_GLOBAL_BYTES || total > JUICE_IO_GLOBAL_BYTES - length)
            return NO;
    } while (!atomic_compare_exchange_weak_explicit(&JuiceBufferedBytes, &total,
                 total + length, memory_order_relaxed, memory_order_relaxed));
    return YES;
}

@implementation JuiceAsyncWriter
{
    int _fd;
    BOOL _socket;
    NSUInteger _limit, _queuedBytes, _queuedPackets;
    atomic_bool _cancelled;
    dispatch_queue_t _queue;
    void (^_failure)(int);
}

- (instancetype)initWithFD:(int)fd socket:(BOOL)socket limit:(NSUInteger)limit
                   failure:(void (^)(int))failure
{
    self = [super init];
    if (!self) return nil;
    _fd = -1;
    if (fd < 0 || !limit || limit > JUICE_IO_GLOBAL_BYTES) { errno = EINVAL; return nil; }
#ifdef F_DUPFD_CLOEXEC
    _fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
#else
    _fd = dup(fd);
    if (_fd >= 0 && fcntl(_fd, F_SETFD, FD_CLOEXEC) < 0)
    { int saved = errno; close(_fd); _fd = -1; errno = saved; }
#endif
    if (_fd < 0) return nil;
    if (!socket)
    {
        int flags = fcntl(_fd, F_GETFL);
        if (flags < 0 || fcntl(_fd, F_SETFL, flags | O_NONBLOCK) < 0) return nil;
    }
#ifdef SO_NOSIGPIPE
    else
    {
        int one = 1;
        if (setsockopt(_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return nil;
    }
#endif
    _socket = socket;
    _limit = limit;
    _failure = [failure copy];
    atomic_init(&_cancelled, false);
    _queue = dispatch_queue_create("org.juice.ordered-writer",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    return self;
}

- (BOOL)enqueueData:(NSData *)data
{
    if (!data.length) return YES;
    int64_t now=JuiceSocketNowMS();
    if(now<0)return NO;
    const int64_t deadline=now+JUICE_IO_WRITE_TIMEOUT_MS;
    @synchronized(self)
    {
        if (atomic_load_explicit(&_cancelled, memory_order_relaxed)) { errno = EPIPE; return NO; }
        if (data.length > _limit || _queuedBytes > _limit - data.length ||
            _queuedPackets >= JUICE_IO_MAX_PACKETS || !JuiceReserveBytes(data.length))
        { errno = ENOBUFS; return NO; }
        /* Freeze mutable caller buffers before returning to UIKit. */
        NSData *packet = [data copy];
        if (!packet)
        {
            atomic_fetch_sub_explicit(&JuiceBufferedBytes, data.length, memory_order_relaxed);
            errno = ENOMEM;
            return NO;
        }
        _queuedBytes += packet.length;
        _queuedPackets++;
        dispatch_async(_queue, ^{
            @autoreleasepool
            {
                /* Queue residence consumes the same deadline as the syscall. */
                int64_t current=JuiceSocketNowMS();
                int64_t remaining=deadline-current;
                int result;
                if(current<0)result=-1;
                else if(remaining<=0){errno=ETIMEDOUT;result=-1;}
                else result=JuiceWriteWithDeadline(self->_fd,packet.bytes,packet.length,
                    self->_socket,(unsigned)remaining,&self->_cancelled);
                int saved = result ? errno : 0;
                if (result && !atomic_exchange_explicit(&self->_cancelled, true, memory_order_relaxed))
                {
                    /* A failed packet may already have a header/prefix on the
                     * wire. Never append another packet to that partial one. */
                    if (self->_socket) shutdown(self->_fd, SHUT_RDWR);
                    if (self->_failure) self->_failure(saved);
                }
                @synchronized(self)
                {
                    self->_queuedBytes -= packet.length;
                    self->_queuedPackets--;
                    atomic_fetch_sub_explicit(&JuiceBufferedBytes, packet.length, memory_order_relaxed);
                }
            }
        });
    }
    return YES;
}

- (void)cancel
{
    @synchronized(self)
    {
        atomic_store_explicit(&_cancelled, true, memory_order_relaxed);
        /* Close only on the worker, after in-flight syscalls have stopped. The
         * caller may immediately close/reuse its own numeric descriptor. */
        dispatch_async(_queue, ^{
            if (self->_fd >= 0) { close(self->_fd); self->_fd = -1; }
        });
    }
}

- (void)dealloc
{
    if (_fd >= 0) close(_fd);
}
@end
