#import "PortholeTransport.h"
#import "PortholeProtocol.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

@interface PortholeTransport () <NSStreamDelegate>
@end

@implementation PortholeTransport {
    NSString *_path;   // AF_UNIX socket path
    NSInputStream *_in; NSOutputStream *_out;
    NSMutableData *_inbuf; NSMutableData *_outbuf;
    NSMutableDictionary *_rawChunks;   // raw sub-packets (index>0) awaiting their main packet
    __weak id<PortholeTransportDelegate> _delegate;
}

// Manual accessors: under MRR the compiler won't @synthesize a weak property,
// so back it with an explicit __weak ivar (no retain).
// Delegate is declared `weak` in the header for future ARC callers, but under
// this MRR build the backing ivar is NOT zeroing -- it is effectively
// unsafe-unretained. The delegate MUST outlive the transport (in Porthole it is
// the app/client, which lives for the process). Teardown that nils the stream
// delegates + this delegate will be added when the transport is wired up (Task 6+).
- (id<PortholeTransportDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<PortholeTransportDelegate>)delegate { _delegate = delegate; }

- (instancetype)initWithSocketPath:(NSString *)path {
    if ((self = [super init])) { _path=[path copy]; _inbuf=[[NSMutableData alloc] init]; _outbuf=[[NSMutableData alloc] init]; }
    return self;
}

- (void)connect {
    // AF_UNIX: the launcher forwards the container's xpra Unix socket to this
    // Mac-side socket path (socat over `docker exec -i`). Connect a POSIX socket
    // and wrap its fd in CFStreams (there is no CFStream unix-path convenience).
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { [self.delegate transport:self didFailWithError:@"socket() failed"]; return; }
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [_path fileSystemRepresentation], sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) != 0) {
        close(fd);
        [self.delegate transport:self didFailWithError:@"connect() failed"]; return;
    }
    CFReadStreamRef r = NULL; CFWriteStreamRef w = NULL;
    CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)fd, &r, &w);
    if (!r || !w) { close(fd);
        [self.delegate transport:self didFailWithError:@"stream pair failed"]; return; }
    // Hand the fd's lifetime to the streams (closed when they close).
    CFReadStreamSetProperty(r, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(w, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    _in = [(NSInputStream *)CFBridgingRelease(r) retain];
    _out = [(NSOutputStream *)CFBridgingRelease(w) retain];
    _in.delegate = self; _out.delegate = self;
    // Common modes (not just default): otherwise the stream is frozen during
    // live window resize / menu tracking, so we stop reading server frames mid-drag
    // and the view just scales the stale frame. Common modes keep pixels flowing.
    [_in scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_out scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_in open]; [_out open];
}

- (void)dealloc {
    [_in setDelegate:nil];
    [_out setDelegate:nil];
    [_in removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_out removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    [_in close];
    [_out close];
    [_in release];
    [_out release];
    [_path release];
    [_inbuf release];
    [_outbuf release];
    [_rawChunks release];
    [super dealloc];
}

- (void)sendPayload:(NSData *)payload {
    [_outbuf appendData:[PortholeProtocol headerForPayloadLength:(uint32_t)payload.length]];
    [_outbuf appendData:payload];
    [self pump];
}

- (void)pump {
    while (_outbuf.length && _out.hasSpaceAvailable) {
        NSInteger n = [_out write:_outbuf.bytes maxLength:_outbuf.length];
        if (n <= 0) break;
        [_outbuf replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0];
    }
}

- (void)drainInbound {
    while (_inbuf.length >= 8) {
        uint32_t plen = 0; uint8_t pindex = 0, plevel = 0;
        if (![PortholeProtocol parseHeader:_inbuf payloadLength:&plen packetIndex:&pindex level:&plevel]) {
            [self.delegate transport:self didFailWithError:@"bad header"]; return;
        }
        if (_inbuf.length < 8 + plen) break;                 // wait for full payload
        NSData *payload = [_inbuf subdataWithRange:NSMakeRange(8, plen)];
        [_inbuf replaceBytesInRange:NSMakeRange(0, 8 + plen) withBytes:NULL length:0];
        // Decompress if the frame is compressed. The level byte's LZ4_FLAG (0x10)
        // marks lz4; we advertise only lz4, so any other compressor is an error.
        if (plevel & 0x10) {
            NSData *inflated = [PortholeProtocol inflateLZ4:payload];
            if (!inflated) { [self.delegate transport:self didFailWithError:@"lz4 inflate failed"]; return; }
            if (getenv("PORTHOLE_WIRELOG"))
                NSLog(@"[LZ4] frame idx=%u inflated %u -> %lu bytes", pindex, plen, (unsigned long)inflated.length);
            payload = inflated;
        } else if (plevel != 0) {
            [self.delegate transport:self didFailWithError:@"unsupported compression"]; return;
        }
        if (pindex > 0) {
            // A raw sub-packet: the server extracted a compressed/large item from
            // position `pindex` of the packet that follows. Buffer it (already
            // inflated above if it was compressed) until the main packet arrives.
            if (!_rawChunks) _rawChunks = [[NSMutableDictionary alloc] init];
            if (_rawChunks.count >= 8) { [self.delegate transport:self didFailWithError:@"too many raw chunks"]; return; }
            _rawChunks[@(pindex)] = payload;
            continue;
        }
        NSDictionary *chunks = _rawChunks;   // nil in the common single-frame case
        _rawChunks = nil;
        [self.delegate transport:self didReceivePayload:payload rawChunks:chunks];
        [chunks release];
    }
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (e == NSStreamEventOpenCompleted && s == _out) { [self.delegate transportDidConnect:self]; }
    else if (e == NSStreamEventHasBytesAvailable && s == _in) {
        uint8_t buf[16384]; NSInteger n = [_in read:buf maxLength:sizeof buf];
        if (n > 0) { [_inbuf appendBytes:buf length:n]; [self drainInbound]; }
        // n == 0 is a clean EOF (server closed), n < 0 a read error: either way the
        // session is gone. Without this the read was silently dropped and the viewer
        // lingered as a frozen zombie (stale windows, dead socket, no reconnect).
        else { [self.delegate transport:self didFailWithError:@"connection closed"]; }
    }
    else if (e == NSStreamEventHasSpaceAvailable && s == _out) { [self pump]; }
    else if (e == NSStreamEventEndEncountered) { [self.delegate transport:self didFailWithError:@"connection closed"]; }
    else if (e == NSStreamEventErrorOccurred) { [self.delegate transport:self didFailWithError:@"stream error"]; }
}

@end
