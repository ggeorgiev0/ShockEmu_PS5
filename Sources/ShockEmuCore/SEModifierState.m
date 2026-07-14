#import "ShockEmuCore.h"

@interface SEModifierState ()
@property(nonatomic) SEInputEngine *inputEngine;
@property(nonatomic) NSMutableSet<NSNumber *> *pressedPhysicalKeys;
@end

static uint16_t logical_key_code(uint16_t physicalCode) {
    switch (physicalCode) {
        case 60: return 56;
        case 62: return 59;
        case 61: return 58;
        case 54: return 55;
        default: return physicalCode;
    }
}

@implementation SEModifierState

- (instancetype)initWithInputEngine:(SEInputEngine *)inputEngine {
    self = [super init];
    if (self != nil) {
        _inputEngine = inputEngine;
        _pressedPhysicalKeys = [NSMutableSet set];
    }
    return self;
}

- (void)togglePhysicalKeyCode:(uint16_t)keyCode {
    NSNumber *physical = @(keyCode);
    if ([_pressedPhysicalKeys containsObject:physical]) [_pressedPhysicalKeys removeObject:physical];
    else [_pressedPhysicalKeys addObject:physical];
    uint16_t logical = logical_key_code(keyCode);
    BOOL pressed = NO;
    for (NSNumber *candidate in _pressedPhysicalKeys) {
        if (logical_key_code(candidate.unsignedShortValue) == logical) {
            pressed = YES;
            break;
        }
    }
    [_inputEngine setKeyCode:logical pressed:pressed];
}

- (void)clear {
    NSArray<NSNumber *> *keys = _pressedPhysicalKeys.allObjects;
    [_pressedPhysicalKeys removeAllObjects];
    for (NSNumber *key in keys) {
        [_inputEngine setKeyCode:logical_key_code(key.unsignedShortValue) pressed:NO];
    }
}

@end
