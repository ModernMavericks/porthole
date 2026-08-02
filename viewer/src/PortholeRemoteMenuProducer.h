#import <Foundation/Foundation.h>
#import "PortholeMenuProducer.h"

// Speaks the newline-JSON menu wire over an AF_UNIX socket. Reads on a background
// thread; delivers to the delegate on the MAIN thread. Writes {hello,open,invoke}.
@interface PortholeRemoteMenuProducer : NSObject <PortholeMenuProducer>
@property(assign, nonatomic) id<PortholeMenuProducerDelegate> delegate;
// Production: connect to a Unix socket path.
- (id)initWithSocketPath:(NSString *)path;
// Test seam: use an already-connected fd (e.g. one end of socketpair()).
- (id)initWithFileDescriptor:(int)fd;
@end
