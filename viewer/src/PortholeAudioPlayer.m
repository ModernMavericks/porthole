#import "PortholeAudioPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

// Streaming MP3 player: AudioFileStream parses the incoming MP3 bytes into audio
// packets; we pack those into a small pool of AudioQueue buffers and enqueue them for
// playback. A mutex/condition recycles buffers between the feeding thread (playChunk)
// and the AudioQueue's callback thread. Standard AudioFileStream+AudioQueue pattern.
#define NUM_BUFFERS 12
#define BUFFER_SIZE 16384
#define MAX_PACKET_DESCS 512

// Errors on this path were silently swallowed, which hid why "video with sound" stayed
// mute. Log OSStatus failures always; verbose lifecycle only under PORTHOLE_WIRELOG.
static inline BOOL PortholeAudioVerbose(void) { static int v = -1; if (v < 0) v = getenv("PORTHOLE_WIRELOG") ? 1 : 0; return v; }
#define PortholeAudioErr(st, what) do { OSStatus _s = (st); if (_s != noErr) NSLog(@"[AUDIO] %s failed: %d", (what), (int)_s); } while (0)

@implementation PortholeAudioPlayer {
    AudioFileStreamID _stream;
    AudioQueueRef _queue;
    AudioStreamBasicDescription _fmt;
    AudioQueueBufferRef _buffers[NUM_BUFFERS];
    BOOL _inuse[NUM_BUFFERS];
    int _fill;                       // index of the buffer we're filling
    size_t _bytesFilled;             // bytes used in the fill buffer
    int _packetsFilled;              // packet descs used in the fill buffer
    AudioStreamPacketDescription _descs[MAX_PACKET_DESCS];
    BOOL _started;
    BOOL _tornDown;
    pthread_mutex_t _mx;
    pthread_cond_t _cond;
}

- (instancetype)init {
    if ((self = [super init])) {
        pthread_mutex_init(&_mx, NULL);
        pthread_cond_init(&_cond, NULL);
        [self openStream];
    }
    return self;
}

- (void)openStream {
    // (void *)self as the client data -- MRR, so a plain pointer (no ARC bridging).
    AudioFileStreamOpen((void *)self, PortholeAudio_property, PortholeAudio_packets,
                        kAudioFileMP3Type, &_stream);
}

// ---- AudioFileStream callbacks ----

static void PortholeAudio_property(void *ctx, AudioFileStreamID sid,
                                 AudioFileStreamPropertyID prop, UInt32 *flags) {
    PortholeAudioPlayer *self = (PortholeAudioPlayer *)ctx;
    if (prop == kAudioFileStreamProperty_ReadyToProducePackets)
        [self buildQueue];
}

static void PortholeAudio_packets(void *ctx, UInt32 nbytes, UInt32 npackets,
                                const void *data, AudioStreamPacketDescription *descs) {
    PortholeAudioPlayer *self = (PortholeAudioPlayer *)ctx;
    [self gotPackets:npackets bytes:nbytes data:data descs:descs];
}

// ---- queue setup ----

- (void)buildQueue {
    if (_queue) return;
    UInt32 sz = sizeof(_fmt);
    OSStatus st = AudioFileStreamGetProperty(_stream, kAudioFileStreamProperty_DataFormat, &sz, &_fmt);
    if (st != noErr) { PortholeAudioErr(st, "GetProperty(DataFormat)"); return; }
    st = AudioQueueNewOutput(&_fmt, PortholeAudio_bufferDone, (void *)self, NULL, NULL, 0, &_queue);
    if (st != noErr) { PortholeAudioErr(st, "AudioQueueNewOutput"); _queue = NULL; return; }
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueAllocateBuffer(_queue, BUFFER_SIZE, &_buffers[i]);
        _inuse[i] = NO;
    }
    if (PortholeAudioVerbose())
        NSLog(@"[AUDIO] queue built: %u Hz, %u ch, ready to play",
              (unsigned)_fmt.mSampleRate, (unsigned)_fmt.mChannelsPerFrame);
}

