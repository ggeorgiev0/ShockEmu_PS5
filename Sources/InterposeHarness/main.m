#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static int matchingCount;
static int removalCount;
static int reportCount;
static int replacedCallbackCount;
static int activeCallbackCount;
static uint8_t lastReport[64];
static id retainedDevice;
static IOHIDDeviceRef expectedReportSender;
static bool invalidReportSender;

static void device_callback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)sender;
    int *count = context;
    if (result == kIOReturnSuccess) {
        *count += 1;
        if (context == &matchingCount) retainedDevice = (__bridge id)device;
        else retainedDevice = nil;
    }
}

static void report_callback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex length
) {
    if (sender != expectedReportSender) invalidReportSender = true;
    if (result == kIOReturnSuccess && type == kIOHIDReportTypeInput && reportID == 1 && length == 64) {
        memcpy(lastReport, report, 64);
        reportCount += 1;
        if (context != NULL) *(int *)context += 1;
    }
}

static CFNumberRef number(long value) {
    return CFNumberCreate(NULL, kCFNumberLongType, &value);
}

static CFDictionaryRef match(long product) {
    const void *keys[] = {
        CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey),
        CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey),
    };
    const void *values[] = {number(1), number(5), number(1356), number(product)};
    CFDictionaryRef result = CFDictionaryCreate(NULL, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (size_t index = 0; index < 4; ++index) CFRelease(values[index]);
    return result;
}

static CFArrayRef controller_criteria(void) {
    static const long products[] = {1476, 2508, 2976, 3302, 3570, 3679, 1476, 2508, 3302, 3570, 3679};
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 11, &kCFTypeArrayCallBacks);
    for (size_t index = 0; index < 11; ++index) {
        CFDictionaryRef dictionary = match(products[index]);
        CFArrayAppendValue(array, dictionary);
        CFRelease(dictionary);
    }
    return array;
}

static int fail(const char *message) {
    fprintf(stderr, "InterposeHarness: %s\n", message);
    return 1;
}

int main(void) {
    void *symbol = dlsym(RTLD_DEFAULT, "SEShockEmuRuntimeLoaded");
    int (*loaded)(void) = NULL;
    _Static_assert(sizeof(loaded) == sizeof(symbol), "function and data pointers must have equal size");
    memcpy(&loaded, &symbol, sizeof(loaded));
    if (loaded == NULL || loaded() != 1) return fail("runtime canary was not loaded");

    IOHIDManagerRef unrelated = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    CFDictionaryRef keyboard = match(9999);
    const void *keyboardValue = keyboard;
    CFArrayRef keyboardCriteria = CFArrayCreate(NULL, &keyboardValue, 1, &kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(unrelated, keyboardCriteria);
    CFSetRef unrelatedDevices = IOHIDManagerCopyDevices(unrelated);
    if (unrelatedDevices != NULL && CFSetGetCount(unrelatedDevices) == 1) {
        const void *candidate = NULL;
        CFSetGetValues(unrelatedDevices, &candidate);
        CFTypeRef vendor = IOHIDDeviceGetProperty((IOHIDDeviceRef)candidate, CFSTR(kIOHIDVendorIDKey));
        long value = 0;
        if (vendor != NULL && CFGetTypeID(vendor) == CFNumberGetTypeID()) {
            CFNumberGetValue(vendor, kCFNumberLongType, &value);
        }
        if (value == 1356) return fail("unrelated manager received the fake controller");
    }
    if (unrelatedDevices != NULL) CFRelease(unrelatedDevices);
    CFRelease(keyboardCriteria);
    CFRelease(keyboard);
    CFRelease(unrelated);

    IOHIDManagerRef manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    CFArrayRef criteria = controller_criteria();
    IOHIDManagerSetDeviceMatchingMultiple(manager, criteria);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, device_callback, &matchingCount);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, device_callback, &removalCount);
    if (IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone) != kIOReturnSuccess) return fail("manager open failed");
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (matchingCount != 1) return fail("fake matching callback was not delivered exactly once");

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices == NULL || CFSetGetCount(devices) != 1) return fail("selective fake discovery failed");
    const void *deviceValue = NULL;
    CFSetGetValues(devices, &deviceValue);
    IOHIDDeviceRef device = (IOHIDDeviceRef)deviceValue;
    expectedReportSender = device;
    CFNumberRef vendor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    long vendorID = 0;
    if (vendor == NULL || !CFNumberGetValue(vendor, kCFNumberLongType, &vendorID) || vendorID != 1356) {
        return fail("fake controller properties are invalid");
    }

    uint8_t feature[64] = {0};
    CFIndex featureLength = 1;
    if (IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x12, feature, &featureLength) != kIOReturnNoSpace || featureLength != 16) {
        return fail("undersized feature report was not rejected");
    }
    featureLength = sizeof(feature);
    if (IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x12, feature, &featureLength) != kIOReturnSuccess || feature[0] != 0x12) {
        return fail("feature report delivery failed");
    }

    uint8_t shortReport[16] = {0};
    IOHIDDeviceRegisterInputReportCallback(device, shortReport, sizeof(shortReport), report_callback, &replacedCallbackCount);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    if (reportCount != 0) return fail("undersized input buffer started report delivery");
    uint8_t report[64] = {0};
    IOHIDDeviceRegisterInputReportCallback(device, report, sizeof(report), report_callback, &replacedCallbackCount);
    IOHIDDeviceRegisterInputReportCallback(device, report, sizeof(report), report_callback, &activeCallbackCount);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.1;
    while (reportCount < 2 && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    }
    if (reportCount < 2 || lastReport[0] != 1) return fail("120 Hz callback delivery failed");
    if (invalidReportSender) return fail("input report callback used the wrong sender");
    if (replacedCallbackCount != 0 || activeCallbackCount != reportCount) {
        return fail("report callback re-registration was not atomic");
    }
    int beforeUnschedule = reportCount;
    IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (reportCount != beforeUnschedule + 1 || lastReport[1] != 128 || lastReport[5] != 8) {
        return fail("unschedule did not deliver one neutral report");
    }
    if (removalCount != 1) return fail("fake removal callback was not delivered exactly once");
    int beforeReschedule = reportCount;
    IOHIDDeviceRegisterInputReportCallback(device, report, sizeof(report), report_callback, &activeCallbackCount);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (matchingCount != 2) return fail("reschedule did not rediscover the fake exactly once");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    if (reportCount <= beforeReschedule) return fail("register-before-schedule ordering failed");
    int beforeClose = reportCount;
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    if (removalCount != 2 || reportCount != beforeClose + 1) return fail("close teardown was not exactly once");
    IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (removalCount != 2 || reportCount != beforeClose + 1) return fail("unschedule duplicated close teardown");

    CFRelease(devices);
    CFRelease(criteria);
    CFRelease(manager);
    puts("InterposeHarness: PASS");
    return 0;
}
