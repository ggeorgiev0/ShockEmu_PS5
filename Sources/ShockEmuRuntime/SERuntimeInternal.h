#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDLib.h>
#import "ShockEmuCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface SEManagerState : NSObject

@property(nonatomic, readonly) IOHIDManagerRef manager;
@property(atomic, readonly, getter=isMarked) BOOL marked;

- (instancetype)initWithManager:(IOHIDManagerRef)manager;
- (void)setMarked:(BOOL)marked;
- (void)setOpened:(BOOL)opened;
- (void)scheduleWithRunLoop:(CFRunLoopRef)runLoop mode:(CFStringRef)mode;
- (void)unschedule;
- (void)setMatchingCallback:(nullable IOHIDDeviceCallback)callback context:(nullable void *)context;
- (void)setRemovalCallback:(nullable IOHIDDeviceCallback)callback context:(nullable void *)context;
- (void)forwardMatchingResult:(IOReturn)result sender:(nullable void *)sender device:(IOHIDDeviceRef)device;
- (void)forwardRemovalResult:(IOReturn)result sender:(nullable void *)sender device:(IOHIDDeviceRef)device;
- (void)registerReportBuffer:(nullable uint8_t *)buffer
                      length:(CFIndex)length
                    callback:(nullable IOHIDReportCallback)callback
                     context:(nullable void *)context;
- (void)deactivateInput;

@end

FOUNDATION_EXPORT void SERegisterManager(IOHIDManagerRef manager);
FOUNDATION_EXPORT SEManagerState * _Nullable SEStateForManager(IOHIDManagerRef manager);
FOUNDATION_EXPORT SEManagerState * _Nullable SEFirstMarkedManager(void);
FOUNDATION_EXPORT BOOL SEIsControllerMatchingCriteria(CFArrayRef _Nullable criteria);
FOUNDATION_EXPORT IOHIDDeviceRef SEFakeDevice(void);
FOUNDATION_EXPORT BOOL SEIsFakeDevice(IOHIDDeviceRef device);
FOUNDATION_EXPORT void SESetInputEngine(SEInputEngine * _Nullable engine);
FOUNDATION_EXPORT SEInputEngine * _Nullable SEGetInputEngine(void);
FOUNDATION_EXPORT void SEDeactivateAllInput(void);
FOUNDATION_EXPORT void SEInstallInputCapture(SEInputEngine *engine, NSString *source);
FOUNDATION_EXPORT int SEShockEmuRuntimeLoaded(void);

NS_ASSUME_NONNULL_END
