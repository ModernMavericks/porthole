#import "PortholeProtocol.h"

@interface PortholeProtocol ()
+ (id)decodeValue:(NSData *)data offset:(NSUInteger *)offset depth:(int)depth;
+ (void)encode:(id)v into:(NSMutableData *)out;
@end

@implementation PortholeProtocol

+ (NSData *)headerForPayloadLength:(uint32_t)len {
    // 'P', proto_flags, compression_level, packet_index, size(BE).
    // proto_flags = 0x10 (FLAGS_RENCODEPLUS) so the server decodes our payload as
    // rencodeplus (0x0 would mean bencode). No compression -> level/index = 0.
    uint8_t h[8] = { 'P', 0x10, 0, 0,
                     (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                     (uint8_t)(len >> 8),  (uint8_t)(len) };
    return [NSData dataWithBytes:h length:8];
}

+ (BOOL)parseHeader:(NSData *)data payloadLength:(uint32_t *)outLen {
    return [self parseHeader:data payloadLength:outLen packetIndex:NULL level:NULL];
}

+ (BOOL)parseHeader:(NSData *)data payloadLength:(uint32_t *)outLen
        packetIndex:(uint8_t *)outIndex level:(uint8_t *)outLevel {
    if (data.length < 8) return NO;
    const uint8_t *b = data.bytes;              // 'P', proto_flags, level, packet_index, size(BE)
    if (b[0] != 'P') return NO;
    if (outLevel) *outLevel = b[2];
    if (outIndex) *outIndex = b[3];
    if (outLen) *outLen = ((uint32_t)b[4] << 24) | ((uint32_t)b[5] << 16) |
                          ((uint32_t)b[6] << 8)  | (uint32_t)b[7];
    return YES;
}

+ (NSData *)inflateLZ4:(NSData *)data {
    // xpra frames lz4 as: [uint32 LE uncompressed size][lz4 block].
    if (data.length < 4) return nil;
    const uint8_t *b = data.bytes;
    uint32_t outSize = (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
                       ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
    if (outSize == 0) return [NSData data];
    if (outSize > 256u * 1024u * 1024u) return nil;   // reject absurd sizes from bad input
    NSMutableData *out = [NSMutableData dataWithLength:outSize];
    if (!out) return nil;
    size_t produced = 0;
    if (!lz4BlockDecode(b + 4, data.length - 4, out.mutableBytes, outSize, &produced)) return nil;
    if (produced != outSize) return nil;              // must fill exactly
    return out;
}

// ---- lz4 block decompression ----
// Decode a raw lz4 block into dst[0..dstCap). Returns YES and sets *outLen on
// success. Every read from src and write to dst is bounds-checked, so this is
// safe to run on untrusted server data (malformed input -> NO, never OOB).
static BOOL lz4BlockDecode(const uint8_t *src, size_t srcLen,
                           uint8_t *dst, size_t dstCap, size_t *outLen) {
    const uint8_t *sp = src, *sEnd = src + srcLen;
    uint8_t *dp = dst, *const dStart = dst, *dEnd = dst + dstCap;
    while (sp < sEnd) {
        uint8_t token = *sp++;
        // literal run
        size_t litLen = token >> 4;
        if (litLen == 15) {
            uint8_t b;
            do { if (sp >= sEnd) return NO; b = *sp++; litLen += b; } while (b == 255);
        }
        if ((size_t)(sEnd - sp) < litLen) return NO;
        if ((size_t)(dEnd - dp) < litLen) return NO;
        memcpy(dp, sp, litLen);
        sp += litLen; dp += litLen;
        if (sp == sEnd) break;                 // last sequence is literals only
        // match
        if ((size_t)(sEnd - sp) < 2) return NO;
        uint32_t offset = (uint32_t)sp[0] | ((uint32_t)sp[1] << 8);
        sp += 2;
        if (offset == 0 || (size_t)(dp - dStart) < offset) return NO;   // bad back-reference
        size_t matchLen = token & 0x0f;
        if (matchLen == 15) {
            uint8_t b;
            do { if (sp >= sEnd) return NO; b = *sp++; matchLen += b; } while (b == 255);
        }
        matchLen += 4;                          // minmatch
        if ((size_t)(dEnd - dp) < matchLen) return NO;
        const uint8_t *mp = dp - offset;        // may overlap dp (RLE) -> copy byte-by-byte
        for (size_t i = 0; i < matchLen; i++) *dp++ = *mp++;
    }
    if (outLen) *outLen = (size_t)(dp - dStart);
    return YES;
}

static int64_t readSignedBE(const uint8_t *p, int n) {
    int64_t v = (p[0] & 0x80) ? -1 : 0;              // sign-extend
    for (int i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

+ (id)decodeValue:(NSData *)data offset:(NSUInteger *)offset {
    return [self decodeValue:data offset:offset depth:0];
}

+ (id)decodeValue:(NSData *)data offset:(NSUInteger *)offset depth:(int)depth {
    if (depth > 64) return nil;
    const uint8_t *b = data.bytes;
    NSUInteger len = data.length, o = *offset;
    if (o >= len) return nil;
    uint8_t t = b[o];

    if (t <= 0x2b) { *offset = o + 1; return @((int)t); }               // pos-fixed 0..43
    if (t >= 0x46 && t <= 0x65) { *offset = o + 1; return @(69 - (int)t); } // neg-fixed -1..-32
    if (t >= 0x30 && t <= 0x39) {                          // digit-prefixed: bytes "N/data" or str "N:data"
        NSUInteger p = o, n = 0;
        while (p < len && b[p] >= 0x30 && b[p] <= 0x39) {
            n = n * 10 + (b[p] - 0x30);
            if (n > len) return nil;        // length can't exceed the buffer; also stops overflow
            p++;
        }
        if (p >= len) return nil;
        uint8_t sep = b[p];
        if (sep != 0x2f && sep != 0x3a) return nil;                      // expect '/' (bytes) or ':' (str)
        p++;
        if (n > len - p) return nil;        // overflow-safe (p <= len here)
        *offset = p + n;
        if (sep == 0x3a)
            return [[[NSString alloc] initWithBytes:b + p length:n encoding:NSUTF8StringEncoding] autorelease];
        return [NSData dataWithBytes:b + p length:n];
    }
    switch (t) {
        case 0x3e: if (o+2 > len) return nil; *offset=o+2; return @(readSignedBE(b+o+1,1));
        case 0x3f: if (o+3 > len) return nil; *offset=o+3; return @(readSignedBE(b+o+1,2));
        case 0x40: if (o+5 > len) return nil; *offset=o+5; return @(readSignedBE(b+o+1,4));
        case 0x41: if (o+9 > len) return nil; *offset=o+9; return @(readSignedBE(b+o+1,8));
        case 0x2c: { if (o+9 > len) return nil; uint64_t u=0; for(int i=0;i<8;i++) u=(u<<8)|b[o+1+i];
                     double dv; memcpy(&dv,&u,8); *offset=o+9; return @(dv); }
        case 0x43: *offset=o+1; return @YES;
        case 0x44: *offset=o+1; return @NO;
        case 0x45: *offset=o+1; return [NSNull null];
    }
    if (t >= 0xc0) {                                                     // fixed list
        int n = t - 0xc0; *offset = o + 1;
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
        for (int i=0;i<n;i++){ id v=[self decodeValue:data offset:offset depth:depth+1]; if(!v) return nil; [a addObject:v]; }
        return a;
    }
    if (t >= 0x66 && t <= 0x7e) {                                        // fixed dict
        int n = t - 0x66; *offset = o + 1;
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:n];
        for (int i=0;i<n;i++){ id k=[self decodeValue:data offset:offset depth:depth+1]; id v=[self decodeValue:data offset:offset depth:depth+1];
                               if(!k||!v) return nil; m[k]=v; }
        return m;
    }
    if (t == 0x3b) {                                                    // variable-length list
        *offset = o + 1;
        NSMutableArray *a = [NSMutableArray array];
        while (1) {
            if (*offset >= len) return nil;
            if (b[*offset] == 0x7f) { (*offset)++; break; }
            id e = [self decodeValue:data offset:offset depth:depth+1]; if (!e) return nil; [a addObject:e];
        }
        return a;
    }
    if (t == 0x3c) {                                                    // variable-length dict
        *offset = o + 1;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        while (1) {
            if (*offset >= len) return nil;
            if (b[*offset] == 0x7f) { (*offset)++; break; }
            id k = [self decodeValue:data offset:offset depth:depth+1]; if (!k) return nil;
            id val = [self decodeValue:data offset:offset depth:depth+1]; if (!val) return nil;
            m[k] = val;
        }
        return m;
    }
    if (t >= 0x80 && t <= 0xbf) {                                        // fixed-length str (len = t - 0x80)
        NSUInteger n = t - 0x80;
        if (o + 1 + n > len) return nil;
        *offset = o + 1 + n;
        return [[[NSString alloc] initWithBytes:b + o + 1 length:n encoding:NSUTF8StringEncoding] autorelease];
    }
    return nil;   // unsupported tag in D0
}

static void appendBytes(NSMutableData *out, const void *bytes, NSUInteger n) {
    NSString *pfx = [NSString stringWithFormat:@"%lu/", (unsigned long)n];
    NSData *p = [pfx dataUsingEncoding:NSUTF8StringEncoding];
    [out appendData:p]; [out appendBytes:bytes length:n];
}

+ (NSData *)encodeValue:(id)value {
    NSMutableData *out = [NSMutableData data];
    [self encode:value into:out];
    return out;
}

+ (void)encode:(id)v into:(NSMutableData *)out {
    if ([v isKindOfClass:[NSData class]]) { appendBytes(out, [v bytes], [v length]); return; }
    if ([v isKindOfClass:[NSString class]]) {
        NSData *d = [v dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger n = d.length;
        if (n <= 63) { uint8_t t = (uint8_t)(0x80 + n); [out appendBytes:&t length:1]; [out appendData:d]; }
        else {
            NSString *pfx = [NSString stringWithFormat:@"%lu:", (unsigned long)n];
            [out appendData:[pfx dataUsingEncoding:NSUTF8StringEncoding]]; [out appendData:d];
        }
        return;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSArray *a = v;
        if (a.count <= 63) { uint8_t t = 0xc0 + (uint8_t)a.count; [out appendBytes:&t length:1]; for (id e in a) [self encode:e into:out]; }
        else { uint8_t t = 0x3b; [out appendBytes:&t length:1]; for (id e in a) [self encode:e into:out]; uint8_t term = 0x7f; [out appendBytes:&term length:1]; }
        return;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *m = v;
        if (m.count <= 24) { uint8_t t = 0x66 + (uint8_t)m.count; [out appendBytes:&t length:1]; for (id k in m) { [self encode:k into:out]; [self encode:m[k] into:out]; } }
        else { uint8_t t = 0x3c; [out appendBytes:&t length:1]; for (id k in m) { [self encode:k into:out]; [self encode:m[k] into:out]; } uint8_t term = 0x7f; [out appendBytes:&term length:1]; }
        return;
    }
    if ([v isKindOfClass:[NSNumber class]]) {
        NSNumber *num = v;
        if (num == (id)kCFBooleanTrue || num == (id)kCFBooleanFalse) {
            uint8_t t = [num boolValue] ? 0x43 : 0x44; [out appendBytes:&t length:1]; return;
        }
        int64_t x = [num longLongValue];
        if (x >= 0 && x <= 43) { uint8_t t=(uint8_t)x; [out appendBytes:&t length:1]; return; }
        if (x < 0 && x >= -32)  { uint8_t t=(uint8_t)(69 - x); [out appendBytes:&t length:1]; return; }
        if (x >= -128 && x <= 127)      { uint8_t h[2]={0x3e,(uint8_t)x}; [out appendBytes:h length:2]; return; }
        if (x >= -32768 && x <= 32767)  { uint8_t h[3]={0x3f,(uint8_t)(x>>8),(uint8_t)x}; [out appendBytes:h length:3]; return; }
        if (x >= -2147483648LL && x <= 2147483647LL) { uint8_t h[5]={0x40,(uint8_t)(x>>24),(uint8_t)(x>>16),(uint8_t)(x>>8),(uint8_t)x}; [out appendBytes:h length:5]; return; }
        uint8_t h[9]; h[0]=0x41; for(int i=0;i<8;i++) h[1+i]=(uint8_t)(x>>(56-8*i)); [out appendBytes:h length:9]; return;
    }
    NSCAssert(NO, @"unsupported type to encode: %@", v);
}

@end
