#import "PortholeMenuController.h"
#import "PortholeMenuModel.h"

@implementation PortholeMenuController {
    NSMenu *_mainMenu;              // weak (owned by NSApp)
    NSMenuItem *_windowHolder;      // weak (lives in _mainMenu)
    id<PortholeMenuProducer> _active;     // weak (owned by the app delegate)
    id<PortholeMenuProducer> _static;    // weak
    id<PortholeMenuProducer> _remote;    // weak
    NSArray *_lastStaticSnapshot;  // to restore on revert
    NSMutableArray *_appHolders;    // NSMenuItem* top-level menus we inserted
    NSMapTable *_itemById;          // nodeId -> NSMenuItem (strong values; flushed by removeAllObjects in rebuildTopLevel before the menu tears items down)
    NSMapTable *_nodeById;          // nodeId -> PortholeMenuNode (for lazy/open)
    NSMapTable *_nodeIdByMenu;      // NSMenu -> nodeId(NSNumber)
}

- (id)initWithMainMenu:(NSMenu *)mainMenu windowHolder:(NSMenuItem *)windowHolder {
    if ((self = [super init])) {
        _mainMenu = mainMenu;
        _windowHolder = windowHolder;
        _appHolders = [[NSMutableArray alloc] init];
        _itemById = [[NSMapTable strongToStrongObjectsMapTable] retain];
        _nodeById = [[NSMapTable strongToStrongObjectsMapTable] retain];
        _nodeIdByMenu = [[NSMapTable weakToStrongObjectsMapTable] retain];
    }
    return self;
}

- (void)useProducer:(id<PortholeMenuProducer>)p {
    _active = p;
    p.delegate = self;
    [p start];
}

- (void)useStaticProducer:(id<PortholeMenuProducer>)staticP remoteProducer:(id<PortholeMenuProducer>)remoteP {
    _static = staticP; _remote = remoteP;
    if (staticP) { staticP.delegate = self; _active = staticP; [staticP start]; }
    if (remoteP) { remoteP.delegate = self; [remoteP start]; }  // upgrades on its snapshot
}

- (NSString *)macKeyEquivFor:(PortholeMenuNode *)n { return n.accelKey ?: @""; }

- (NSMenuItem *)buildItem:(PortholeMenuNode *)n intoMenu:(NSMenu *)menu {
    if ([n.role isEqualToString:@"separator"]) {
        [menu addItem:[NSMenuItem separatorItem]];
        return nil;
    }
    NSMenuItem *it = [menu addItemWithTitle:(n.label ?: @"")
        action:@selector(menuInvoke:) keyEquivalent:[self macKeyEquivFor:n]];
    if (n.accelKey.length) [it setKeyEquivalentModifierMask:n.accelMods];
    [it setTarget:self];
    [it setEnabled:n.enabled];
    [it setHidden:!n.visible];
    if (n.hasChecked) [it setState:(n.checked ? NSOnState : NSOffState)];
    [it setRepresentedObject:@(n.nodeId)];
    [_itemById setObject:it forKey:@(n.nodeId)];
    [_nodeById setObject:n forKey:@(n.nodeId)];
    if ([n.role isEqualToString:@"submenu"]) {
        NSMenu *sub = [[[NSMenu alloc] initWithTitle:(n.label ?: @"")] autorelease];
        [sub setDelegate:self];
        [it setSubmenu:sub];
        [_nodeIdByMenu setObject:@(n.nodeId) forKey:sub];
        [it setAction:NULL];   // a submenu holder isn't itself invoked
        for (PortholeMenuNode *c in n.children) [self buildItem:c intoMenu:sub];
    }
    return it;
}

