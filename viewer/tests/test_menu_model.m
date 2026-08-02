#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "PortholeMenuModel.h"
#import "PortholeStaticMenuProducer.h"
#include <assert.h>

@interface TestDelegate : NSObject <PortholeMenuProducerDelegate>
@property(copy) void (^onSnapshot)(NSArray *);
@end
@implementation TestDelegate
- (void)producer:(id)p didSnapshot:(NSArray *)n { if (_onSnapshot) _onSnapshot(n); }
- (void)producer:(id)p didDelta:(NSArray *)c {}
- (void)producer:(id)p didPopulate:(NSInteger)i children:(NSArray *)c {}
- (void)producerDidEnd:(id)p {}
- (void)dealloc { [_onSnapshot release]; [super dealloc]; }
@end

@interface TestInvoker : NSObject <PortholeMenuStaticInvoker>
@property(copy) void (^onSend)(NSString *);
@end
@implementation TestInvoker
- (void)invokeSendString:(NSString *)s { if (_onSend) _onSend(s); }
- (void)dealloc { [_onSend release]; [super dealloc]; }
@end

int main(void) {
    @autoreleasepool {
        NSArray *wire = @[@{
            @"id": @1, @"role": @"submenu", @"label": @"File", @"enabled": @YES,
            @"children": @[
                @{@"id": @2, @"role": @"item", @"label": @"Save",
                  @"enabled": @YES, @"accel": @{@"key": @"s", @"mods": @[@"cmd"]}},
                @{@"id": @3, @"role": @"separator"},
                @{@"id": @4, @"role": @"item", @"label": @"Reload", @"enabled": @NO},
            ],
        }];
        NSArray *nodes = [PortholeMenuNode nodesFromArray:wire];
        assert(nodes.count == 1);
        PortholeMenuNode *file = nodes[0];
        assert([file.role isEqualToString:@"submenu"]);
        assert([file.label isEqualToString:@"File"]);
        assert(file.children.count == 3);
        PortholeMenuNode *save = file.children[0];
        assert(save.nodeId == 2);
        assert(save.enabled);
        assert([save.accelKey isEqualToString:@"s"]);
        assert((save.accelMods & NSCommandKeyMask) != 0);
        PortholeMenuNode *sep = file.children[1];
        assert([sep.role isEqualToString:@"separator"]);
        PortholeMenuNode *reload = file.children[2];
        assert(!reload.enabled);
        // visible defaults to YES when the key is absent
        assert(file.visible);
        // --- static producer: menu.json dict -> snapshot + invoke mapping ---
        NSDictionary *mj = @{@"menus": @[@{
            @"title": @"Edit", @"items": @[
                @{@"title": @"Lock", @"send": @"ctrl+shift+l"},
                @{@"separator": @YES},
                @{@"title": @"Quit", @"send": @"@quit", @"key": @"q"},
            ]}]};
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"porthole-test-menu.json"];
        [[NSJSONSerialization dataWithJSONObject:mj options:0 error:NULL] writeToFile:tmp atomically:YES];

        __block NSArray *snap = nil;
        __block NSString *invoked = nil;
        TestDelegate *del = [[[TestDelegate alloc] init] autorelease];
        del.onSnapshot = ^(NSArray *nodes){ snap = [nodes retain]; };
        TestInvoker *inv = [[[TestInvoker alloc] init] autorelease];
        inv.onSend = ^(NSString *s){ invoked = [s retain]; };

        PortholeStaticMenuProducer *sp = [[[PortholeStaticMenuProducer alloc]
            initWithJSONPath:tmp invoker:inv] autorelease];
        sp.delegate = del;
        [sp start];
        assert(snap.count == 1);                       // one top-level menu: Edit
        PortholeMenuNode *editM = snap[0];
        assert([editM.label isEqualToString:@"Edit"]);
        assert(editM.children.count == 3);             // Lock, separator, Quit
        PortholeMenuNode *lock = editM.children[0];
        assert([lock.label isEqualToString:@"Lock"]);
        [sp invokeNode:lock.nodeId];
        assert([invoked isEqualToString:@"ctrl+shift+l"]);  // id -> original send

        printf("test_menu_model: OK\n");
    }
    return 0;
}
