#import "PortholeRemoteMenuProducer.h"
#import "PortholeMenuModel.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

@implementation PortholeRemoteMenuProducer {
    NSString *_path;       // for path-based connect (nil when fd given)
    int _fd;
    NSThread *_reader;
    NSLock *_writeLock;
    BOOL _stopped;
}
@synthesize delegate = _delegate;

- (id)initWithSocketPath:(NSString *)path {
    if ((self = [super init])) { _path = [path copy]; _fd = -1; _writeLock = [[NSLock alloc] init]; }
    return self;
}
- (id)initWithFileDescriptor:(int)fd {
    if ((self = [super init])) { _fd = fd; _writeLock = [[NSLock alloc] init]; }
    return self;
}

- (void)start {
    if (_fd < 0 && _path) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a; memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        strncpy(a.sun_path, [_path fileSystemRepresentation], sizeof(a.sun_path)-1);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
            close(fd);
            // No producer available: behave as an immediate, quiet end.
            [self performSelectorOnMainThread:@selector(deliverEnd) withObject:nil waitUntilDone:NO];
            return;
        }
        _fd = fd;
    }
    if (_fd < 0) { [self performSelectorOnMainThread:@selector(deliverEnd) withObject:nil waitUntilDone:NO]; return; }
    [self writeJSON:@{@"t": @"hello", @"v": @1}];
    _reader = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:nil];
    [_reader start];
}

- (void)writeJSON:(NSDictionary *)obj {
    NSMutableData *d = [[[NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL] mutableCopy] autorelease];
    [d appendBytes:"\n" length:1];
    [_writeLock lock];
    if (_fd >= 0) { ssize_t off = 0; const char *b = d.bytes; NSUInteger len = d.length;
        while (off < (ssize_t)len) { ssize_t w = write(_fd, b + off, len - off); if (w <= 0) break; off += w; } }
    [_writeLock unlock];
}

- (void)readLoop {
    NSMutableData *acc = [[NSMutableData alloc] init];
    char buf[4096];
    while (!_stopped) {
        ssize_t n = read(_fd, buf, sizeof(buf));
        if (n <= 0) break;
        [acc appendBytes:buf length:n];
        // Split complete lines.
        const char *bytes = acc.bytes; NSUInteger start = 0;
        for (NSUInteger i = 0; i < acc.length; i++) {
            if (bytes[i] != '\n') continue;
            NSData *line = [NSData dataWithBytes:bytes + start length:i - start];
            start = i + 1;
            NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if ([msg isKindOfClass:[NSDictionary class]])
                [self performSelectorOnMainThread:@selector(deliver:) withObject:msg waitUntilDone:NO];
            bytes = acc.bytes;  // (unchanged, but explicit)
        }
        if (start) [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
    [acc release];
    [_writeLock lock];
    if (_fd >= 0) { close(_fd); _fd = -1; }
    [_writeLock unlock];
    [self performSelectorOnMainThread:@selector(deliverEnd) withObject:nil waitUntilDone:NO];
}

// --- main thread ---
- (void)deliver:(NSDictionary *)msg {
    NSString *t = msg[@"t"];
    if ([t isEqualToString:@"menu"])
        [_delegate producer:self didSnapshot:[PortholeMenuNode nodesFromArray:msg[@"root"]]];
    else if ([t isEqualToString:@"delta"])
        [_delegate producer:self didDelta:msg[@"changes"]];
    else if ([t isEqualToString:@"subtree"])
        [_delegate producer:self didPopulate:[msg[@"id"] integerValue]
                   children:[PortholeMenuNode nodesFromArray:msg[@"children"]]];
    else if ([t isEqualToString:@"bye"])
        [self deliverEnd];
}
- (void)deliverEnd { [_delegate producerDidEnd:self]; }

- (void)openNode:(NSInteger)nodeId   { [self writeJSON:@{@"t": @"open",   @"id": @(nodeId)}]; }
- (void)invokeNode:(NSInteger)nodeId { [self writeJSON:@{@"t": @"invoke", @"id": @(nodeId)}]; }

- (void)stop {
    _stopped = YES;
    [_writeLock lock];
    if (_fd >= 0) { close(_fd); _fd = -1; }
    [_writeLock unlock];
}

- (void)dealloc { [_path release]; [_reader release]; [_writeLock release]; [super dealloc]; }
@end
