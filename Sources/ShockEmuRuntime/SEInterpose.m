#import "SERuntimeInternal.h"

#import <IOKit/hid/IOHIDKeys.h>

#include <string.h>

#define DYLD_INTERPOSE(replacement, replacee)                                      \
    __attribute__((used)) static struct {                                           \
        const void *replacement;                                                    \
        const void *replacee;                                                       \
    } interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement,                                  \
        (const void *)(unsigned long)&replacee                                      \
    }

static void matching_proxy(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge SEManagerState *)context forwardMatchingResult:result sender:sender device:device];
}

static void removal_proxy(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge SEManagerState *)context forwardRemovalResult:result sender:sender device:device];
}

static IOHIDManagerRef se_manager_create(CFAllocatorRef allocator, IOOptionBits options) {
    IOHIDManagerRef manager = IOHIDManagerCreate(allocator, options);
    SERegisterManager(manager);
    return manager;
}

static void se_manager_set_matching_multiple(IOHIDManagerRef manager, CFArrayRef criteria) {
    SEManagerState *state = SEStateForManager(manager);
    BOOL marked = SEGetInputEngine() != nil && SEIsControllerMatchingCriteria(criteria);
    [state setMarked:marked];
    if (marked) {
        NSArray *matchNothing = @[@{@kIOHIDVendorIDKey: @(-1), @kIOHIDProductIDKey: @(-1)}];
        IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matchNothing);
    } else {
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria);
    }
}

static IOReturn se_manager_open(IOHIDManagerRef manager, IOOptionBits options) {
    IOReturn result = IOHIDManagerOpen(manager, options);
    if (result == kIOReturnSuccess) [SEStateForManager(manager) setOpened:YES];
    return result;
}

static IOReturn se_manager_close(IOHIDManagerRef manager, IOOptionBits options) {
    [SEStateForManager(manager) setOpened:NO];
    return IOHIDManagerClose(manager, options);
}

static void se_manager_schedule(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef mode) {
    IOHIDManagerScheduleWithRunLoop(manager, runLoop, mode);
    [SEStateForManager(manager) scheduleWithRunLoop:runLoop mode:mode];
}

static void se_manager_unschedule(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef mode) {
    [SEStateForManager(manager) unschedule];
    IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, mode);
}

static CFSetRef se_manager_copy_devices(IOHIDManagerRef manager) {
    SEManagerState *state = SEStateForManager(manager);
    if (!state.marked) return IOHIDManagerCopyDevices(manager);
    const void *device = SEFakeDevice();
    return CFSetCreate(NULL, &device, 1, NULL);
}

static void se_manager_register_matching(
    IOHIDManagerRef manager,
    IOHIDDeviceCallback callback,
    void *context
) {
    SEManagerState *state = SEStateForManager(manager);
    [state setMatchingCallback:callback context:context];
    IOHIDManagerRegisterDeviceMatchingCallback(manager, matching_proxy, (__bridge void *)state);
}

static void se_manager_register_removal(
    IOHIDManagerRef manager,
    IOHIDDeviceCallback callback,
    void *context
) {
    SEManagerState *state = SEStateForManager(manager);
    [state setRemovalCallback:callback context:context];
    IOHIDManagerRegisterDeviceRemovalCallback(manager, removal_proxy, (__bridge void *)state);
}

static IOReturn se_device_open(IOHIDDeviceRef device, IOOptionBits options) {
    return SEIsFakeDevice(device) ? kIOReturnSuccess : IOHIDDeviceOpen(device, options);
}

static CFTypeRef se_device_get_property(IOHIDDeviceRef device, CFStringRef key) {
    if (!SEIsFakeDevice(device)) return IOHIDDeviceGetProperty(device, key);
    static NSDictionary<NSString *, id> *properties;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        properties = @{
            @kIOHIDVendorIDKey: @0x054c,
            @kIOHIDProductIDKey: @0x05c4,
            @kIOHIDVersionNumberKey: @0x0100,
            @kIOHIDTransportKey: @"USB",
            @kIOHIDProductKey: @"Wireless Controller",
            @kIOHIDManufacturerKey: @"Sony Computer Entertainment",
            @kIOHIDPrimaryUsagePageKey: @1,
            @kIOHIDPrimaryUsageKey: @5,
        };
    });
    return (__bridge CFTypeRef)properties[(__bridge NSString *)key];
}

static IOReturn se_device_get_report(
    IOHIDDeviceRef device,
    IOHIDReportType type,
    CFIndex reportID,
    uint8_t *report,
    CFIndex *length
) {
    if (!SEIsFakeDevice(device)) return IOHIDDeviceGetReport(device, type, reportID, report, length);
    if (length == NULL || *length < 0 || reportID < 0 || reportID > UINT8_MAX) return kIOReturnBadArgument;
    size_t capacity = (size_t)*length;
    SEReportStatus status = SECopyFeatureReport((uint8_t)reportID, report, &capacity);
    *length = (CFIndex)capacity;
    if (status == SEReportStatusSuccess) return kIOReturnSuccess;
    return status == SEReportStatusBufferTooSmall ? kIOReturnNoSpace : kIOReturnUnsupported;
}

static IOReturn se_device_set_report(
    IOHIDDeviceRef device,
    IOHIDReportType type,
    CFIndex reportID,
    const uint8_t *report,
    CFIndex length
) {
    if (SEIsFakeDevice(device)) return kIOReturnSuccess;
    return IOHIDDeviceSetReport(device, type, reportID, report, length);
}

static void se_device_schedule(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef mode) {
    if (!SEIsFakeDevice(device)) IOHIDDeviceScheduleWithRunLoop(device, runLoop, mode);
}

static void se_device_register_report(
    IOHIDDeviceRef device,
    uint8_t *report,
    CFIndex length,
    IOHIDReportCallback callback,
    void *context
) {
    if (!SEIsFakeDevice(device)) {
        IOHIDDeviceRegisterInputReportCallback(device, report, length, callback, context);
        return;
    }
    [SEFirstMarkedManager() registerReportBuffer:report length:length callback:callback context:context];
}

DYLD_INTERPOSE(se_manager_create, IOHIDManagerCreate);
DYLD_INTERPOSE(se_manager_set_matching_multiple, IOHIDManagerSetDeviceMatchingMultiple);
DYLD_INTERPOSE(se_manager_open, IOHIDManagerOpen);
DYLD_INTERPOSE(se_manager_close, IOHIDManagerClose);
DYLD_INTERPOSE(se_manager_schedule, IOHIDManagerScheduleWithRunLoop);
DYLD_INTERPOSE(se_manager_unschedule, IOHIDManagerUnscheduleFromRunLoop);
DYLD_INTERPOSE(se_manager_copy_devices, IOHIDManagerCopyDevices);
DYLD_INTERPOSE(se_manager_register_matching, IOHIDManagerRegisterDeviceMatchingCallback);
DYLD_INTERPOSE(se_manager_register_removal, IOHIDManagerRegisterDeviceRemovalCallback);
DYLD_INTERPOSE(se_device_open, IOHIDDeviceOpen);
DYLD_INTERPOSE(se_device_get_property, IOHIDDeviceGetProperty);
DYLD_INTERPOSE(se_device_get_report, IOHIDDeviceGetReport);
DYLD_INTERPOSE(se_device_set_report, IOHIDDeviceSetReport);
DYLD_INTERPOSE(se_device_schedule, IOHIDDeviceScheduleWithRunLoop);
DYLD_INTERPOSE(se_device_register_report, IOHIDDeviceRegisterInputReportCallback);
