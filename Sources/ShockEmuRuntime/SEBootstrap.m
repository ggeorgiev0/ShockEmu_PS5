#import "SERuntimeInternal.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

static NSString *sha256(NSData *data) {
    if (data.length > UINT32_MAX) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static SEProfile *load_profile(void) {
    const char *pathValue = getenv("SHOCKEMU_PROFILE_PATH");
    const char *hashValue = getenv("SHOCKEMU_PROFILE_SHA256");
    if (pathValue == NULL || hashValue == NULL) return nil;
    NSString *path = [NSString stringWithUTF8String:pathValue];
    NSString *expectedHash = [NSString stringWithUTF8String:hashValue];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (data == nil || ![sha256(data) isEqualToString:expectedHash.lowercaseString]) {
        os_log_error(OS_LOG_DEFAULT, "ShockEmu profile verification failed; controller emulation is disabled");
        return nil;
    }
    NSError *error = nil;
    SEProfile *profile = [[SEProfile alloc] initWithData:data error:&error];
    if (profile == nil) {
        os_log_error(OS_LOG_DEFAULT, "ShockEmu profile parsing failed; controller emulation is disabled");
        return nil;
    }
    return profile;
}

int SEShockEmuRuntimeLoaded(void) { return 1; }

__attribute__((constructor)) static void shockemu_load(void) {
    @autoreleasepool {
        os_log_info(OS_LOG_DEFAULT, "ShockEmu runtime loaded");
        SEProfile *profile = load_profile();
        if (profile == nil) return;
        SEInputEngine *engine = [[SEInputEngine alloc] initWithProfile:profile];
        SESetInputEngine(engine);
        const char *sourceValue = getenv("SHOCKEMU_INPUT_SOURCE");
        NSString *source = sourceValue == NULL ? @"auto" : [NSString stringWithUTF8String:sourceValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^install)(void) = ^{ SEInstallInputCapture(engine, source); };
            if (NSApp != nil && NSApp.isRunning) install();
            else [[NSNotificationCenter defaultCenter]
                addObserverForName:NSApplicationDidFinishLaunchingNotification
                object:nil
                queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) { install(); }];
        });
    }
}
