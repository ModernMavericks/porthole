#import <Foundation/Foundation.h>

@protocol PortholeMenuProducer;

// Producer -> controller, always delivered on the MAIN thread.
@protocol PortholeMenuProducerDelegate <NSObject>
- (void)producer:(id<PortholeMenuProducer>)p didSnapshot:(NSArray *)topLevelNodes; // NSArray<PortholeMenuNode*>
- (void)producer:(id<PortholeMenuProducer>)p didDelta:(NSArray *)changes;          // NSArray<NSDictionary*>
- (void)producer:(id<PortholeMenuProducer>)p didPopulate:(NSInteger)nodeId children:(NSArray *)children;
- (void)producerDidEnd:(id<PortholeMenuProducer>)p;
@end

@protocol PortholeMenuProducer <NSObject>
@property(assign, nonatomic) id<PortholeMenuProducerDelegate> delegate; // weak
- (void)start;
- (void)openNode:(NSInteger)nodeId;
- (void)invokeNode:(NSInteger)nodeId;
- (void)stop;
@end
