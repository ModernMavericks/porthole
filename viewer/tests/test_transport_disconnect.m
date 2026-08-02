// test_transport_disconnect -- the transport must report a dropped connection so the
// shell can tear down instead of lingering as a frozen zombie (see main.m
// sessionDisconnected). Drives a real PortholeTransport against a local AF_UNIX
// listener, then closes the server end and asserts the delegate is told.
#import <Cocoa/Cocoa.h>
#import "PortholeTransport.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <assert.h>

@interface DiscDelegate : NSObject <PortholeTransportDelegate>
@property(assign) BOOL connected;
@property(assign) NSInteger failCount;
@property(retain) NSString *lastFail;
@end
@implementation DiscDelegate
- (void)transport:(PortholeTransport *)t didReceivePayload:(NSData *)p rawChunks:(NSDictionary *)r {}
- (void)transportDidConnect:(PortholeTransport *)t { _connected = YES; }
- (void)transport:(PortholeTransport *)t didFailWithError:(NSString *)msg {
    _failCount++; self.lastFail = msg;
}
- (void)dealloc { [_lastFail release]; [super dealloc]; }
@end

// Pump the main run loop until `cond` or a timeout (stream events arrive via the runloop).
static void pump(BOOL (^cond)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (!cond() && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];   // a run loop, like the real shell

        // A private AF_UNIX listener the transport can connect() to.
        NSString *path = [NSString stringWithFormat:@"%@porthole-disc-%d.sock",
                          NSTemporaryDirectory(), getpid()];
        unlink([path fileSystemRepresentation]);
        int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
        assert(lfd >= 0);
        struct sockaddr_un addr; memset(&addr, 0, sizeof addr);
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, [path fileSystemRepresentation], sizeof(addr.sun_path) - 1);
        assert(bind(lfd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) == 0);
        assert(listen(lfd, 1) == 0);

        DiscDelegate *d = [[[DiscDelegate alloc] init] autorelease];
        PortholeTransport *t = [[PortholeTransport alloc] initWithSocketPath:path];
        t.delegate = d;
        [t connect];                 // AF_UNIX connect() completes into the accept queue
        int cfd = accept(lfd, NULL, NULL);
        assert(cfd >= 0);
        pump(^BOOL{ return d.connected; });
        assert(d.connected);         // sanity: streams opened before we test the drop

        // The server goes away (container/VM stop, bridge drop). The client must notice.
        assert(d.failCount == 0);    // ...and not before.
        close(cfd);
        pump(^BOOL{ return d.failCount > 0; });
        assert(d.failCount > 0);     // EOF / end-of-stream surfaced as a failure
        assert([d.lastFail isEqualToString:@"connection closed"]);

        close(lfd);
        unlink([path fileSystemRepresentation]);
        [t release];
        printf("test_transport_disconnect: OK\n");
    }
    return 0;
}
