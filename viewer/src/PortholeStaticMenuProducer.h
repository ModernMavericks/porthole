#import <Foundation/Foundation.h>
#import "PortholeMenuProducer.h"

// Resolves a static menu.json item's original action string ("ctrl+shift+l",
// "@quit", ...). Implemented by the app delegate (existing send/native dispatch).
@protocol PortholeMenuStaticInvoker <NSObject>
- (void)invokeSendString:(NSString *)send;
@end

// Mac-local producer: reads the bundled menu.json (existing format) into the
// normalized model, assigning ids. No deltas. invokeNode: maps id -> send string
// -> the invoker. open/stop are no-ops.
@interface PortholeStaticMenuProducer : NSObject <PortholeMenuProducer>
@property(assign, nonatomic) id<PortholeMenuProducerDelegate> delegate;
// jsonPath may be nil (no per-app menus -> empty snapshot). invoker is weak.
- (id)initWithJSONPath:(NSString *)jsonPath invoker:(id<PortholeMenuStaticInvoker>)invoker;
@end