static void PortholeAudio_bufferDone(void *ctx, AudioQueueRef q, AudioQueueBufferRef buf) {
    PortholeAudioPlayer *self = (PortholeAudioPlayer *)ctx;
    [self recycle:buf];
}

- (void)recycle:(AudioQueueBufferRef)buf {
    pthread_mutex_lock(&_mx);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        if (_buffers[i] == buf) { _inuse[i] = NO; pthread_cond_signal(&_cond); break; }
    }
    pthread_mutex_unlock(&_mx);
}

// ---- feed path ----

- (void)playChunk:(NSData *)mp3 {
    if (!_stream || _tornDown || mp3.length == 0) return;
    AudioFileStreamParseBytes(_stream, (UInt32)mp3.length, mp3.bytes, 0);
}

- (void)gotPackets:(UInt32)npackets bytes:(UInt32)nbytes data:(const void *)data
             descs:(AudioStreamPacketDescription *)descs {
    if (!_queue) return;
    for (UInt32 i = 0; i < npackets; i++) {
        SInt64 off = descs[i].mStartOffset;
        UInt32 plen = descs[i].mDataByteSize;
        // If this packet won't fit in the current fill buffer (or the desc table is
        // full), ship the current buffer and grab a fresh one.
        if (_bytesFilled + plen > BUFFER_SIZE || _packetsFilled >= MAX_PACKET_DESCS)
            [self enqueueFillBuffer];
        if (plen > BUFFER_SIZE) continue;   // a single packet bigger than a buffer: skip
        AudioQueueBufferRef b = _buffers[_fill];
        memcpy((uint8_t *)b->mAudioData + _bytesFilled, (const uint8_t *)data + off, plen);
        _descs[_packetsFilled] = descs[i];
        _descs[_packetsFilled].mStartOffset = (SInt64)_bytesFilled;
        _bytesFilled += plen;
        _packetsFilled += 1;
    }
}

- (void)enqueueFillBuffer {
    if (!_queue || _bytesFilled == 0) return;
    AudioQueueBufferRef b = _buffers[_fill];
    b->mAudioDataByteSize = (UInt32)_bytesFilled;
    PortholeAudioErr(AudioQueueEnqueueBuffer(_queue, b, _packetsFilled, _descs), "EnqueueBuffer");

    if (!_started) {
        PortholeAudioErr(AudioQueueStart(_queue, NULL), "AudioQueueStart");
        _started = YES;
        if (PortholeAudioVerbose()) NSLog(@"[AUDIO] playback started");
    }
    // Advance to the next free buffer, waiting if all are in flight.
    pthread_mutex_lock(&_mx);
    _inuse[_fill] = YES;
    int next = (_fill + 1) % NUM_BUFFERS;
    while (_inuse[next] && !_tornDown) pthread_cond_wait(&_cond, &_mx);
    _fill = next;
    pthread_mutex_unlock(&_mx);
    _bytesFilled = 0;
    _packetsFilled = 0;
}

- (void)reset {
    // Stop playback and re-open a fresh parser so the next stream starts clean.
    pthread_mutex_lock(&_mx);
    _tornDown = YES;
    pthread_cond_broadcast(&_cond);   // wake any wait in enqueueFillBuffer
    pthread_mutex_unlock(&_mx);
    if (_queue) { AudioQueueStop(_queue, true); AudioQueueDispose(_queue, true); _queue = NULL; }
    if (_stream) { AudioFileStreamClose(_stream); _stream = NULL; }
    for (int i = 0; i < NUM_BUFFERS; i++) { _buffers[i] = NULL; _inuse[i] = NO; }
    _fill = 0; _bytesFilled = 0; _packetsFilled = 0; _started = NO; _tornDown = NO;
    [self openStream];
}

- (void)dealloc {
    if (_queue) AudioQueueDispose(_queue, true);
    if (_stream) AudioFileStreamClose(_stream);
    pthread_mutex_destroy(&_mx);
    pthread_cond_destroy(&_cond);
    [super dealloc];
}
@end
