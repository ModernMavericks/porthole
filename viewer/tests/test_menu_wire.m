#import <Cocoa/Cocoa.h>
#import "PortholeRemoteMenuProducer.h"
#import "PortholeMenuModel.h"
#include <sys/socket.h>
#include <unistd.h>
#include <assert.h>

@interface WireDelegate : NSObject <PortholeMenuProducerDelegate>
@property(retain) NSArray *snapshot;
@property(retain) NSArray *delta;
@property(assign) BOOL ended;
@end
@implementation WireDelegate
- (void)producer:(id)p didSnapshot:(NSArray *)n { self.snapshot = n; }
- (void)producer:(id)p didDelta:(NSArray *)c { self.delta = c; }
- (void)producer:(id)p didPopulate:(NSInteger)i children:(NSArray *)c {}
- (void)producerDidEnd:(id)p { _ended = YES; }
- (void)dealloc { [_snapshot release]; [_delta release]; [super dealloc]; }
@end

// Pump the main run loop until `cond` or timeout (deltas arrive via main queue).
static void pump(BOOL (^cond)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while (!cond() && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static void writeLine(int fd, NSString *s) {
    NSData *d = [[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, d.bytes, d.length);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        int sv[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
        // sv[0] = producer (test) side; sv[1] = client side.
        PortholeRemoteMenuProducer *rp = [[[PortholeRemoteMenuProducer alloc]
            initWithFileDescriptor:sv[1]] autorelease];
        WireDelegate *del = [[[WireDelegate alloc] init] autorelease];
        rp.delegate = del;
        [rp start];

        // Client should send hello first.
        char buf[256]; ssize_t n = read(sv[0], buf, sizeof(buf)-1);
        assert(n > 0); buf[n] = 0;
        assert(strstr(buf, "\"hello\"") != NULL);

        // Producer sends a menu snapshot.
        writeLine(sv[0], @"{\"t\":\"menu\",\"root\":[{\"id\":1,\"role\":\"submenu\","
                          "\"label\":\"File\",\"children\":[{\"id\":2,\"role\":\"item\","
                          "\"label\":\"Save\",\"enabled\":true}]}]}");
        pump(^BOOL{ return del.snapshot != nil; });
        assert(del.snapshot.count == 1);
        assert([[del.snapshot[0] label] isEqualToString:@"File"]);

        // Producer sends a delta.
        writeLine(sv[0], @"{\"t\":\"delta\",\"changes\":[{\"id\":2,\"enabled\":false}]}");
        pump(^BOOL{ return del.delta != nil; });
        assert(del.delta.count == 1);

        // Client invoke -> a line the producer can read.
        [rp invokeNode:2];
        n = read(sv[0], buf, sizeof(buf)-1); assert(n > 0); buf[n] = 0;
        assert(strstr(buf, "\"invoke\"") && strstr(buf, "\"id\":2"));

        // EOF -> producerDidEnd.
        close(sv[0]);
        pump(^BOOL{ return del.ended; });
        assert(del.ended);

        printf("test_menu_wire: OK\n");
    }
    return 0;
}
