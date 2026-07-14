#import "ShockEmuCore.h"

#include <errno.h>

NSErrorDomain const SEProfileErrorDomain = @"ShockEmu.Profile";

@interface SEProfile ()
@property(nonatomic, readwrite) NSDictionary<NSNumber *, NSArray<NSString *> *> *keyBindings;
@property(nonatomic, readwrite) NSDictionary<NSNumber *, NSArray<NSString *> *> *mouseBindings;
@property(nonatomic, readwrite) NSArray<NSString *> *warnings;
@property(nonatomic, readwrite) BOOL mouseLookEnabled;
@property(nonatomic, readwrite) NSString *mouseStick;
@property(nonatomic, readwrite) double mouseSensitivity;
@property(nonatomic, readwrite) double mouseSmoothing;
@property(nonatomic, readwrite) double mouseMinimumMagnitude;
@property(nonatomic, readwrite) double mouseDecay;
@property(nonatomic, readwrite) double mouseDeadZone;
@property(nonatomic, readwrite) double mouseMultiplierX;
@property(nonatomic, readwrite) double mouseMultiplierY;
@end

static NSString *trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSDictionary<NSString *, NSNumber *> *key_codes(void) {
    static NSDictionary<NSString *, NSNumber *> *codes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSNumber *> *letters = @[
            @0, @11, @8, @2, @14, @3, @5, @4, @34, @38, @40, @37, @46,
            @45, @31, @35, @12, @15, @1, @17, @32, @9, @13, @7, @16, @6,
        ];
        NSArray<NSNumber *> *numbers = @[@29, @18, @19, @20, @21, @23, @22, @26, @28, @25];
        NSMutableDictionary *result = [@{
            @"space": @49, @"enter": @36, @"control": @59, @"option": @58,
            @"command": @55, @"up": @126, @"down": @125, @"left": @123,
            @"right": @124, @"shift": @56, @"capslock": @57, @"tab": @48,
            @"backtick": @50, @"comma": @43, @"period": @47, @"slash": @44,
            @"backslash": @42, @"delete": @51, @"escape": @53,
        } mutableCopy];
        for (NSUInteger index = 0; index < letters.count; ++index) {
            unichar character = (unichar)('a' + index);
            result[[NSString stringWithCharacters:&character length:1]] = letters[index];
        }
        for (NSUInteger index = 0; index < numbers.count; ++index) {
            result[[NSString stringWithFormat:@"%lu", (unsigned long)index]] = numbers[index];
        }
        codes = [result copy];
    });
    return codes;
}

static NSSet<NSString *> *actions(void) {
    static NSSet<NSString *> *values;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        values = [NSSet setWithArray:[@"dpadUp dpadLeft dpadRight dpadDown X O "
            "square triangle PS touchpad options share L1 L2 L3 R1 R2 R3 "
            "leftX- leftX+ leftY- leftY+ rightX- rightX+ rightY- rightY+"
            componentsSeparatedByString:@" "]];
    });
    return values;
}

static NSNumber *mouse_button(NSString *name) {
    if ([name isEqualToString:@"leftMouse"]) return @0;
    if ([name isEqualToString:@"rightMouse"]) return @1;
    if ([name isEqualToString:@"middleMouse"]) return @2;
    if ([name hasPrefix:@"mouse"] && name.length > 5) {
        NSInteger number = [[name substringFromIndex:5] integerValue];
        if (number >= 1 && number <= 31) return @(number - 1);
    }
    return nil;
}

static BOOL parse_number(NSString *text, double *result) {
    const char *start = text.UTF8String;
    char *end = NULL;
    errno = 0;
    double value = strtod(start, &end);
    if (errno != 0 || end == start || *end != '\0' || !isfinite(value)) return NO;
    *result = value;
    return YES;
}

static NSError *line_error(NSUInteger line, NSString *message) {
    return [NSError errorWithDomain:SEProfileErrorDomain code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Line %lu: %@", (unsigned long)line, message],
    }];
}

static void add_binding(
    NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *bindings,
    NSNumber *input,
    NSString *action,
    NSUInteger line,
    NSMutableArray<NSString *> *warnings
) {
    NSMutableArray<NSString *> *values = bindings[input];
    if (values == nil) {
        values = [NSMutableArray array];
        bindings[input] = values;
    }
    if ([values containsObject:action]) {
        [warnings addObject:[NSString stringWithFormat:@"Line %lu: duplicate binding ignored", (unsigned long)line]];
    } else {
        [values addObject:action];
    }
}

@implementation SEProfile

- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (self == nil) return nil;
    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (source == nil) {
        if (error != NULL) *error = line_error(1, @"profile is not valid UTF-8");
        return nil;
    }

    _mouseStick = @"right";
    _mouseSensitivity = 0.04;
    _mouseSmoothing = 0.65;
    _mouseMinimumMagnitude = 0.0;
    _mouseDecay = 10.0;
    _mouseDeadZone = 0.1;
    _mouseMultiplierX = 1.0;
    _mouseMultiplierY = 1.0;
    NSMutableDictionary *keys = [NSMutableDictionary dictionary];
    NSMutableDictionary *mouse = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *settings = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSArray<NSString *> *lines = [source componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

    for (NSUInteger index = 0; index < lines.count; ++index) {
        NSString *line = [lines[index] componentsSeparatedByString:@"#"].firstObject;
        line = trim(line);
        if (line.length == 0) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"="];
        if (parts.count != 2 || trim(parts[0]).length == 0 || trim(parts[1]).length == 0) {
            if (error != NULL) *error = line_error(index + 1, @"expected 'input = action'");
            return nil;
        }
        NSString *name = trim(parts[0]);
        NSString *value = trim(parts[1]);
        if ([name hasPrefix:@"mouseLook."]) {
            _mouseLookEnabled = YES;
            NSString *old = settings[name];
            if (old != nil) {
                if ([old isEqualToString:value]) {
                    [warnings addObject:[NSString stringWithFormat:@"Line %lu: duplicate setting ignored", (unsigned long)(index + 1)]];
                    continue;
                }
                if (error != NULL) *error = line_error(index + 1, [NSString stringWithFormat:@"conflicting setting '%@'", name]);
                return nil;
            }
            settings[name] = value;
            NSError *settingError = [self applySetting:name value:value line:index + 1];
            if (settingError != nil) {
                if (error != NULL) *error = settingError;
                return nil;
            }
            continue;
        }
        if (![actions() containsObject:value]) {
            if (error != NULL) *error = line_error(index + 1, [NSString stringWithFormat:@"unknown action '%@'", value]);
            return nil;
        }
        NSNumber *keyCode = key_codes()[name];
        NSNumber *button = mouse_button(name);
        if (keyCode != nil) add_binding(keys, keyCode, value, index + 1, warnings);
        else if (button != nil) add_binding(mouse, button, value, index + 1, warnings);
        else {
            if (error != NULL) *error = line_error(index + 1, [NSString stringWithFormat:@"unknown input '%@'", name]);
            return nil;
        }
    }
    _keyBindings = [self immutableBindings:keys];
    _mouseBindings = [self immutableBindings:mouse];
    _warnings = [warnings copy];
    return self;
}

- (NSDictionary *)immutableBindings:(NSDictionary<NSNumber *, NSMutableArray<NSString *> *> *)source {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [source enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableArray *value, BOOL *stop) {
        (void)stop;
        result[key] = [value copy];
    }];
    return [result copy];
}

- (nullable NSError *)applySetting:(NSString *)name value:(NSString *)value line:(NSUInteger)line {
    if ([name isEqualToString:@"mouseLook.type"]) {
        return [value isEqualToString:@"linear"] ? nil : line_error(line, @"mouseLook.type must be 'linear'");
    }
    if ([name isEqualToString:@"mouseLook.stick"]) {
        if (![value isEqualToString:@"left"] && ![value isEqualToString:@"right"]) return line_error(line, @"mouseLook.stick must be 'left' or 'right'");
        _mouseStick = value;
        return nil;
    }
    double number;
    if (!parse_number(value, &number)) return line_error(line, [NSString stringWithFormat:@"invalid number '%@'", value]);
    if ([name isEqualToString:@"mouseLook.sensitivity"] && number > 0) _mouseSensitivity = number;
    else if ([name isEqualToString:@"mouseLook.smoothing"] && number > 0 && number <= 1) _mouseSmoothing = number;
    else if ([name isEqualToString:@"mouseLook.minimumMagnitude"] && number >= 0 && number <= 1) _mouseMinimumMagnitude = number;
    else if ([name isEqualToString:@"mouseLook.decay"] && number >= 1) _mouseDecay = number;
    else if ([name isEqualToString:@"mouseLook.deadZone"] && number >= 0 && number < 1) _mouseDeadZone = number;
    else if ([name isEqualToString:@"mouseLook.multX"]) _mouseMultiplierX = number;
    else if ([name isEqualToString:@"mouseLook.multY"]) _mouseMultiplierY = number;
    else return line_error(line, [NSString stringWithFormat:@"unknown or out-of-range setting '%@'", name]);
    return nil;
}

@end
