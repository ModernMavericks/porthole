#import <Foundation/Foundation.h>
#import "PortholeProtocol.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL: %s\n", msg); failures++; } } while (0)

static NSData *hex(const char *s) {
    NSMutableData *d = [NSMutableData data];
    for (; s[0] && s[1]; s += 2) { unsigned v; sscanf(s, "%2x", &v); uint8_t b = (uint8_t)v; [d appendBytes:&b length:1]; }
    return d;
}
static id dec(const char *h) { NSUInteger o = 0; return [PortholeProtocol decodeValue:hex(h) offset:&o]; }

static void rt(id v, const char *msg) {
    NSData *e = [PortholeProtocol encodeValue:v];
    NSUInteger o = 0; id back = [PortholeProtocol decodeValue:e offset:&o];
    CHECK(o == e.length && [back isEqual:v], msg);
}

static void test_header(void) {
    NSData *h = [PortholeProtocol headerForPayloadLength:0x0102];
    const uint8_t *b = h.bytes;
    CHECK(h.length == 8, "header is 8 bytes");
    CHECK(b[0] == 'P', "magic P");
    CHECK(b[1] == 0x10, "proto_flags = rencodeplus (0x10)");
    CHECK(b[2] == 0 && b[3] == 0, "compression level + packet index zero");
    CHECK(b[4] == 0 && b[5] == 0 && b[6] == 0x01 && b[7] == 0x02, "len big-endian");

    uint32_t len = 0;
    BOOL ok = [PortholeProtocol parseHeader:h payloadLength:&len];
    CHECK(ok && len == 0x0102, "round-trip parse");

    uint8_t bad[8] = {'X',0,0,0,0,0,0,0};
    CHECK(![PortholeProtocol parseHeader:[NSData dataWithBytes:bad length:8] payloadLength:&len], "reject bad magic");

    uint32_t big = 0xFF010203;
    NSData *hb = [PortholeProtocol headerForPayloadLength:big];
    uint32_t blen = 0;
    CHECK([PortholeProtocol parseHeader:hb payloadLength:&blen] && blen == big, "high-bit length round-trips");
}

