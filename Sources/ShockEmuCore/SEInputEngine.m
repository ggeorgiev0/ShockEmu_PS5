#import "ShockEmuCore.h"

#include <math.h>
#include <os/lock.h>

@interface SEInputEngine () {
    os_unfair_lock _lock;
    NSMutableSet<NSNumber *> *_pressedKeys;
    NSMutableSet<NSNumber *> *_pressedMouseButtons;
    double _deltaX;
    double _deltaY;
    double _filteredX;
    double _filteredY;
    uint64_t _ticks;
}
@property(nonatomic) SEProfile *profile;
@end

static double clamp_axis(double value) {
    return fmin(fmax(value, -1.0), 1.0);
}

static uint8_t encode_axis(double value) {
    return (uint8_t)lround(fmin(fmax(128.0 + clamp_axis(value) * 127.0, 0.0), 255.0));
}

static void radial_dead_zone(double *x, double *y, double deadZone) {
    double magnitude = hypot(*x, *y);
    if (magnitude <= deadZone || magnitude == 0.0) {
        *x = 0.0;
        *y = 0.0;
        return;
    }
    double outputMagnitude = fmin((magnitude - deadZone) / (1.0 - deadZone), 1.0);
    *x = (*x / magnitude) * outputMagnitude;
    *y = (*y / magnitude) * outputMagnitude;
}

static void apply_minimum_magnitude(double *x, double *y, double minimum) {
    double magnitude = hypot(*x, *y);
    if (magnitude == 0.0 || minimum == 0.0 || magnitude >= 1.0) return;
    double outputMagnitude = minimum + (1.0 - minimum) * magnitude;
    *x = (*x / magnitude) * outputMagnitude;
    *y = (*y / magnitude) * outputMagnitude;
}

@implementation SEInputEngine

- (instancetype)initWithProfile:(SEProfile *)profile {
    self = [super init];
    if (self != nil) {
        _profile = profile;
        _lock = OS_UNFAIR_LOCK_INIT;
        _pressedKeys = [NSMutableSet set];
        _pressedMouseButtons = [NSMutableSet set];
    }
    return self;
}

- (void)setKeyCode:(uint16_t)keyCode pressed:(BOOL)pressed {
    os_unfair_lock_lock(&_lock);
    if (pressed) [_pressedKeys addObject:@(keyCode)];
    else [_pressedKeys removeObject:@(keyCode)];
    os_unfair_lock_unlock(&_lock);
}

- (void)setMouseButton:(NSInteger)button pressed:(BOOL)pressed {
    os_unfair_lock_lock(&_lock);
    if (pressed) [_pressedMouseButtons addObject:@(button)];
    else [_pressedMouseButtons removeObject:@(button)];
    os_unfair_lock_unlock(&_lock);
}

- (void)addMouseDeltaX:(double)deltaX deltaY:(double)deltaY {
    os_unfair_lock_lock(&_lock);
    _deltaX += deltaX;
    _deltaY += deltaY;
    os_unfair_lock_unlock(&_lock);
}

