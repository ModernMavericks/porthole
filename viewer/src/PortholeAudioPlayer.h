#import <Foundation/Foundation.h>

// Plays a continuous stream of encoded audio chunks (MP3) out the Mac speakers via
// Core Audio. The remote app's forwarded sound arrives as a series of MP3 byte
// chunks; feed each to -playChunk:. -reset stops playback and clears state (the
// stream ended). MP3 is decoded natively by AudioToolbox (nothing bundled), so this
// stays 10.9-safe. Feed on the main run loop; AudioQueue does playback on its own
// thread and this class is internally synchronized for buffer recycling.
@interface PortholeAudioPlayer : NSObject
- (void)playChunk:(NSData *)mp3;
- (void)reset;
@end
