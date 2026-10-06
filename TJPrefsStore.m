#import "TJPrefsStore.h"
#import <os/lock.h>
#import <sys/stat.h>

NSString *const kTJPrefsDomain = @"com.pisknk.twentyone";
NSString *const kTJPrefsChangedDarwinNotification = @"com.pisknk.twentyone.prefsChanged";
NSString *const TJPrefsStoreChangedNotification = @"TJPrefsStoreChangedNotification";

static NSString *const kSharedPrefsDir = @"/var/mobile/Media/TwentyOne";
static NSString *const kSharedPrefsFile = @"/var/mobile/Media/TwentyOne/com.pisknk.twentyone.plist";
static NSString *const kStandardPrefsFile = @"/var/mobile/Library/Preferences/com.pisknk.twentyone.plist";
static NSString *const kRootlessPrefsFile = @"/var/jb/var/mobile/Library/Preferences/com.pisknk.twentyone.plist";

static NSDictionary *sCachedPrefs = nil;
static os_unfair_lock sCacheLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sDarwinToken;

static void onDarwinPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    os_unfair_lock_lock(&sCacheLock);
    sCachedPrefs = nil;
    os_unfair_lock_unlock(&sCacheLock);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTJPrefsDomain);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TJPrefsStoreChangedNotification object:nil];
    });
}

static void ensureDarwinListener(void) {
    dispatch_once(&sDarwinToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        onDarwinPrefsChanged,
                                        (__bridge CFStringRef)kTJPrefsChangedDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    });
}

static NSDictionary *buildPrefsSnapshot(void) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    NSDictionary *shared = [NSDictionary dictionaryWithContentsOfFile:kSharedPrefsFile];
    if (shared && [shared isKindOfClass:[NSDictionary class]]) {
        [dict addEntriesFromDictionary:shared];
    }

    NSDictionary *standard = [NSDictionary dictionaryWithContentsOfFile:kStandardPrefsFile];
    if (standard && [standard isKindOfClass:[NSDictionary class]]) {
        [dict addEntriesFromDictionary:standard];
    }

    NSDictionary *rootless = [NSDictionary dictionaryWithContentsOfFile:kRootlessPrefsFile];
    if (rootless && [rootless isKindOfClass:[NSDictionary class]]) {
        [dict addEntriesFromDictionary:rootless];
    }

    NSArray *standardKeys = @[
        @"enabled", @"albumDetailEnabled", @"albumSaturation", @"albumBrightness",
        @"immersiveNowPlaying", @"immersiveMotionArtwork", @"lockScreenSpotifyMotion", @"lockScreenHideComplications",
        @"lastFmEnabled", @"lastFmShowBadge", @"lastFmNowPlayingEnabled",
        @"lastFmThreshold", @"lastFmBlacklistedArtists", @"lastFmBlacklistedAlbums",
        @"lastFmSessionKey", @"lastFmUsername", @"blacklistFormat"
    ];

    for (NSString *k in standardKeys) {
        CFPropertyListRef cfVal = CFPreferencesCopyAppValue((__bridge CFStringRef)k, (__bridge CFStringRef)kTJPrefsDomain);
        if (cfVal) {
            dict[k] = (__bridge id)cfVal;
            CFRelease(cfVal);
        } else if (!dict[k]) {
            NSString *anyKey = [NSString stringWithFormat:@"twentyone_%@", k];
            CFPropertyListRef anyVal = CFPreferencesCopyValue((__bridge CFStringRef)anyKey, CFSTR("kCFPreferencesAnyApplication"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            if (anyVal) {
                dict[k] = (__bridge id)anyVal;
                CFRelease(anyVal);
            }
        }
    }

    return [dict copy];
}

static NSDictionary *readPrefs(void) {
    ensureDarwinListener();

    os_unfair_lock_lock(&sCacheLock);
    NSDictionary *cached = sCachedPrefs;
    os_unfair_lock_unlock(&sCacheLock);
    if (cached) return cached;

    NSDictionary *snapshot = buildPrefsSnapshot();

    os_unfair_lock_lock(&sCacheLock);
    sCachedPrefs = snapshot;
    os_unfair_lock_unlock(&sCacheLock);
    return snapshot;
}

BOOL prefBool(NSString *key, BOOL def) {
    id v = readPrefs()[key];
    return v ? [v boolValue] : def;
}

CGFloat prefFloat(NSString *key, CGFloat def) {
    id v = readPrefs()[key];
    return v ? [v floatValue] : def;
}

NSString * _Nullable prefString(NSString *key, NSString * _Nullable def) {
    id v = readPrefs()[key];
    return [v isKindOfClass:[NSString class]] ? v : def;
}

id _Nullable prefValue(NSString *key) {
    return readPrefs()[key];
}

void prefSetObject(NSString *key, id _Nullable value) {
    os_unfair_lock_lock(&sCacheLock);
    sCachedPrefs = nil;
    os_unfair_lock_unlock(&sCacheLock);

    [[NSFileManager defaultManager] createDirectoryAtPath:kSharedPrefsDir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0777}
                                                    error:nil];

    NSMutableDictionary *sharedDict = [NSMutableDictionary dictionaryWithContentsOfFile:kSharedPrefsFile] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *stdDict = [NSMutableDictionary dictionaryWithContentsOfFile:kStandardPrefsFile] ?: [NSMutableDictionary dictionary];

    if (value) {
        sharedDict[key] = value;
        stdDict[key] = value;
    } else {
        [sharedDict removeObjectForKey:key];
        [stdDict removeObjectForKey:key];
    }

    NSData *sharedData = [NSPropertyListSerialization dataWithPropertyList:sharedDict
                                                                    format:NSPropertyListXMLFormat_v1_0
                                                                   options:0
                                                                     error:nil];
    if (sharedData) {
        [sharedData writeToFile:kSharedPrefsFile options:NSDataWritingAtomic error:nil];
        chmod([kSharedPrefsFile UTF8String], 0666);
    }

    NSData *stdData = [NSPropertyListSerialization dataWithPropertyList:stdDict
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:nil];
    if (stdData) {
        [stdData writeToFile:kStandardPrefsFile options:NSDataWritingAtomic error:nil];
        chmod([kStandardPrefsFile UTF8String], 0666);
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
        NSString *jbDir = @"/var/jb/var/mobile/Library/Preferences";
        [[NSFileManager defaultManager] createDirectoryAtPath:jbDir withIntermediateDirectories:YES attributes:nil error:nil];
        if (stdData) {
            [stdData writeToFile:kRootlessPrefsFile options:NSDataWritingAtomic error:nil];
            chmod([kRootlessPrefsFile UTF8String], 0666);
        }
    }

    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kTJPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTJPrefsDomain);

    NSString *anyKey = [NSString stringWithFormat:@"twentyone_%@", key];
    CFPreferencesSetValue((__bridge CFStringRef)anyKey, (__bridge CFPropertyListRef)value, CFSTR("kCFPreferencesAnyApplication"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("kCFPreferencesAnyApplication"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kTJPrefsChangedDarwinNotification,
                                         NULL, NULL, YES);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TJPrefsStoreChangedNotification object:nil];
    });
}
