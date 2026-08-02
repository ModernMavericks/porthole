#import <Cocoa/Cocoa.h>
#import "PortholeMenuController.h"
#import "PortholeMenuModel.h"
#include <assert.h>

// A trivial producer the test drives by hand.
@interface FakeProducer : NSObject <PortholeMenuProducer>
@property(assign) id<PortholeMenuProducerDelegate> delegate;
@property(retain) NSArray *snapshot;
@property(assign) NSInteger lastInvoked;
@end
@implementation FakeProducer
- (void)start { [_delegate producer:self didSnapshot:_snapshot]; }
- (void)openNode:(NSInteger)n {}
- (void)invokeNode:(NSInteger)n { _lastInvoked = n; }
- (void)stop {}
- (void)dealloc { [_snapshot release]; [super dealloc]; }
@end

static PortholeMenuNode *mk(NSInteger i, NSString *role, NSString *label) {
    PortholeMenuNode *n = [[[PortholeMenuNode alloc] init] autorelease];
    n.nodeId = i; n.role = role; n.label = label; n.children = [NSMutableArray array];
    return n;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];   // NSMenu needs the app object (not a run loop)
        NSMenu *main = [[[NSMenu alloc] initWithTitle:@""] autorelease];
        [main addItemWithTitle:@"" action:NULL keyEquivalent:@""];       // App
        [main addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];   // Edit
        NSMenuItem *winHolder = [main addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];

        PortholeMenuController *c = [[[PortholeMenuController alloc]
            initWithMainMenu:main windowHolder:winHolder] autorelease];

        PortholeMenuNode *file = mk(1, @"submenu", @"File");
        PortholeMenuNode *save = mk(2, @"item", @"Save"); save.enabled = YES;
        PortholeMenuNode *reload = mk(3, @"item", @"Reload"); reload.enabled = NO;
        [file.children addObject:save];
        [file.children addObject:reload];

        FakeProducer *fp = [[[FakeProducer alloc] init] autorelease];
        fp.snapshot = @[file];
        [c useProducer:fp];

        assert([c appMenuCount] == 1);
        // Inserted between Edit (index 1) and Window (now index 3).
        NSInteger fileIdx = [main indexOfItemWithTitle:@"File"];
        NSInteger winIdx  = [main indexOfItemWithTitle:@"Window"];
        assert(fileIdx == 2 && winIdx == 3);

        NSMenuItem *saveItem = [c itemForNodeId:2];
        NSMenuItem *reloadItem = [c itemForNodeId:3];
        assert(saveItem && [saveItem isEnabled]);
        assert(reloadItem && ![reloadItem isEnabled]);   // gray-out from the model

        // Invoking routes to the producer by nodeId.
        [saveItem.target performSelector:saveItem.action withObject:saveItem];
        assert(fp.lastInvoked == 2);

        // --- delta: flip enabled + checked + label in place, no rebuild ---
        NSMenuItem *fileHolderBefore = [c itemForNodeId:1];
        [c producer:fp didDelta:@[
            @{@"id": @3, @"enabled": @YES},                 // Reload becomes enabled
            @{@"id": @2, @"label": @"Save All"},            // Save relabeled
        ]];
        assert([[c itemForNodeId:3] isEnabled]);
        assert([[[c itemForNodeId:2] title] isEqualToString:@"Save All"]);
        // Same holder object -> no rebuild happened.
        assert([c itemForNodeId:1] == fileHolderBefore);

        [c producer:fp didDelta:@[@{@"id": @2, @"enabled": @NO}]];
        assert(![[c itemForNodeId:2] isEnabled]);   // @NO applied, not skipped

        // --- lazy submenu: opening requests children; didPopulate fills them ---
        PortholeMenuNode *tools = mk(10, @"submenu", @"Tools"); tools.lazy = YES;  // no children yet
        FakeProducer *fp2 = [[[FakeProducer alloc] init] autorelease];
        fp2.snapshot = @[tools];
        __block NSInteger opened = 0;
        [c useProducer:fp2];
        NSMenuItem *toolsHolder = [c itemForNodeId:10];
        assert([[toolsHolder submenu] numberOfItems] == 0);
        // Simulate the delegate callback the OS fires when the menu opens:
        [c menuNeedsUpdate:[toolsHolder submenu]];
        // Producer answers with children:
        PortholeMenuNode *opt = mk(11, @"item", @"Options"); opt.enabled = YES;
        [c producer:fp2 didPopulate:10 children:@[opt]];
        assert([[toolsHolder submenu] numberOfItems] == 1);
        assert([c itemForNodeId:11] != nil);
        (void)opened;

        // --- fallback: static shows first; remote upgrades; remote end reverts ---
        NSMenu *main2 = [[[NSMenu alloc] initWithTitle:@""] autorelease];
        [main2 addItemWithTitle:@"" action:NULL keyEquivalent:@""];
        [main2 addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
        NSMenuItem *win2 = [main2 addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
        PortholeMenuController *c2 = [[[PortholeMenuController alloc]
            initWithMainMenu:main2 windowHolder:win2] autorelease];

        FakeProducer *staticP = [[[FakeProducer alloc] init] autorelease];
        staticP.snapshot = @[mk(1, @"submenu", @"StaticMenu")];
        FakeProducer *remoteP = [[[FakeProducer alloc] init] autorelease];
        PortholeMenuNode *liveMenu = mk(1, @"submenu", @"LiveMenu");
        PortholeMenuNode *liveGo = mk(2, @"item", @"Go"); liveGo.enabled = YES;
        [liveMenu.children addObject:liveGo];
        remoteP.snapshot = @[liveMenu];

        [c2 useStaticProducer:staticP remoteProducer:remoteP];
        // Both were started; remote's snapshot wins -> LiveMenu shown.
        assert([main2 indexOfItemWithTitle:@"LiveMenu"] >= 0);
        assert([main2 indexOfItemWithTitle:@"StaticMenu"] < 0);
        // Invoke a leaf routes to the remote (active) producer.
        NSMenuItem *go = [c2 itemForNodeId:2];
        [go.target performSelector:go.action withObject:go];
        assert(remoteP.lastInvoked == 2);
        // Remote ends -> revert to static.
        [c2 producerDidEnd:remoteP];
        assert([main2 indexOfItemWithTitle:@"StaticMenu"] >= 0);
        assert([main2 indexOfItemWithTitle:@"LiveMenu"] < 0);

        printf("test_menu_controller: OK\n");
    }
    return 0;
}
