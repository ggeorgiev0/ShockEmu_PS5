#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define DYLD_INTERPOSE(replacement, replacee)                                      \
    __attribute__((used)) static struct {                                           \
        const void *replacement;                                                    \
        const void *replacee;                                                       \
    } interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement,                                  \
        (const void *)(unsigned long)&replacee                                      \
    }

static void probe_log(const char *format, ...) {
    const char *path = getenv("SHOCKEMU_PROBE_PATH");
    if (path == NULL || path[0] == '\0') {
        return;
    }

    int descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (descriptor < 0) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    (void)vdprintf(descriptor, format, arguments);
    va_end(arguments);
    (void)close(descriptor);
}

static long dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
    CFNumberRef value = CFDictionaryGetValue(dictionary, key);
    long result = -1;
    if (value != NULL && CFGetTypeID(value) == CFNumberGetTypeID()) {
        (void)CFNumberGetValue(value, kCFNumberLongType, &result);
    }
    return result;
}

static IOHIDManagerRef replacement_IOHIDManagerCreate(
    CFAllocatorRef allocator,
    IOOptionBits options
) {
    probe_log("IOHIDManagerCreate\n");
    return IOHIDManagerCreate(allocator, options);
}

static void replacement_IOHIDManagerSetDeviceMatchingMultiple(
    IOHIDManagerRef manager,
    CFArrayRef multiple
) {
    CFIndex count = multiple == NULL ? 0 : CFArrayGetCount(multiple);
    probe_log("IOHIDManagerSetDeviceMatchingMultiple count=%ld\n", (long)count);
    for (CFIndex index = 0; index < count; ++index) {
        CFTypeRef item = CFArrayGetValueAtIndex(multiple, index);
        if (item == NULL || CFGetTypeID(item) != CFDictionaryGetTypeID()) {
            continue;
        }
        CFDictionaryRef dictionary = item;
        probe_log(
            "match page=%ld usage=%ld vendor=%ld product=%ld\n",
            dictionary_number(dictionary, CFSTR(kIOHIDDeviceUsagePageKey)),
            dictionary_number(dictionary, CFSTR(kIOHIDDeviceUsageKey)),
            dictionary_number(dictionary, CFSTR(kIOHIDVendorIDKey)),
            dictionary_number(dictionary, CFSTR(kIOHIDProductIDKey))
        );
    }
    IOHIDManagerSetDeviceMatchingMultiple(manager, multiple);
}

DYLD_INTERPOSE(replacement_IOHIDManagerCreate, IOHIDManagerCreate);
DYLD_INTERPOSE(
    replacement_IOHIDManagerSetDeviceMatchingMultiple,
    IOHIDManagerSetDeviceMatchingMultiple
);
