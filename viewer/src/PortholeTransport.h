#import <Foundation/Foundation.h>
@class PortholeTransport;

@protocol PortholeTransportDelegate <NSObject>
// One logical packet: `payload` is the main (index-0) rencodeplus payload;
// `rawChunks` (nil if none) maps a position index -> the raw bytes that the
// server extracted from that position of the packet (compressed/large items),
// which the delegate substitutes back before decoding the value there.
- (void)transport:(PortholeTransport *)t didReceivePayload:(NSData *)payload
        rawChunks:(NSDictionary *)rawChunks;
- (void)transportDidConnect:(PortholeTransport *)t;
- (void)transport:(PortholeTransport *)t didFailWithError:(NSString *)msg;
@end

@interface PortholeTransport : NSObject
@property (nonatomic, weak) id<PortholeTransportDelegate> delegate;
- (instancetype)initWithSocketPath:(NSString *)path;   // AF_UNIX socket path
- (void)connect;
- (void)sendPayload:(NSData *)payload;   // wraps with a header and writes
@end
