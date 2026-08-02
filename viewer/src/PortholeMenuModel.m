#import "PortholeMenuModel.h"
#import <AppKit/AppKit.h>   // NSCommandKeyMask etc. (compile-time constants only)

@implementation PortholeMenuNode

- (id)init {
    if ((self = [super init])) { _enabled = YES; _visible = YES; }
    return self;
}

+ (NSUInteger)modsFromArray:(NSArray *)mods {
    NSUInteger m = 0;
    for (NSString *s in mods) {
        if ([s isEqualToString:@"cmd"])   m |= NSCommandKeyMask;
        else if ([s isEqualToString:@"shift"]) m |= NSShiftKeyMask;
        else if ([s isEqualToString:@"alt"])   m |= NSAlternateKeyMask;
        else if ([s isEqualToString:@"ctrl"])  m |= NSControlKeyMask;
    }
    return m;
}

+ (PortholeMenuNode *)nodeFromDict:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    PortholeMenuNode *n = [[[PortholeMenuNode alloc] init] autorelease];
    n.nodeId = [d[@"id"] integerValue];
    n.role   = d[@"role"] ?: @"item";
    n.label  = d[@"label"] ?: @"";
    if (d[@"enabled"]) n.enabled = [d[@"enabled"] boolValue];
    if (d[@"visible"]) n.visible = [d[@"visible"] boolValue];
    if (d[@"checked"] != nil) { n.hasChecked = YES; n.checked = [d[@"checked"] boolValue]; }
    n.lazy = [d[@"lazy"] boolValue];
    NSDictionary *accel = d[@"accel"];
    if ([accel isKindOfClass:[NSDictionary class]]) {
        n.accelKey  = accel[@"key"];
        n.accelMods = [PortholeMenuNode modsFromArray:accel[@"mods"]];
    }
    n.children = [NSMutableArray array];
    for (NSDictionary *cd in d[@"children"]) {
        PortholeMenuNode *c = [PortholeMenuNode nodeFromDict:cd];
        if (c) [n.children addObject:c];
    }
    return n;
}

+ (NSArray *)nodesFromArray:(NSArray *)arr {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in arr) {
        PortholeMenuNode *n = [PortholeMenuNode nodeFromDict:d];
        if (n) [out addObject:n];
    }
    return out;
}

- (void)dealloc {
    [_role release]; [_label release]; [_accelKey release]; [_children release];
    [super dealloc];
}
@end