static void test_decode(void) {
    CHECK([dec("00") isEqual:@0], "int 0");
    CHECK([dec("2b") isEqual:@43], "int 43 fixed");
    CHECK([dec("46") isEqual:@(-1)], "int -1 fixed");
    CHECK([dec("65") isEqual:@(-32)], "int -32 fixed");
    CHECK([dec("3e2c") isEqual:@44], "int8 44");
    CHECK([dec("3e80") isEqual:@(-128)], "int8 -128");
    CHECK([dec("3f0080") isEqual:@128], "int16 128");
    CHECK([dec("3fff7f") isEqual:@(-129)], "int16 -129");
    CHECK([dec("4000010000") isEqual:@65536], "int32 65536");
    CHECK([dec("410000000080000000") isEqual:@2147483648LL], "int64 2**31");
    CHECK([dec("2c3ff8000000000000") isEqual:@1.5], "float64 1.5");
    CHECK([dec("43") isEqual:@YES], "True");
    CHECK([dec("44") isEqual:@NO], "False");
    CHECK([dec("45") isEqual:[NSNull null]], "None");
    CHECK([dec("302f") isEqual:[NSData data]], "empty bytes");
    CHECK([dec("312f61") isEqual:[@"a" dataUsingEncoding:NSUTF8StringEncoding]], "bytes 'a'");
    NSArray *l = dec("c3010203");
    CHECK(l.count==3 && [l[0] isEqual:@1] && [l[2] isEqual:@3], "list [1,2,3]");
    NSDictionary *dd = dec("69352f77696474683f04dd362f6865696768743f0339382f656e636f64696e67332f726762");
    NSData *enc = [@"encoding" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([dd[enc] isEqual:[@"rgb" dataUsingEncoding:NSUTF8StringEncoding]], "dict encoding=rgb");
}

static void test_decode_malformed(void) {
    CHECK(dec("3f00") == nil, "truncated int16 -> nil");            // tag says int16 but only 1 byte follows
    CHECK(dec("3161") == nil, "byte-string missing '/' -> nil");    // "1a" no slash
    CHECK(dec("ff") == nil, "fixed list of 63 with no items -> nil"); // 0xff = list of 63, buffer ends
    // over-long byte-string length must be rejected, not OOB-read:
    const char *huge = "18446744073709551610/";
    NSMutableData *hd = [NSMutableData data];
    for (const char *s = huge; *s; s++) { uint8_t c = (uint8_t)*s; [hd appendBytes:&c length:1]; }
    NSUInteger o1 = 0;
    CHECK([PortholeProtocol decodeValue:hd offset:&o1] == nil, "overflow length -> nil (no OOB)");
    // deep nesting must be rejected, not stack-overflow:
    NSMutableData *deep = [NSMutableData data];
    uint8_t c1 = 0xc1; for (int i = 0; i < 100000; i++) [deep appendBytes:&c1 length:1];
    NSUInteger o2 = 0;
    CHECK([PortholeProtocol decodeValue:deep offset:&o2] == nil, "deep nesting -> nil (no stack overflow)");
}

static void test_encode(void) {
    rt(@0, "rt 0"); rt(@43, "rt 43"); rt(@(-1), "rt -1"); rt(@44, "rt 44");
    rt(@128, "rt 128"); rt(@65536, "rt 65536"); rt(@2147483648LL, "rt 2**31");
    rt(@YES, "rt YES"); rt(@NO, "rt NO");
    rt([@"rgb" dataUsingEncoding:NSUTF8StringEncoding], "rt bytes");
    rt((@[@1, @2, @3]), "rt list");
    CHECK([[PortholeProtocol encodeValue:@0] isEqual:hex("00")], "enc 0 == 00");
    CHECK([[PortholeProtocol encodeValue:[@"a" dataUsingEncoding:NSUTF8StringEncoding]] isEqual:hex("312f61")], "enc 'a'");
    CHECK([[PortholeProtocol encodeValue:@"a"] isEqual:hex("8161")], "enc str 'a'");
}

static void test_str(void) {
    // ENCODE: NSString -> str form (0x80+len), distinct from NSData -> bytes form
    CHECK([[PortholeProtocol encodeValue:@"hello"] isEqual:hex("8568656c6c6f")], "enc str hello");
    CHECK([[PortholeProtocol encodeValue:@""] isEqual:hex("80")], "enc str empty");
    CHECK([[PortholeProtocol encodeValue:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]] isEqual:hex("352f68656c6c6f")], "enc bytes hello (still N/data)");
    // UTF-8 length is byte count:
    CHECK([[PortholeProtocol encodeValue:@"café"] isEqual:hex("85636166c3a9")], "enc str cafe utf8");
    // long str (>=64 bytes) -> "<len>:<data>"
    NSMutableString *big = [NSMutableString string]; for(int i=0;i<64;i++)[big appendString:@"a"];
    NSData *e = [PortholeProtocol encodeValue:big];
    const uint8_t *eb = e.bytes; CHECK(eb[0]=='6' && eb[1]=='4' && eb[2]==0x3a, "enc long str uses N: form");
    // DECODE: str-fixed and long form -> NSString
    NSUInteger o=0; CHECK([[PortholeProtocol decodeValue:hex("8568656c6c6f") offset:&o] isEqual:@"hello"], "dec str-fixed hello");
    o=0; CHECK([[PortholeProtocol decodeValue:hex("80") offset:&o] isEqual:@""], "dec str empty");
    o=0; CHECK([[PortholeProtocol decodeValue:hex("85636166c3a9") offset:&o] isEqual:@"café"], "dec str utf8");
    // decode long str "3:abc" (=51 3a 616263) -> @"abc"
    o=0; CHECK([[PortholeProtocol decodeValue:hex("333a616263") offset:&o] isEqual:@"abc"], "dec long-form str");
    // bytes path still yields NSData, not NSString:
    o=0; id b = [PortholeProtocol decodeValue:hex("352f68656c6c6f") offset:&o];
    CHECK([b isKindOfClass:[NSData class]], "bytes still decode to NSData");
    // round-trip a hello-shaped packet: type must come back as NSString
    o=0; id pk = [PortholeProtocol decodeValue:[PortholeProtocol encodeValue:@[@"hello", @{@"encoding":@"rgb"}]] offset:&o];
    CHECK([pk isKindOfClass:[NSArray class]] && [((NSArray*)pk)[0] isKindOfClass:[NSString class]] && [((NSArray*)pk)[0] isEqualToString:@"hello"], "packet type round-trips as NSString");
}

