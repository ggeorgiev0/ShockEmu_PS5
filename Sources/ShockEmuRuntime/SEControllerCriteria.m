#import "SERuntimeInternal.h"

#import <IOKit/hid/IOHIDKeys.h>

static long dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    long result = -1;
    if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
        (void)CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    }
    return result;
}

BOOL SEIsControllerMatchingCriteria(CFArrayRef criteria) {
    static const long expectedProducts[] = {
        1476, 2508, 2976, 3302, 3570, 3679, 1476, 2508, 3302, 3570, 3679,
    };
    if (criteria == NULL || CFGetTypeID(criteria) != CFArrayGetTypeID() ||
        CFArrayGetCount(criteria) != (CFIndex)(sizeof(expectedProducts) / sizeof(expectedProducts[0]))) {
        return NO;
    }
    for (CFIndex index = 0; index < CFArrayGetCount(criteria); ++index) {
        CFTypeRef item = CFArrayGetValueAtIndex(criteria, index);
        if (item == NULL || CFGetTypeID(item) != CFDictionaryGetTypeID()) return NO;
        CFDictionaryRef dictionary = (CFDictionaryRef)item;
        if (dictionary_number(dictionary, CFSTR(kIOHIDDeviceUsagePageKey)) != 1 ||
            dictionary_number(dictionary, CFSTR(kIOHIDDeviceUsageKey)) != 5 ||
            dictionary_number(dictionary, CFSTR(kIOHIDVendorIDKey)) != 1356 ||
            dictionary_number(dictionary, CFSTR(kIOHIDProductIDKey)) != expectedProducts[index]) {
            return NO;
        }
    }
    return YES;
}
