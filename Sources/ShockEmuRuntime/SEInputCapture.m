#import "SERuntimeInternal.h"

#import <CoreGraphics/CoreGraphics.h>

@interface SEInputCapture : NSObject
@property(nonatomic) SEInputEngine *engine;
@property(nonatomic) NSString *source;
@property(nonatomic) id localMonitor;
@property(nonatomic) SEModifierState *modifierState;
@property(nonatomic) SEMouseCapturePolicy *mouseCapturePolicy;
@property(nonatomic) BOOL cursorCaptured;
@property(nonatomic) CFMachPortRef eventTap;
@property(nonatomic) CFRunLoopSourceRef eventTapSource;
@end

static CGEventRef event_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *context
);

static BOOL is_streaming_window(NSWindow *window) {
    if (window == nil) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name isEqualToString:@"RemotePlay.RPWindowStreaming"] ||
        [name isEqualToString:@"_TtC10RemotePlay17RPWindowStreaming"];
}

static BOOL is_mouse_capture_hotkey(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown || event.isARepeat || event.keyCode != 46) return NO;
    NSEventModifierFlags relevant = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    return relevant == (NSEventModifierFlagControl | NSEventModifierFlagOption);
}

@implementation SEInputCapture

- (instancetype)initWithEngine:(SEInputEngine *)engine source:(NSString *)source {
    self = [super init];
    if (self != nil) {
        _engine = engine;
        _source = source;
        _modifierState = [[SEModifierState alloc] initWithInputEngine:engine];
        _mouseCapturePolicy = [[SEMouseCapturePolicy alloc] init];
    }
    return self;
}

- (void)install {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(focusChanged:) name:NSApplicationDidResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(focusChanged:) name:NSApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(focusChanged:) name:NSWindowDidBecomeKeyNotification object:nil];
    [center addObserver:self selector:@selector(focusChanged:) name:NSWindowDidResignKeyNotification object:nil];
    [center addObserver:self selector:@selector(willTerminate:) name:NSApplicationWillTerminateNotification object:nil];
    if (![_source isEqualToString:@"event-tap"]) [self installLocalMonitor];
    [_mouseCapturePolicy setStreamingActive:[self isActive]];
    [self refreshEventTap];
    [self refreshMouseCapture];
}

- (BOOL)isActive {
    NSWindow *window = NSApp.keyWindow;
    BOOL active = NSApp.isActive && is_streaming_window(window);
    if (active) window.acceptsMouseMovedEvents = YES;
    return active;
}

- (void)installLocalMonitor {
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
        NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown |
        NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
        NSEventMaskOtherMouseDragged;
    __weak SEInputCapture *weakSelf = self;
    _localMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        [weakSelf handleEvent:event];
        return event;
    }];
}

- (void)handleEvent:(NSEvent *)event {
    if (![self isActive]) { [self deactivate]; return; }
    if (is_mouse_capture_hotkey(event)) {
        [_mouseCapturePolicy toggleCaptureRequested];
        [self refreshMouseCapture];
        return;
    }
    switch (event.type) {
        case NSEventTypeKeyDown: [_engine setKeyCode:event.keyCode pressed:YES]; break;
        case NSEventTypeKeyUp: [_engine setKeyCode:event.keyCode pressed:NO]; break;
        case NSEventTypeFlagsChanged: [_modifierState togglePhysicalKeyCode:event.keyCode]; break;
        case NSEventTypeLeftMouseDown: case NSEventTypeRightMouseDown: case NSEventTypeOtherMouseDown:
            [_engine setMouseButton:event.buttonNumber pressed:YES]; break;
        case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseUp: case NSEventTypeOtherMouseUp:
            [_engine setMouseButton:event.buttonNumber pressed:NO]; break;
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
            [_engine addMouseDeltaX:event.deltaX deltaY:event.deltaY]; break;
        default: break;
    }
}

- (void)focusChanged:(NSNotification *)notification {
    (void)notification;
    BOOL active = [self isActive];
    [_mouseCapturePolicy setStreamingActive:active];
    if (!active) [self deactivate];
    [self refreshEventTap];
    [self refreshMouseCapture];
}

- (void)deactivate {
    [_mouseCapturePolicy setStreamingActive:NO];
    [self refreshMouseCapture];
    [_modifierState clear];
    [_engine clear];
    SEDeactivateAllInput();
}

- (void)refreshMouseCapture {
    BOOL shouldCapture = _mouseCapturePolicy.shouldCapture;
    if (shouldCapture == _cursorCaptured) return;
    if (shouldCapture) {
        if (CGAssociateMouseAndMouseCursorPosition(false) != kCGErrorSuccess) return;
        if (CGDisplayHideCursor(CGMainDisplayID()) != kCGErrorSuccess) {
            CGAssociateMouseAndMouseCursorPosition(true);
            return;
        }
        _cursorCaptured = YES;
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        CGDisplayShowCursor(CGMainDisplayID());
        _cursorCaptured = NO;
    }
}

- (void)willTerminate:(NSNotification *)notification {
    (void)notification;
    [_mouseCapturePolicy setStreamingActive:NO];
    [self refreshMouseCapture];
}

- (void)refreshEventTap {
    if (![_source isEqualToString:@"event-tap"]) return;
    if (![self isActive]) { [self stopEventTap]; return; }
    if (_eventTap != NULL) return;
    if (!CGPreflightListenEventAccess() && !CGRequestListenEventAccess()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged);
    _eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly, mask, event_tap_callback, (__bridge void *)self);
    if (_eventTap == NULL) return;
    _eventTapSource = CFMachPortCreateRunLoopSource(NULL, _eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _eventTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(_eventTap, true);
}

- (void)stopEventTap {
    if (_eventTapSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _eventTapSource, kCFRunLoopCommonModes);
        CFRelease(_eventTapSource);
        _eventTapSource = NULL;
    }
    if (_eventTap != NULL) { CFMachPortInvalidate(_eventTap); CFRelease(_eventTap); _eventTap = NULL; }
}

static CGEventRef event_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *context
) {
    (void)proxy;
    SEInputCapture *capture = (__bridge SEInputCapture *)context;
    if (type == kCGEventTapDisabledByTimeout) { CGEventTapEnable(capture.eventTap, true); return event; }
    if (![capture isActive]) { [capture deactivate]; return event; }
    NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
    if (nsEvent != nil) [capture handleEvent:nsEvent];
    return event;
}

@end

void SEInstallInputCapture(SEInputEngine *engine, NSString *source) {
    static SEInputCapture *capture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ capture = [[SEInputCapture alloc] initWithEngine:engine source:source]; [capture install]; });
}
