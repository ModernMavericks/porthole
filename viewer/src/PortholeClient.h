#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "PortholeTransport.h"
#import "remote_display.h"

// Internal: the Xpra backend engine behind the remote_display C interface.
// Callers use the C API (rds_xpra_create + rds_* + rds_callbacks), not this
// class. The rds_session handle is an PortholeClient instance.
@interface PortholeClient : NSObject <PortholeTransportDelegate>
- (instancetype)initWithSocketPath:(NSString *)path
                         callbacks:(const rds_callbacks *)cb;
@end
