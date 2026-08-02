#import <Foundation/Foundation.h>

@interface PortholeProtocol : NSObject

// Build an 8-byte Xpra header for a payload of the given length.
+ (NSData *)headerForPayloadLength:(uint32_t)len;

// Parse a header. Returns YES and sets *outLen if `data` starts with a valid
// 8-byte header (first byte 'P'); NO otherwise.
+ (BOOL)parseHeader:(NSData *)data payloadLength:(uint32_t *)outLen;

// Parse a header, also reporting the packet_index (0 = the main packet; >0 = a
// raw sub-packet extracted from position `packetIndex` of the main packet) and
// the compression level (0 = uncompressed). Any out-pointer may be NULL.
+ (BOOL)parseHeader:(NSData *)data payloadLength:(uint32_t *)outLen
        packetIndex:(uint8_t *)outIndex level:(uint8_t *)outLevel;

// Decode one rencodeplus value from `data` starting at *offset; advances *offset.
// Returns nil on malformed input. Types: NSData (bytes), NSNumber (int/float/bool),
// NSNull (None), NSArray, NSDictionary.
+ (id)decodeValue:(NSData *)data offset:(NSUInteger *)offset;

// Encode a value (NSData/NSString/NSNumber/NSArray/NSDictionary) to rencodeplus.
+ (NSData *)encodeValue:(id)value;

// Inflate an xpra lz4-compressed payload: a 4-byte little-endian uncompressed
// size followed by an lz4 *block*. Returns nil on malformed input. Self-contained
// and bounds-checked (safe on untrusted server data).
+ (NSData *)inflateLZ4:(NSData *)data;

@end
