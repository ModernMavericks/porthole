#import <Cocoa/Cocoa.h>
#import "PortholeMenuProducer.h"

// Owns the current menu model and drives one contiguous range of top-level menus
// in `mainMenu`, inserted just before `windowHolder`. App/Edit/Window stay
// engine-owned. Renders whatever the ACTIVE producer supplies; applies deltas in
// place; lazy-loads submenus; routes clicks to the active producer via nodeId.
@interface PortholeMenuController : NSObject <PortholeMenuProducerDelegate, NSMenuDelegate>
// mainMenu is [NSApp mainMenu]; windowHolder is the top-level "Window" item that the
// app menus are inserted BEFORE. The active producer is set via -useProducer:.
- (id)initWithMainMenu:(NSMenu *)mainMenu windowHolder:(NSMenuItem *)windowHolder;
// Make `p` the active producer and (re)start it. Its didSnapshot rebuilds the range.
- (void)useProducer:(id<PortholeMenuProducer>)p;
// Static (fallback) + remote (preferred) producers. The controller shows static
// immediately; when the remote sends its first snapshot it "upgrades" to remote;
// when the remote ends it reverts to static. Either may be nil.
- (void)useStaticProducer:(id<PortholeMenuProducer>)staticP remoteProducer:(id<PortholeMenuProducer>)remoteP;
// Test seam: the number of top-level app menus currently inserted.
- (NSUInteger)appMenuCount;
// Test seam: the NSMenuItem currently bound to a nodeId, or nil.
- (NSMenuItem *)itemForNodeId:(NSInteger)nodeId;
@end