static void test_varlen(void) {
    // round-trip a large list (>63) and large dict (>24) through encode->decode
    NSMutableArray *big = [NSMutableArray array];
    for (int i=0;i<70;i++) [big addObject:@(i)];
    rt(big, "rt list of 70 (variable-length)");
    NSMutableDictionary *bd = [NSMutableDictionary dictionary];
    for (int i=0;i<30;i++) bd[[NSString stringWithFormat:@"k%02d", i]] = @(i);
    // NSString keys now round-trip as NSString (str type), so the whole dict round-trips:
    NSData *e = [PortholeProtocol encodeValue:bd];
    NSUInteger o=0; NSDictionary *back = [PortholeProtocol decodeValue:e offset:&o];
    CHECK(o==e.length && back.count==30, "rt dict of 30 (variable-length) count");
    CHECK([back[@"k05"] isEqual:@5], "rt dict of 30 value lookup");
    // decode a REAL variable-length list header/terminator shape: [64 zero-ints]
    NSMutableData *vl = [NSMutableData data];
    uint8_t lt=0x3b; [vl appendBytes:&lt length:1];
    for (int i=0;i<64;i++){ uint8_t z=0; [vl appendBytes:&z length:1]; }
    uint8_t term=0x7f; [vl appendBytes:&term length:1];
    NSUInteger o2=0; NSArray *dl=[PortholeProtocol decodeValue:vl offset:&o2];
    CHECK(o2==vl.length && dl.count==64, "decode variable-length list w/ terminator");
}

static void test_lz4(void) {
    // A real xpra lz4 vector: "The quick brown fox jumps over the lazy dog. " x4
    // (4-byte LE size 0xb4=180, then the lz4 block; exercises literal-extension + a match).
    NSMutableData *exp = [NSMutableData data];
    NSData *unit = [@"The quick brown fox jumps over the lazy dog. " dataUsingEncoding:NSUTF8StringEncoding];
    for (int i = 0; i < 4; i++) [exp appendData:unit];
    NSData *comp = hex("b4000000ff1e54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e202d006f50646f672e20");
    NSData *out = [PortholeProtocol inflateLZ4:comp];
    CHECK(out != nil, "lz4 inflate returns data");
    CHECK(out.length == 180, "lz4 output length 180");
    CHECK([out isEqual:exp], "lz4 inflate matches expected");
    // malformed / hostile input must return nil (never OOB), per the codec's hardening:
    CHECK([PortholeProtocol inflateLZ4:hex("ff")] == nil, "lz4 header < 4 bytes -> nil");
    CHECK([PortholeProtocol inflateLZ4:hex("64000000ff")] == nil, "lz4 truncated block -> nil");
    CHECK([[PortholeProtocol inflateLZ4:hex("00000000")] length] == 0, "lz4 zero size -> empty");
}

int main(void) {
    @autoreleasepool {
        test_header();
        test_decode();
        test_decode_malformed();
        test_encode();
        test_str();
        test_varlen();
        test_lz4();
        if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
        fprintf(stderr, "OK\n"); return 0;
    }
}