- (void)rebuildTopLevel:(NSArray *)topLevelNodes {
    for (NSMenuItem *h in _appHolders) [_mainMenu removeItem:h];
    [_appHolders removeAllObjects];
    [_itemById removeAllObjects];
    [_nodeById removeAllObjects];
    NSInteger insertAt = [_mainMenu indexOfItem:_windowHolder];
    if (insertAt < 0) insertAt = [_mainMenu numberOfItems];
    for (PortholeMenuNode *top in topLevelNodes) {
        NSMenuItem *holder = [[[NSMenuItem alloc] initWithTitle:(top.label ?: @"")
            action:NULL keyEquivalent:@""] autorelease];   // a submenu holder isn't itself invoked
        NSMenu *sub = [[[NSMenu alloc] initWithTitle:(top.label ?: @"")] autorelease];
        [sub setDelegate:self];
        [holder setSubmenu:sub];
        [_nodeIdByMenu setObject:@(top.nodeId) forKey:sub];
        [_itemById setObject:holder forKey:@(top.nodeId)];
        [_nodeById setObject:top forKey:@(top.nodeId)];
        for (PortholeMenuNode *c in top.children) [self buildItem:c intoMenu:sub];
        [_mainMenu insertItem:holder atIndex:insertAt++];
        [_appHolders addObject:holder];
    }
}

- (void)menuInvoke:(NSMenuItem *)sender {
    NSNumber *nid = [sender representedObject];
    if (nid && _active) [_active invokeNode:[nid integerValue]];
}

// --- PortholeMenuProducerDelegate (main thread) ---
- (void)producer:(id<PortholeMenuProducer>)p didSnapshot:(NSArray *)topLevelNodes {
    if (p == _static) { [_lastStaticSnapshot release]; _lastStaticSnapshot = [topLevelNodes copy]; }
    // A remote snapshot always wins and becomes active (the "upgrade").
    if (p == _remote) _active = _remote;
    else if (p != _active) return;   // stale static snapshot while remote is active
    [self rebuildTopLevel:topLevelNodes];
}
- (void)producer:(id<PortholeMenuProducer>)p didDelta:(NSArray *)changes {
    if (p != _active) return;
    for (NSDictionary *ch in changes) {
        if (![ch isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *nid = ch[@"id"];
        if (!nid) continue;
        NSMenuItem *it = [_itemById objectForKey:nid];
        if (!it) continue;   // unknown id -> ignore (spec §6)
        if (ch[@"enabled"]) [it setEnabled:[ch[@"enabled"] boolValue]];
        else if (ch[@"enabled"] == [NSNull null]) {}
        if (ch[@"visible"] != nil) [it setHidden:![ch[@"visible"] boolValue]];
        if (ch[@"label"])   [it setTitle:ch[@"label"]];
        if (ch[@"checked"] != nil)
            [it setState:([ch[@"checked"] boolValue] ? NSOnState : NSOffState)];
    }
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSNumber *nid = [_nodeIdByMenu objectForKey:menu];
    PortholeMenuNode *node = nid ? [_nodeById objectForKey:nid] : nil;
    if (node && node.lazy && menu.numberOfItems == 0 && _active)
        [_active openNode:[nid integerValue]];
}
- (void)producer:(id<PortholeMenuProducer>)p didPopulate:(NSInteger)nodeId children:(NSArray *)children {
    if (p != _active) return;
    NSMenuItem *holder = [_itemById objectForKey:@(nodeId)];
    NSMenu *sub = [holder submenu];
    if (!sub) return;
    [sub removeAllItems];
    for (PortholeMenuNode *c in children) [self buildItem:c intoMenu:sub];
    PortholeMenuNode *node = [_nodeById objectForKey:@(nodeId)];
    node.lazy = NO;   // populated; don't re-request until a fresh snapshot
}
- (void)producerDidEnd:(id<PortholeMenuProducer>)p {
    if (p != _remote) return;
    if (_active == _remote) {
        _active = _static;
        if (_lastStaticSnapshot) [self rebuildTopLevel:_lastStaticSnapshot];
        else [self rebuildTopLevel:@[]];
    }
}

// --- test seams ---
- (NSUInteger)appMenuCount { return _appHolders.count; }
- (NSMenuItem *)itemForNodeId:(NSInteger)nodeId { return [_itemById objectForKey:@(nodeId)]; }

- (void)dealloc {
    [_lastStaticSnapshot release];
    [_appHolders release]; [_itemById release]; [_nodeById release]; [_nodeIdByMenu release];
    [super dealloc];
}
@end
