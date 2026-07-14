#import "SERuntimeInternal.h"

#include <os/lock.h>

@interface SEManagerState () {
    BOOL _marked;
}
@property(nonatomic, readwrite) IOHIDManagerRef manager;
@property(atomic, readwrite, getter=isMarked) BOOL marked;
@property(nonatomic) BOOL opened;
@property(nonatomic) BOOL scheduled;
@property(nonatomic) BOOL fakeAnnounced;
@property(nonatomic) CFRunLoopRef runLoop;
@property(nonatomic) CFStringRef runLoopMode;
@property(nonatomic) CFRunLoopTimerRef timer;
@property(nonatomic) IOHIDDeviceCallback matchingCallback;
@property(nonatomic) void *matchingContext;
@property(nonatomic) IOHIDDeviceCallback removalCallback;
@property(nonatomic) void *removalContext;
@property(nonatomic) IOHIDReportCallback reportCallback;
@property(nonatomic) void *reportContext;
@property(nonatomic) uint8_t *reportBuffer;
@property(nonatomic) CFIndex reportLength;
@end

static os_unfair_lock gRegistryLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSValue *, SEManagerState *> *gStates;
static SEInputEngine *gInputEngine;
static NSObject *gFakeDeviceObject;

static void timer_callback(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    SEManagerState *state = (__bridge SEManagerState *)info;
    SEInputEngine *engine = SEGetInputEngine();
    if (engine == nil) return;
    NSData *data = [engine copyInputReport];
    IOHIDReportCallback callback = NULL;
    void *context = NULL;
    uint8_t *buffer = NULL;
    @synchronized(state) {
        if (!state.marked || !state.opened || !state.scheduled || state.reportLength < 64) return;
        callback = state.reportCallback;
        context = state.reportContext;
        buffer = state.reportBuffer;
        if (callback == NULL || buffer == NULL) return;
        memcpy(buffer, data.bytes, 64);
    }
    callback(context, kIOReturnSuccess, (void *)SEFakeDevice(), kIOHIDReportTypeInput, 0x01, buffer, 64);
}

@implementation SEManagerState

- (instancetype)initWithManager:(IOHIDManagerRef)manager {
    self = [super init];
    if (self != nil) _manager = manager;
    return self;
}

- (void)setMarked:(BOOL)marked {
    BOOL mustStop = NO;
    @synchronized(self) {
        mustStop = _marked && !marked;
        _marked = marked;
    }
    if (mustStop) [self stopAndDisappear];
    else [self updateLifecycle];
}

- (BOOL)isMarked {
    @synchronized(self) { return _marked; }
}

- (void)setOpened:(BOOL)opened {
    if (!opened) {
        [self stopAndDisappear];
        @synchronized(self) { _opened = NO; }
        return;
    }
    @synchronized(self) { _opened = YES; }
    [self updateLifecycle];
}

- (void)scheduleWithRunLoop:(CFRunLoopRef)runLoop mode:(CFStringRef)mode {
    @synchronized(self) {
        if (_runLoop != NULL) CFRelease(_runLoop);
        if (_runLoopMode != NULL) CFRelease(_runLoopMode);
        _runLoop = (CFRunLoopRef)CFRetain(runLoop);
        _runLoopMode = (CFStringRef)CFRetain(mode);
        _scheduled = YES;
    }
    [self updateLifecycle];
}

- (void)unschedule {
    [self stopAndDisappear];
    @synchronized(self) {
        _scheduled = NO;
        if (_runLoop != NULL) { CFRelease(_runLoop); _runLoop = NULL; }
        if (_runLoopMode != NULL) { CFRelease(_runLoopMode); _runLoopMode = NULL; }
    }
}

- (void)setMatchingCallback:(IOHIDDeviceCallback)callback context:(void *)context {
    @synchronized(self) { _matchingCallback = callback; _matchingContext = context; }
    [self updateLifecycle];
}

- (void)setRemovalCallback:(IOHIDDeviceCallback)callback context:(void *)context {
    @synchronized(self) { _removalCallback = callback; _removalContext = context; }
}

- (void)forwardMatchingResult:(IOReturn)result sender:(void *)sender device:(IOHIDDeviceRef)device {
    IOHIDDeviceCallback callback = NULL;
    void *context = NULL;
    @synchronized(self) {
        if (_marked) return;
        callback = _matchingCallback;
        context = _matchingContext;
    }
    if (callback != NULL) callback(context, result, sender, device);
}

- (void)forwardRemovalResult:(IOReturn)result sender:(void *)sender device:(IOHIDDeviceRef)device {
    IOHIDDeviceCallback callback = NULL;
    void *context = NULL;
    @synchronized(self) {
        if (_marked) return;
        callback = _removalCallback;
        context = _removalContext;
    }
    if (callback != NULL) callback(context, result, sender, device);
}

- (void)registerReportBuffer:(uint8_t *)buffer
                      length:(CFIndex)length
                    callback:(IOHIDReportCallback)callback
                     context:(void *)context {
    @synchronized(self) {
        _reportBuffer = buffer;
        _reportLength = length;
        _reportCallback = callback;
        _reportContext = context;
    }
    [self updateLifecycle];
}

