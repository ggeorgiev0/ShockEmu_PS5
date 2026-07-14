#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SEProfileErrorDomain;

typedef NS_ENUM(NSInteger, SEReportStatus) {
    SEReportStatusSuccess = 0,
    SEReportStatusUnsupported = 1,
    SEReportStatusBufferTooSmall = 2,
};

@interface SEProfile : NSObject

@property(nonatomic, readonly) NSDictionary<NSNumber *, NSArray<NSString *> *> *keyBindings;
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSArray<NSString *> *> *mouseBindings;
@property(nonatomic, readonly) NSArray<NSString *> *warnings;
@property(nonatomic, readonly) BOOL mouseLookEnabled;
@property(nonatomic, readonly) NSString *mouseStick;
@property(nonatomic, readonly) double mouseSensitivity;
@property(nonatomic, readonly) double mouseSmoothing;
@property(nonatomic, readonly) double mouseMinimumMagnitude;
@property(nonatomic, readonly) double mouseDecay;
@property(nonatomic, readonly) double mouseDeadZone;
@property(nonatomic, readonly) double mouseMultiplierX;
@property(nonatomic, readonly) double mouseMultiplierY;

- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error;

@end

@interface SEInputEngine : NSObject

- (instancetype)initWithProfile:(SEProfile *)profile;
- (void)setKeyCode:(uint16_t)keyCode pressed:(BOOL)pressed;
- (void)setMouseButton:(NSInteger)button pressed:(BOOL)pressed;
- (void)addMouseDeltaX:(double)deltaX deltaY:(double)deltaY;
- (NSData *)copyInputReport;
- (void)clear;

@end

@interface SEModifierState : NSObject

- (instancetype)initWithInputEngine:(SEInputEngine *)inputEngine;
- (void)togglePhysicalKeyCode:(uint16_t)keyCode;
- (void)clear;

@end

@interface SEMouseCapturePolicy : NSObject

@property(nonatomic, readonly) BOOL captureRequested;
@property(nonatomic, readonly) BOOL shouldCapture;

- (void)setStreamingActive:(BOOL)active;
- (void)toggleCaptureRequested;

@end

FOUNDATION_EXPORT SEReportStatus SECopyFeatureReport(
    uint8_t reportID,
    uint8_t *buffer,
    size_t *length
);

NS_ASSUME_NONNULL_END
