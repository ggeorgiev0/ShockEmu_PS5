#import "ShockEmuCore.h"

@interface SEMouseCapturePolicy ()
@property(nonatomic, readwrite) BOOL captureRequested;
@property(nonatomic) BOOL streamingActive;
@end

@implementation SEMouseCapturePolicy

- (instancetype)init {
    self = [super init];
    if (self != nil) _captureRequested = YES;
    return self;
}

- (BOOL)shouldCapture {
    return _captureRequested && _streamingActive;
}

- (void)setStreamingActive:(BOOL)active {
    _streamingActive = active;
}

- (void)toggleCaptureRequested {
    _captureRequested = !_captureRequested;
}

@end
