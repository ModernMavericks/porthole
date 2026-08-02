#import "PortholeStaticMenuProducer.h"
#import "PortholeMenuModel.h"
#import <AppKit/AppKit.h>   // NSCommandKeyMask etc. are compile-time enum constants
                            // (no AppKit link needed; test_menu_model stays Foundation-only)

@implementation PortholeStaticMenuProducer {
    NSString *_jsonPath;
    id<PortholeMenuStaticInvoker> _invoker;      // weak
    NSMutableDictionary *_sendById;        // nodeId(NSNumber) -> send string
    NSArray *_snapshot;                    // NSArray<PortholeMenuNode*>
    NSInteger _nextId;
}
@synthesize delegate = _delegate;

- (id)initWithJSONPath:(NSString *)jsonPath invoker:(id<PortholeMenuStaticInvoker>)invoker {
    if ((self = [super init])) {
        _jsonPath = [jsonPath copy];
        _invoker = invoker;
        _sendById = [[NSMutableDictionary alloc] init];
        _nextId = 1;
    }
    return self;
}

// menu.json ("key"/"shift"/"alt") -> the model's accel (display) fields.
- (void)applyAccelFrom:(NSDictionary *)it to:(PortholeMenuNode *)node {
    NSString *key = it[@"key"];
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return;
    if ([key isEqualToString:@"comma"]) node.accelKey = @",";
    else if ([key isEqualToString:@"period"]) node.accelKey = @".";
    else if ([key isEqualToString:@"space"]) node.accelKey = @" ";
    else if (key.length == 1) node.accelKey = [key lowercaseString];
    else return;
    NSUInteger mask = NSCommandKeyMask;
    if ([it[@"shift"] boolValue]) mask |= NSShiftKeyMask;
    if ([it[@"alt"]   boolValue]) mask |= NSAlternateKeyMask;
    node.accelMods = mask;
}

- (void)start {
    NSMutableArray *top = [NSMutableArray array];
    NSData *d = _jsonPath ? [NSData dataWithContentsOfFile:_jsonPath] : nil;
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    for (NSDictionary *menuSpec in root[@"menus"]) {
        if (![menuSpec isKindOfClass:[NSDictionary class]]) continue;
        PortholeMenuNode *m = [[[PortholeMenuNode alloc] init] autorelease];
        m.nodeId = _nextId++;
        m.role = @"submenu";
        m.label = menuSpec[@"title"] ?: @"";
        m.children = [NSMutableArray array];
        for (NSDictionary *it in menuSpec[@"items"]) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            PortholeMenuNode *node = [[[PortholeMenuNode alloc] init] autorelease];
            node.nodeId = _nextId++;
            if ([it[@"separator"] boolValue]) { node.role = @"separator"; }
            else {
                node.role = @"item";
                node.label = it[@"title"] ?: @"";
                [self applyAccelFrom:it to:node];
                NSString *send = it[@"send"];
                if ([send isKindOfClass:[NSString class]] && send.length)
                    _sendById[@(node.nodeId)] = send;
            }
            [m.children addObject:node];
        }
        [top addObject:m];
    }
    [_snapshot release]; _snapshot = [top retain];
    [_delegate producer:self didSnapshot:_snapshot];
}

- (void)openNode:(NSInteger)nodeId { (void)nodeId; }   // static menus are fully materialized
- (void)invokeNode:(NSInteger)nodeId {
    NSString *send = _sendById[@(nodeId)];
    if (send) [_invoker invokeSendString:send];
}
- (void)stop {}

- (void)dealloc {
    [_jsonPath release]; [_sendById release]; [_snapshot release];
    [super dealloc];
}
@end