- (NSData *)copyInputReport {
    os_unfair_lock_lock(&_lock);
    NSMutableSet<NSString *> *actions = [NSMutableSet set];
    for (NSNumber *key in _pressedKeys) {
        NSArray *values = _profile.keyBindings[key];
        [actions addObjectsFromArray:values == nil ? @[] : values];
    }
    for (NSNumber *button in _pressedMouseButtons) {
        NSArray *values = _profile.mouseBindings[button];
        [actions addObjectsFromArray:values == nil ? @[] : values];
    }

    double leftX = [self axis:@"leftX" actions:actions];
    double leftY = [self axis:@"leftY" actions:actions];
    double rightX = [self axis:@"rightX" actions:actions];
    double rightY = [self axis:@"rightY" actions:actions];
    if (_profile.mouseLookEnabled) {
        BOOL moved = _deltaX != 0.0 || _deltaY != 0.0;
        if (moved) {
            double targetX = clamp_axis(_deltaX * _profile.mouseSensitivity * _profile.mouseMultiplierX);
            double targetY = clamp_axis(_deltaY * _profile.mouseSensitivity * _profile.mouseMultiplierY);
            _filteredX = _profile.mouseSmoothing * targetX + (1.0 - _profile.mouseSmoothing) * _filteredX;
            _filteredY = _profile.mouseSmoothing * targetY + (1.0 - _profile.mouseSmoothing) * _filteredY;
        } else {
            _filteredX /= _profile.mouseDecay;
            _filteredY /= _profile.mouseDecay;
        }
        _deltaX = _deltaY = 0.0;
        if (fabs(_filteredX) < 0.001) _filteredX = 0.0;
        if (fabs(_filteredY) < 0.001) _filteredY = 0.0;
        double mouseX = _filteredX;
        double mouseY = _filteredY;
        radial_dead_zone(&mouseX, &mouseY, _profile.mouseDeadZone);
        if (moved) apply_minimum_magnitude(&mouseX, &mouseY, _profile.mouseMinimumMagnitude);
        if ([_profile.mouseStick isEqualToString:@"left"]) {
            leftX = clamp_axis(leftX + mouseX);
            leftY = clamp_axis(leftY + mouseY);
        } else {
            rightX = clamp_axis(rightX + mouseX);
            rightY = clamp_axis(rightY + mouseY);
        }
    }

    uint8_t report[64] = {
        0x01, 0x80, 0x80, 0x80, 0x80, 0x08, 0x00, 0x00, 0x00, 0x00,
        0xc8, 0xad, 0xf9, 0x04, 0x00, 0xfe, 0xff, 0xfc, 0xff, 0xe5, 0xfe,
        0xcb, 0x1f, 0x69, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1b, 0x00,
        0x00, 0x01, 0x63, 0x8b, 0x80, 0xc1, 0x2e, 0x80,
    };
    report[1] = encode_axis(leftX);
    report[2] = encode_axis(leftY);
    report[3] = encode_axis(rightX);
    report[4] = encode_axis(rightY);
    report[5] = [self faceButtons:actions] | [self dpad:actions];
    report[6] = [self shoulderButtons:actions];
    report[7] = (uint8_t)((_ticks << 2) & 0xfc) |
        ([actions containsObject:@"touchpad"] ? 2 : 0) |
        ([actions containsObject:@"PS"] ? 1 : 0);
    report[8] = [actions containsObject:@"L2"] ? 255 : 0;
    report[9] = [actions containsObject:@"R2"] ? 255 : 0;
    _ticks += 1;
    NSData *data = [NSData dataWithBytes:report length:sizeof(report)];
    os_unfair_lock_unlock(&_lock);
    return data;
}

- (double)axis:(NSString *)axis actions:(NSSet<NSString *> *)actions {
    double value = 0.0;
    if ([actions containsObject:[axis stringByAppendingString:@"-"]]) value -= 1.0;
    if ([actions containsObject:[axis stringByAppendingString:@"+"]]) value += 1.0;
    return clamp_axis(value);
}

- (uint8_t)faceButtons:(NSSet<NSString *> *)actions {
    return ([actions containsObject:@"triangle"] ? 0x80 : 0) |
        ([actions containsObject:@"O"] ? 0x40 : 0) |
        ([actions containsObject:@"X"] ? 0x20 : 0) |
        ([actions containsObject:@"square"] ? 0x10 : 0);
}

- (uint8_t)shoulderButtons:(NSSet<NSString *> *)actions {
    return ([actions containsObject:@"R3"] ? 0x80 : 0) |
        ([actions containsObject:@"L3"] ? 0x40 : 0) |
        ([actions containsObject:@"options"] ? 0x20 : 0) |
        ([actions containsObject:@"share"] ? 0x10 : 0) |
        ([actions containsObject:@"R2"] ? 0x08 : 0) |
        ([actions containsObject:@"L2"] ? 0x04 : 0) |
        ([actions containsObject:@"R1"] ? 0x02 : 0) |
        ([actions containsObject:@"L1"] ? 0x01 : 0);
}

- (uint8_t)dpad:(NSSet<NSString *> *)actions {
    BOOL up = [actions containsObject:@"dpadUp"];
    BOOL down = [actions containsObject:@"dpadDown"];
    BOOL left = [actions containsObject:@"dpadLeft"];
    BOOL right = [actions containsObject:@"dpadRight"];
    if (left) return up ? 7 : (down ? 5 : 6);
    if (right) return up ? 1 : (down ? 3 : 2);
    if (up) return 0;
    if (down) return 4;
    return 8;
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    [_pressedKeys removeAllObjects];
    [_pressedMouseButtons removeAllObjects];
    _deltaX = _deltaY = _filteredX = _filteredY = 0.0;
    os_unfair_lock_unlock(&_lock);
}

@end
