#import <Foundation/Foundation.h>

// One node type for the whole menu tree, toolkit-agnostic (see the spine spec).
// The model is ACTION-AGNOSTIC: invocation is by nodeId; a producer decides what
// an id does. accelKey/accelMods are DISPLAY-only.
@interface PortholeMenuNode : NSObject
@property(assign, nonatomic) NSInteger nodeId;
@property(copy,   nonatomic) NSString *role;    // item|submenu|separator|checkbox|radio
@property(copy,   nonatomic) NSString *label;
@property(assign, nonatomic) BOOL enabled;
@property(assign, nonatomic) BOOL visible;
@property(assign, nonatomic) BOOL hasChecked;   // whether `checked` is meaningful
@property(assign, nonatomic) BOOL checked;
@property(copy,   nonatomic) NSString *accelKey;   // display key char, or nil
@property(assign, nonatomic) NSUInteger accelMods; // NSEventModifierFlags (display)
@property(assign, nonatomic) BOOL lazy;            // children load on open
@property(retain, nonatomic) NSMutableArray *children; // of PortholeMenuNode

// Parse one wire/JSON node dict (see spec §4) into an PortholeMenuNode (recursive).
+ (PortholeMenuNode *)nodeFromDict:(NSDictionary *)d;
// Parse an array of node dicts into an NSArray<PortholeMenuNode*>.
+ (NSArray *)nodesFromArray:(NSArray *)arr;
@end