- (void)updateLifecycle {
    IOHIDDeviceCallback matching = NULL;
    void *matchingContext = NULL;
    CFRunLoopTimerRef timer = NULL;
    CFRunLoopRef runLoop = NULL;
    CFStringRef mode = NULL;
    @synchronized(self) {
        BOOL ready = _marked && _opened && _scheduled;
        if (ready && !_fakeAnnounced && _matchingCallback != NULL) {
            _fakeAnnounced = YES;
            matching = _matchingCallback;
            matchingContext = _matchingContext;
        }
        BOOL reportReady = ready && _reportCallback != NULL && _reportBuffer != NULL && _reportLength >= 64;
        if (reportReady && _timer == NULL && _runLoop != NULL && _runLoopMode != NULL) {
            CFRunLoopTimerContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
            _timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1.0 / 120.0, 0, 0, timer_callback, &context);
            timer = _timer;
            runLoop = _runLoop;
            mode = _runLoopMode;
        }
    }
    if (matching != NULL) matching(matchingContext, kIOReturnSuccess, (void *)_manager, SEFakeDevice());
    if (timer != NULL) CFRunLoopAddTimer(runLoop, timer, mode);
}

- (void)stopAndDisappear {
    IOHIDDeviceCallback removal = NULL;
    IOHIDReportCallback report = NULL;
    void *removalContext = NULL;
    void *reportContext = NULL;
    uint8_t *buffer = NULL;
    CFRunLoopTimerRef timer = NULL;
    @synchronized(self) {
        timer = _timer;
        _timer = NULL;
        if (_fakeAnnounced) { removal = _removalCallback; removalContext = _removalContext; }
        _fakeAnnounced = NO;
        report = _reportCallback;
        reportContext = _reportContext;
        buffer = _reportBuffer;
        _reportCallback = NULL;
        _reportContext = NULL;
        _reportBuffer = NULL;
        _reportLength = 0;
    }
    if (timer != NULL) { CFRunLoopTimerInvalidate(timer); CFRelease(timer); }
    SEInputEngine *engine = SEGetInputEngine();
    [engine clear];
    if (report != NULL && buffer != NULL) {
        NSData *neutral = [engine copyInputReport];
        memcpy(buffer, neutral.bytes, 64);
        report(reportContext, kIOReturnSuccess, (void *)SEFakeDevice(), kIOHIDReportTypeInput, 0x01, buffer, 64);
    }
    if (removal != NULL) removal(removalContext, kIOReturnSuccess, (void *)_manager, SEFakeDevice());
}

- (void)deactivateInput {
    SEInputEngine *engine = SEGetInputEngine();
    [engine clear];
    NSData *neutral = [engine copyInputReport];
    IOHIDReportCallback callback = NULL;
    void *context = NULL;
    uint8_t *buffer = NULL;
    @synchronized(self) {
        callback = _reportCallback;
        context = _reportContext;
        buffer = _reportBuffer;
        if (callback != NULL && buffer != NULL && _reportLength >= 64) memcpy(buffer, neutral.bytes, 64);
        else callback = NULL;
    }
    if (callback != NULL) callback(context, kIOReturnSuccess, (void *)SEFakeDevice(), kIOHIDReportTypeInput, 0x01, buffer, 64);
}

@end

void SERegisterManager(IOHIDManagerRef manager) {
    if (manager == NULL) return;
    os_unfair_lock_lock(&gRegistryLock);
    if (gStates == nil) gStates = [NSMutableDictionary dictionary];
    gStates[[NSValue valueWithPointer:manager]] = [[SEManagerState alloc] initWithManager:manager];
    os_unfair_lock_unlock(&gRegistryLock);
}

SEManagerState *SEStateForManager(IOHIDManagerRef manager) {
    os_unfair_lock_lock(&gRegistryLock);
    SEManagerState *state = gStates[[NSValue valueWithPointer:manager]];
    os_unfair_lock_unlock(&gRegistryLock);
    return state;
}

SEManagerState *SEFirstMarkedManager(void) {
    os_unfair_lock_lock(&gRegistryLock);
    SEManagerState *result = nil;
    for (SEManagerState *state in gStates.allValues) if (state.marked) { result = state; break; }
    os_unfair_lock_unlock(&gRegistryLock);
    return result;
}

IOHIDDeviceRef SEFakeDevice(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gFakeDeviceObject = [[NSObject alloc] init]; });
    return (__bridge IOHIDDeviceRef)gFakeDeviceObject;
}
BOOL SEIsFakeDevice(IOHIDDeviceRef device) { return device == SEFakeDevice(); }

void SESetInputEngine(SEInputEngine *engine) {
    os_unfair_lock_lock(&gRegistryLock); gInputEngine = engine; os_unfair_lock_unlock(&gRegistryLock);
}

SEInputEngine *SEGetInputEngine(void) {
    os_unfair_lock_lock(&gRegistryLock); SEInputEngine *engine = gInputEngine; os_unfair_lock_unlock(&gRegistryLock);
    return engine;
}

void SEDeactivateAllInput(void) {
    os_unfair_lock_lock(&gRegistryLock); NSArray *states = gStates.allValues.copy; os_unfair_lock_unlock(&gRegistryLock);
    for (SEManagerState *state in states) if (state.marked) [state deactivateInput];
}
